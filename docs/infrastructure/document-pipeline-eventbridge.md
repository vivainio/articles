# A Document Processing Pipeline with EventBridge Choreography

*2026-09-12*

The [durable-functions version](document-pipeline-durable-functions.md) gives one execution responsibility for the whole document pipeline. Here, extraction, classification, review, and finalization each own their stage. EventBridge connects them; a shared orchestrator API, `emit(...)`, records transitions and arranges delivery.

The central invariant is **one owner for the document's next required action**. Completing a stage means handing responsibility to the next service. The owner is explicit in the event and in DynamoDB, so an operator can ask "who owes the next action, and since when?" without reconstructing the event history.

## A handoff transfers ownership

A stage hands off through one interface. The examples below are conceptual pseudocode, not AWS SDK calls:

```text
emit(
    eventId=stable_completion_id,
    eventType="DocumentClassified",
    tenantId=tenant_id,
    documentId=document_id,
    processingRunId=run_id,
    sender="classification",
    expectedOwnershipVersion=12,
    owner="review",
    payload={classificationRef: immutable_result_ref, reviewRequestId: review_id},
)
```

**Ownership transfers when `emit` durably accepts the handoff.** Until then, the sender remains responsible. After acceptance, the new owner is responsible even while its work is queued; the delivery infrastructure must deliver the assignment.

If the response is lost, retry with the same event ID and contents. `emit` returns the original receipt; reusing the ID with different contents is an error. The producer must store its completion intent durably or reconstruct it from a redelivered task.

An explicit `owner` couples the producer to its destination. For independent routing, a routing service or versioned policy can choose the owner instead. Persist that choice before publication. The example above chooses review directly; the pipeline table below uses a routing service.

The emitter declares `sender` as a logical service name, regardless of where it runs. The API checks the current owner against `sender`, checks `expectedOwnershipVersion`, and validates the transition. These are workflow consistency checks, not authentication. Owner and version checks run inside the transaction.

The version prevents an old completion from A releasing a new assignment after ownership moves A → B → A. Check for an existing receipt before checking ownership, so retries still succeed after a completed handoff.

## Handoffs and broadcasts

A handoff assigns one next owner. Other subscribers can observe the same event without becoming owners. Analytics reacting to `DocumentClassified` does not acquire responsibility for progressing the document.

| Accepted event | Document owner after transition | Required action |
|---|---|---|
| `DocumentUploaded` | extraction | Establish the page manifest and dispatch OCR |
| `PageReady` / `PageExtracted` | extraction, unchanged | Process and collect page tasks |
| `DocumentClassifiable` | classification | Classify the collected result |
| `DocumentClassified` | routing | Choose review or finalization |
| `ReviewRequested` | review | Collect a decision or expire the request |
| `DocumentApproved` | finalization | Store the approved document |
| `DocumentRejected` / `ReviewExpired` | disposition | Record the outcome and apply archive policy |
| `DocumentFinalized` / `DocumentArchived` | none | Terminal; observers may still react |

An ingestion adapter creates the initial assignment from the S3 notification; this creation transition has no previous owner. Splitting then produces `PageReady` events.

During fan-out, extraction owns the document and workers own page tasks. Validate each page completion against its task owner and version. Optional work such as indexing has a separate lifecycle unless the next document handoff requires its result.

## What `emit` guarantees

The shared API owns the event schema. Its handlers can run concurrently, so acceptance requires transactions and conditional writes.

For each accepted transition, atomically persist:

- The input event identity and its acceptance receipt, for deduplication.
- The validated state change, including owner and ownership version when transferring responsibility.
- The accepted transition in the document history.
- Immutable outgoing event envelopes in an outbox, for eventual publication.

```text
accept(request):
    sender = request.sender
    validate_event_schema(request)
    if receipt_exists(request.eventId):
        return receipt_if_same_contents(request)
    state = load_relevant_state(request)
    transition = owning_process_policy(state, request)
    transaction(
        require_event_not_previously_accepted,
        require_current_owner_equals_sender,  # for the assignment being handed off
        require_expected_state_versions,
        write_receipt_and_history,
        apply_transition,
        write_outgoing_intents,
    )
    return acceptance_receipt
```

