# A Document Processing Pipeline with EventBridge Choreography

*2026-09-12*

The [durable-functions version](document-pipeline-durable-functions.md) puts one execution in charge of the document's whole journey. This design distributes that responsibility across services: extraction, classification, review, and finalization each own their part of the process. EventBridge connects them, and a shared `emit(...)` API records accepted transitions and arranges delivery.

The central invariant is **one owner for the document's next required action**. Completing a stage means handing responsibility to the next service. The owner is explicit in the event and in DynamoDB, so an operator can ask "who owes the next action, and since when?" without reconstructing the event history.

There is still business logic with an owner. Extraction owns page completion, review owns decisions and deadlines, and routing policy determines the next service. What disappears is the requirement for one execution to drive every stage from beginning to end.

## Emitting releases ownership

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

**Ownership transfers when `emit` durably accepts the handoff.** Attempting an HTTP call or placing an event in process memory does not release it. After acceptance, the new owner is responsible even if its work is still queued. The delivery infrastructure is responsible for getting the accepted assignment to that service.

A lost response leaves the producer uncertain, so it retries with the same event ID and contents. `emit` returns the original acceptance receipt rather than creating another transition. A reused event ID with different contents is an error. The producer must retain its completion intent durably or be able to reconstruct it from a redelivered task; a local variable is not a retry mechanism.

Passing `owner` explicitly means the producer knows its next destination. That is a deliberate coupling. If routing should change independently, a routing service chooses the owner, or the acceptance API resolves it from versioned routing policy. Resolve and persist that choice once, before publication.

The API derives the sender service from the authenticated caller, or verifies an explicit `sender` against that identity. For a handoff, it checks that the current document owner equals `sender`, that `expectedOwnershipVersion` matches, and that the sender may request the proposed transition. A caller cannot acquire authority merely by naming the current owner. The owner and version checks are transaction preconditions, so a concurrent handoff cannot invalidate them between validation and commit.

Keep the version even with the sender check: ownership can move from A to B and back to A. An old completion from A must not release A's new assignment. An authenticated retry of an already accepted event returns its original receipt before checking current ownership; otherwise a successful handoff with a lost response would incorrectly fail on retry.

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

An ingestion adapter translates the S3 notification into `DocumentUploaded`. Splitting produces `PageReady` events, not another `DocumentUploaded`.

For fan-out, extraction retains document ownership while workers receive individually owned page tasks. For a page completion, validate the sender and version against the page task assignment. Page completion changes that task's state; it does not overwrite the document owner. This also accommodates optional work such as indexing: either it is required before the next handoff, or it has its own responsibility and lifecycle outside the document's main path.

## What `emit` guarantees

A recording Lambda is a convenient schema boundary, but its invocations run concurrently. Reliability comes from transactions and conditional writes, not from having one function name.

For each accepted transition, atomically persist:

- The input event identity and its acceptance receipt, for deduplication.
- The validated state change, including owner and ownership version when transferring responsibility.
- The accepted transition in the document history.
- Immutable outgoing event envelopes in an outbox, for eventual publication.