On a transaction conflict, reload state and reevaluate. Record ignored reports, such as expiry after approval, without changing business state.

A publisher reads the outbox and calls EventBridge. It handles individual `PutEvents` entry failures and marks only successful entries as published. If it crashes after publication but before recording success, it publishes again with the same application event ID. Consumers must tolerate that duplicate.

This [transactional outbox](https://docs.aws.amazon.com/prescriptive-guidance/latest/cloud-design-patterns/transactional-outbox.html) prevents a committed transition from losing its outgoing event. Publication confirms bus acceptance, not worker completion; delivery and worker failures still need recovery.

Keep transactions bounded: store large manifests immutably and create deterministic page assignments in resumable batches. Persist the dispatch intent so a crash cannot lose undispatched pages.

## Tracking ownership in DynamoDB

The document's authoritative coordination item might contain:

```text
tenantId, documentId, processingRunId
owner: review
status: pending-review
ownershipVersion: 13
assignedAt: ...
dueAt: ...
reviewRequestId: ...
```

`owner` describes responsibility; `status` describes progress. Use separate state revisions to protect concurrent updates within an assignment.

Each assignment event carries `ownershipVersion`. The receiver copies it unchanged into `expectedOwnershipVersion` on its next handoff. Services neither increment it nor need to query for it.

```text
A receives an assignment with ownershipVersion: 12
A → Emit(sender: A, expectedOwnershipVersion: 12, owner: B)
Orchestrator → B: event with owner: B, ownershipVersion: 13
B → Emit(sender: B, expectedOwnershipVersion: 13, owner: C)
Orchestrator → C: event with owner: C, ownershipVersion: 14
```

The orchestrator atomically checks and increments the version when accepting a handoff, storing it in the assignment and outgoing event. Publication retries and reports without a handoff keep the version unchanged. File and page assignments follow the same rule with task versions.

Replacing a file or reprocessing a document starts a new `processingRunId`. Scope page deduplication to the run and page, and review decisions to the review request, so old completions cannot advance new work. Pin source object and policy/model versions to identify what produced each result.

Key history by stable event identities. Record versions and causation IDs for ordering; timestamps alone are insufficient. Keep large OCR results in S3 and immutable references in events.

Index dashboard queries by tenant, owner, status, and due time. Avoid concentrating traffic on a common status key. Dashboards may use eventually consistent projections; transitions check authoritative state.

EventBridge [archives and replay](https://docs.aws.amazon.com/eventbridge/latest/userguide/eb-replay-archived-event.html) can help recover published events. The application history additionally records acceptance, ignored reports, and ownership decisions; a bus archive does not replace that record.

## Fan-in belongs to extraction

Before dispatch, extraction fixes an immutable manifest of expected page identities. Each page result must belong to that manifest and processing run. Recording a previously unseen successful result and incrementing the completion count happen atomically. Exactly one accepted join transition creates the `DocumentClassifiable` outgoing intent and transfers ownership.

Extraction retains ownership when a page fails permanently, until intervention retries it or rejects the document. Missing pages have deadlines and enter the repair queue. Processing partial results requires an explicit policy.

A durable execution can implement extraction internally if it owns dispatch and collection. A `context.map` that starts OCR is not a drop-in replacement for a passive gate receiving independently dispatched results; changing between them changes who owns the work.

There may be no reason to split at all. Textract's [asynchronous multipage processing](https://docs.aws.amazon.com/textract/latest/dg/api-async.html) accepts PDF/TIFF documents and reports completion through SNS. For suitable documents, extraction can own one external job instead of a custom page fan-out and join. Keep page tasks when they serve selective retries, different processors, or other actual requirements.

## Reviews, deadlines, and authorization

The review service owns the document while a person decides. It validates the response and emits the handoff as `sender="review"`, recording the human actor separately for audit.

The approval endpoint binds authorization to the tenant, run, review request, action, and expiry. A signed link opens the UI; an explicit authorized submission records the decision.

Approval requires a pending review and a server-side deadline check. Here, a decision must pass that check during acceptance processing; a client-provided timestamp does not establish timely approval. Concurrent approval and expiry use conditional transitions on the same review state. If the business instead requires an exact durable receipt cutoff, persist receipt time and arbitrate from that record explicitly.

Entering review persists a scheduling intent. A retryable dispatcher creates a one-time EventBridge Scheduler schedule with a stable identity. It requests expiry for that review; the review service decides the outcome. Late delivery cannot extend the approval deadline or overturn an accepted approval.

Cancel schedules after decisions and delete completed schedules. A reconciler checks overdue reviews to cover failed schedule creation or exhausted delivery retries.

## Preserve event meaning on retries

Use a common envelope:

```text
eventId, eventType, schemaVersion
tenantId, documentId, processingRunId
causationId, occurredAt
sender                        # declared logical service name
owner, ownershipVersion       # document assignment, where relevant
taskId, taskVersion           # separately scoped work, where relevant
payload / immutable artifact references
```

An allow-listed context record can simplify producers, but resolve its fields when accepting the transition and freeze them in the outgoing envelope. Reading the latest context during publication could attach a new classification or source object to an old event on retry.

A transport retry keeps the original event identity and meaning. Intentional reprocessing creates a new run. Rebuilding a dashboard from history should not accidentally reissue business actions. Version event schemas and routing decisions so independently deployed consumers can interpret older accepted work.

## Backpressure and idempotent workers

An SQS queue between the `PageReady` rule and OCR buffers bursts. Set event-source concurrency and function capacity deliberately, and account for batch size and parallel calls within each worker. Concurrency limits bound in-flight work, not requests per second. Shared OCR quotas may need a rate limiter and retry backoff across all documents and tenants.

Every required consumer handles duplicates, including those on a linear path. A forwarding stage can reproduce a downstream side effect even if it changes no gate state. Workers persist or reconstruct a stable task outcome and completion event, and acknowledge queue messages only after the required completion acceptance succeeds. If a crash occurs between an external side effect and its result record, use the downstream service's idempotency mechanism or reconcile the result before repeating it.

Ownership versions reject stale coordination writes. External writes need their own run/version checks or idempotency keys; transferring ownership does not stop an old worker.

## Recovery is part of the model

Ownership makes recovery actionable. Query for overdue assignments, incomplete page manifests, unpublished outbox entries, and exhausted target or worker retries. Show the responsible service, assignment age, last accepted transition, and failure reason.

Retry the same logical assignment when repairing delivery. Reassign only through a conditional ownership transition, issuing a new version that makes old completions stale. Retain deduplication receipts long enough for the supported retry and replay window, and define how older events are rejected or reconciled.

Track business age separately from delivery health: a review can legitimately wait for hours, while an unpublished assignment should attract attention much sooner. Required ownership routes need deployment checks and monitoring; adding an optional subscriber is different from changing the route on which progress depends.

## Scaling and the tradeoff

A waiting document has no durable Lambda execution, but it still has managed state: coordination and history items, possibly an outbox backlog, and a schedule for a pending review. [Scheduler quotas](https://docs.aws.amazon.com/scheduler/latest/UserGuide/scheduler-quotas.html) cover schedule count, creation rate, and invocation throughput.

Current [Lambda quotas](https://docs.aws.amazon.com/lambda/latest/dg/gettingstarted-limits.html) list 5 million running durable executions per Region, or 10 million in the specified higher-quota Regions, with increases available. The 3,000-operation and 100 MB cumulative persisted-payload limits are per execution. Quotas change; verify the deployment Region rather than choosing choreography to escape a particular historical number.

Size either design using arrival rate, pages per document, review fraction and duration, burst size, and downstream throughput. At steady state, pending reviews are roughly the review arrival rate multiplied by average review duration. One million documents per day says much less about capacity than those quantities do.

EventBridge supports independent evolution: services own their processes, observers subscribe without changing them, and assignments expose responsibility. The shared acceptance contract makes consistency and recovery reusable.

The cost is operating transactions, an outbox, consumer idempotency, scheduling, and reconciliation. Durable functions can still simplify work inside a stage, while EventBridge connects document handoffs and independent subscribers.