```text
accept(request):
    sender = authenticate_sender_and_authorize(request)
    require_claimed_sender_matches_identity(request, sender)
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

Concurrent changes can invalidate the transaction. Reload and reevaluate rather than applying a decision based on stale state. Ignored reports, such as a late expiry after approval, may be recorded with that disposition; they never change the accepted business state.

A publisher reads the outbox and calls EventBridge. It handles individual `PutEvents` entry failures and marks only successful entries as published. If it crashes after publication but before recording success, it publishes again with the same application event ID. Consumers must tolerate that duplicate.

This is the [transactional outbox pattern](https://docs.aws.amazon.com/prescriptive-guidance/latest/cloud-design-patterns/transactional-outbox.html). It closes the gap where a gate commits but its output disappears before publication. EventBridge acceptance is also not proof that the required worker completed: target delivery failures and worker failures need their own retry and repair paths.

Keep each transaction bounded. A large page manifest should be stored immutably, then expanded into deterministic page assignments in resumable batches. A durable dispatch intent ensures that a crash halfway through expansion does not lose the remaining pages.

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

`owner` describes responsibility; `status` describes progress. A service can own queued work before any worker starts. Transfer increments `ownershipVersion`; later completions must match the assignment they were issued. Use additional state revisions where concurrent updates within an assignment need protection.

Document identity and processing identity differ. Replacing a file or deliberately reprocessing it starts a new `processingRunId`. Page deduplication includes the run and page identity; review decisions include the review request. An old completion cannot advance a new run. Pin the source object version and processing policy or model version so results have a defined provenance.

The append-only history uses stable event identities, with timestamps as metadata. Timestamps alone neither guarantee unique keys nor establish causal order. Record accepted versions and causation IDs to explain transitions. Store large OCR results in S3 and retain immutable references in events.

Dashboard indexes can answer queries by tenant, owner, status, and due time. Plan index partitioning for concentrated workloads; distributing base-table keys by document does not automatically distribute an index keyed only by a common status. Dashboards may tolerate stale projections, but transition preconditions use authoritative state.

EventBridge [archives and replay](https://docs.aws.amazon.com/eventbridge/latest/userguide/eb-replay-archived-event.html) can help recover published events. The application history additionally records acceptance, ignored reports, and ownership decisions; a bus archive does not replace that record.

## Fan-in belongs to extraction

Before dispatch, extraction fixes an immutable manifest of expected page identities. Each page result must belong to that manifest and processing run. Recording a previously unseen successful result and incrementing the completion count happen atomically. Exactly one accepted join transition creates the `DocumentClassifiable` outgoing intent and transfers ownership.

Define failure as well as success: this pipeline sends a permanently failed page to extraction intervention and retains extraction ownership until the page is retried or the document is explicitly rejected. A missing page has a deadline and appears in the repair queue; it cannot leave the document silently waiting forever. Partial classification could be a separate, explicit policy.

A durable execution can implement extraction internally if it owns dispatch and collection. A `context.map` that starts OCR is not a drop-in replacement for a passive gate receiving independently dispatched results; changing between them changes who owns the work.

There may be no reason to split at all. Textract's [asynchronous multipage processing](https://docs.aws.amazon.com/textract/latest/dg/api-async.html) accepts PDF/TIFF documents and reports completion through SNS. For suitable documents, extraction can own one external job instead of a custom page fan-out and join. Keep page tasks when they serve selective retries, different processors, or other actual requirements.

## Reviews, deadlines, and authorization

The review service owns the document while a person decides. A human response is a request to that service; the accepted business event follows validation. The review service emits the handoff as `sender="review"`; record the human actor separately for audit. Similarly, optional observers submit reports or requests without transferring document ownership. Initial ingestion is an explicitly authorized creation transition, since no previous owner exists.

The approval endpoint binds authorization to the tenant, document run, review request, permitted action, and expiry. An unguessable document ID is not authorization. A signed link may open the review UI; an explicit authenticated or token-authorized submission records the decision.

Approval requires a pending review and a server-side deadline check. Here, a decision must pass that check during acceptance processing; a client-provided timestamp does not establish timely approval. Concurrent approval and expiry use conditional transitions on the same review state. If the business instead requires an exact durable receipt cutoff, persist receipt time and arbitrate from that record explicitly.

Entering review also persists an intent to create a one-time EventBridge Scheduler schedule. A retryable dispatcher creates it using a stable schedule identity. The schedule requests expiry for that specific review; it does not itself decide the outcome. If delivered late, it cannot make a late approval valid. If approval has already won, expiry is ignored.

Cancellation after a decision and deletion of completed schedules keep resources tidy. A reconciler also checks overdue reviews, covering failed schedule creation or exhausted delivery retries. Scheduling is part of the durable handoff design, not an untracked side effect after it.

## Preserve event meaning on retries

Use a common envelope:

```text
eventId, eventType, schemaVersion
tenantId, documentId, processingRunId
causationId, occurredAt
sender                        # verified service identity, recorded by emit
owner, ownershipVersion       # document assignment, where relevant
taskId, taskVersion           # separately scoped work, where relevant
payload / immutable artifact references
```

An allow-listed context record can simplify producers, but resolve its fields when accepting the transition and freeze them in the outgoing envelope. Reading the latest context during publication could attach a new classification or source object to an old event on retry.

A transport retry keeps the original event identity and meaning. Intentional reprocessing creates a new run. Rebuilding a dashboard from history should not accidentally reissue business actions. Version event schemas and routing decisions so independently deployed consumers can interpret older accepted work.

## Backpressure and idempotent workers

An SQS queue between the `PageReady` rule and OCR buffers bursts. Set event-source concurrency and function capacity deliberately, and account for batch size and parallel calls within each worker. Concurrency bounds in-flight work; they are not a requests-per-second guarantee. Shared OCR quotas may need a rate limiter and retry backoff across all documents and tenants.

Likewise, a durable map's per-document concurrency bound does not protect an account-wide downstream quota. Both designs need capacity planning beyond their local fan-out mechanism.

Every required consumer handles duplicates, including those on a linear path. A forwarding stage can reproduce a downstream side effect even if it changes no gate state. Workers persist or reconstruct a stable task outcome and completion event, and acknowledge queue messages only after the required completion acceptance succeeds. If a crash occurs between an external side effect and its result record, use the downstream service's idempotency mechanism or reconcile the result before repeating it.

An ownership version fences stale coordination writes. It does not automatically cancel an old worker or prevent its external writes; those effects need their own run/version checks or idempotency keys.

## Recovery is part of the model

Ownership makes recovery actionable. Query for overdue assignments, incomplete page manifests, unpublished outbox entries, and exhausted target or worker retries. Show the responsible service, assignment age, last accepted transition, and failure reason.

Retry the same logical assignment when repairing delivery. Reassign only through a conditional ownership transition, issuing a new version that makes old completions stale. Retain deduplication receipts long enough for the supported retry and replay window, and define how older events are rejected or reconciled.

Track business age separately from delivery health: a review can legitimately wait for hours, while an unpublished assignment should attract attention much sooner. Required ownership routes need deployment checks and monitoring; adding an optional subscriber is different from changing the route on which progress depends.

## Scaling and the tradeoff

A waiting document has no durable Lambda execution, but it still has managed state: coordination and history items, possibly an outbox backlog, and a schedule for a pending review. [Scheduler quotas](https://docs.aws.amazon.com/scheduler/latest/UserGuide/scheduler-quotas.html) cover schedule count, creation rate, and invocation throughput. This is not unlimited concurrency without resources.

Current [Lambda quotas](https://docs.aws.amazon.com/lambda/latest/dg/gettingstarted-limits.html) list 5 million running durable executions per Region, or 10 million in the specified higher-quota Regions, with increases available. The 3,000-operation and 100 MB cumulative persisted-payload limits are per execution. Quotas change; verify the deployment Region rather than choosing choreography to escape a particular historical number.

Size either design using arrival rate, pages per document, review fraction and duration, burst size, and downstream throughput. At steady state, pending reviews are roughly the review arrival rate multiplied by average review duration. One million documents per day says much less about capacity than those quantities do.

The stronger case for EventBridge is independent evolution: services own bounded processes, observers subscribe without changing those processes, and explicit assignments expose responsibility across the whole system. The shared acceptance contract makes consistency and recovery reusable instead of asking every stage to invent them.

The cost is operating that contract: transactions, an outbox, consumer idempotency, scheduling, and reconciliation. Durable functions can still simplify a service's internal work. Use them inside extraction or another bounded stage when useful, while keeping document handoffs and independent subscriptions on EventBridge. The result is a pipeline whose ownership is distributed, explicit, and queryable.
