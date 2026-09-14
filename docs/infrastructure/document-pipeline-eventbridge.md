# A Document Processing Pipeline with EventBridge

*2026-09-12*

Imagine a user uploads an invoice. The upload service announces `DocumentUploaded`. An extraction service picks it up, reads the document, and announces `DocumentClassifiable`. Classification then does its part, followed by review and finalization.

This is an illustrative pipeline: OCR and document classification give us a concrete example of services working together.

```text
Upload         → DocumentUploaded
Extraction     → DocumentClassifiable
Classification → DocumentClassified
Routing        → ReviewRequested
Review         → DocumentApproved
Finalization   → DocumentFinalized
```

Each event says what just happened. The next service reacts to that event and carries the work forward. This example follows a document that needs review and gets approved; other documents could skip review or be rejected.

**Amazon EventBridge is an event bus:** services publish events to it, and rules route those events to interested services. The upload service publishes `DocumentUploaded`, and an EventBridge rule delivers that event to extraction. Another rule could send the same event to analytics without changing the upload service.

You subscribe by creating a **rule**: an event pattern says which events you want, and a target says where to send them. A rule can match one event type, such as `DocumentUploaded`, or several, such as `DocumentApproved` and `DocumentRejected`. See [EventBridge rules](https://docs.aws.amazon.com/eventbridge/latest/userguide/eb-rules.html).

A common target is an **SQS queue**, which holds the matching events until the receiving service processes them:

```text
Upload service → EventBridge → rule matching DocumentUploaded → SQS → Extraction service
```

Each interested service can have its own rule and queue. EventBridge can also deliver directly to targets such as Lambda functions. See [EventBridge targets](https://docs.aws.amazon.com/eventbridge/latest/userguide/eb-targets.html).

This style is called **choreography**: services coordinate through events, with each service owning its part of the process. The [durable-functions version](document-pipeline-durable-functions.md) instead gives one execution responsibility for the whole pipeline.

## Passing responsibility with the event

For this concept, services publish through a shared API called `emit`. The upload service starts the pipeline with:

```text
emit("DocumentUploaded", documentId="invoice-42",
     sender="upload", nextOwner="extraction")
```

Once extraction has the document's text, it hands over to classification:

```text
emit("DocumentClassifiable", documentId="invoice-42",
     sender="extraction", nextOwner="classification")
```

These are conceptual calls. `emit` is our application's handoff API, built around EventBridge. A small client wrapper could invoke a Lambda synchronously, returning an acceptance receipt or raising an ownership/version error before the calling service proceeds. The follow-up compares [implementation options for `emit`](document-pipeline-workflow-tracker.md#implementing-emit).

Ownership is optional and applies where the workflow needs a controlled handoff. In a strict ownership flow, the application records the responsible service and validates its handoffs. In an unowned flow, the owner is `null` and ownership checks do not apply. Authentication and other applicable validation still apply.

A service does not always need to know what happens next. It can publish an event describing the work it completed, and configured subscribers can react to that result. Multiple services may react independently; any required ordering or coordination must be defined by the application.

Coordination is distributed in this model. A component can explicitly hand responsibility to a known next owner, or publish a completion event without specifying an owner and let interested handlers react. The workflow then emerges from the services’ event contracts and subscription rules.

`nextOwner` therefore supports explicit handoffs where needed, while completion events also support flows without a designated owner. The examples below use strict ownership.

`sender` identifies the service making the handoff; `nextOwner` says who should take over. The handoff API verifies the sender against the authenticated caller and checks that it matches the document's recorded current owner. It also checks that the requested transition is allowed. If classification tries to advance a document still owned by extraction, the API rejects the handoff and reports an ownership mismatch. Ownership stays with extraction.

`DocumentUploaded` creates the initial assignment, so it has no previous owner to check. The API verifies that the upload service is allowed to start the workflow and that it is not replacing an existing assignment.

For a strict ownership flow, **one service owns the document's next required action**. After upload, extraction owes the next action. After extraction, classification does. The handoff records who is responsible next and arranges delivery of the event.

EventBridge routes events; the application keeps track of responsibility. A shared record in a database such as DynamoDB could show:

```text
document: invoice-42
owner: review
status: waiting for approval
```

That makes a useful operational question easy to answer: “Who owes the next action, and how long have they been waiting?”

## Versioning transitions for replay

Give each accepted transition a new version within the document's workflow run:

```text
invoice-42: version 1 → DocumentUploaded      → extraction
invoice-42: version 2 → DocumentClassifiable  → classification
invoice-42: version 3 → DocumentClassified    → routing
```

The handoff API assigns the version and includes it in the outgoing event. A retry or replay keeps that event's original version and application event ID. This is a workflow sequence number; a separate schema version would describe the event's data format.

[EventBridge replay](https://docs.aws.amazon.com/eventbridge/latest/userguide/eb-replay-archived-event.html) can redeliver archived events, for example after a subscriber outage. Consumers can use the original identities to recognize work they have already completed. Replaying version 2 should not classify the document twice or move its tracked state backwards.

Versioning supports that protection, but each consumer must enforce it. A tracker showing the latest state can ignore older snapshots; a worker needs a durable record of completed work before skipping a duplicate. The [tracker follow-up](document-pipeline-workflow-tracker.md#transition-versions-and-replay) explains those checks and how to handle events arriving out of order.

## Seeing the workflow as a whole

A **workflow tracker** can query the shared records to show where each document is and how much work each service owns:

| Service | Documents assigned |
|---|---:|
| Extraction | 24 |
| Classification | 8 |
| Review | 137 |
| Finalization | 3 |

These illustrative counts include queued, running, and waiting work. Click Review to list its documents, oldest assignment first; open `invoice-42` to see its current status and handoff history.

The follow-up, [A Workflow Tracker for the EventBridge Pipeline](document-pipeline-workflow-tracker.md), explores those queries, a possible DynamoDB schema and indexes, and how to maintain service counts.

## Following one document

Extraction finishes, and classification identifies the invoice as needing a person's approval. Routing assigns it to review:

```text
emit("ReviewRequested", documentId="invoice-42",
     sender="routing", nextOwner="review")
```

The review service now owns the next action. The document can wait there for hours or days while the person decides. An EventBridge Scheduler timer could prompt the service to handle an expired review.

When the person approves, review hands the document to finalization:

```text
emit("DocumentApproved", documentId="invoice-42",
     sender="review", nextOwner="finalization")
```

Finalization stores the approved document and announces `DocumentFinalized`. The pipeline is complete, so there is no next owner.

Each service handles its own part of the process: review understands approval, and finalization understands storage. They share a small contract for events and handoffs.

## Other services can listen too

An event can have several listeners. In a strict ownership flow, only one service owns the next pipeline action; in an unowned flow, there is no designated owner.

For example, `DocumentApproved` could also update a dashboard, notify the uploader, or feed analytics. Those subscribers react independently. Adding an analytics subscriber does not require changing the review service.

This is where the event bus becomes useful beyond moving a document from one stage to another: the same business event can support new capabilities as the system grows.

## Durable functions still fit inside a stage

A service can use durable functions for its internal substeps, including parallel work and collecting results. From the rest of the pipeline's perspective, it still receives an assignment and emits a completion event.

EventBridge connects the services; durable functions can organize the work within a service.

## Example: enrichment and validation in parallel

Suppose an invoice arrives with `owner = null`. Both enrichment and validation subscribe to its arrival event, and both want to modify its content. With ownership checks disabled, both could read the same invoice, modify their own copies, and save them. One save could overwrite the other's changes. EventBridge routes the event to both services; it does not lock the invoice or choose which service may write.

For this case, assign the invoice to a processing stage that coordinates both operations. An AWS Lambda durable function can run the branches and wait for their results using its parallel operations. See [AWS's workflow orchestration guidance](https://docs.aws.amazon.com/lambda/latest/dg/with-step-functions.html).

```text
Processing stage owns the invoice
                |
       Read invoice version N
                |
         +------+------+
         |             |
     Enrichment    Validation
     returns patch returns findings/patch
         |             |
         +------+------+
                |
          Wait for both
                |
     Merge results, resolve conflicts
                |
     Save once, conditional on version N
                |
       Hand off to the next stage
```

Both branches receive the same input snapshot and return proposed changes instead of independently overwriting the shared invoice. The processing stage remains the owner throughout. Once both branches succeed, it combines their results and commits the content once. If both change the same field, the application needs an explicit merge rule or must reject the conflict; branch completion order should not decide the result.

The content save must atomically check the expected content version and the current processing claim. If the invoice changed or the claim is no longer valid, reject the save and reconcile or recompute the results. Here, version N identifies the content snapshot; it is separate from the handoff sequence number unless the application explicitly keeps them together. DynamoDB supports [atomic conditional writes](https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/WorkingWithItems.html#WorkingWithItems.ConditionalUpdate) for this protection.

This is **fan-out/fan-in**: start independent work in parallel, then collect its results before continuing. It is appropriate only if validation can inspect the original invoice. If validation must check the enriched content, run `enrichment → validation` sequentially instead.

Durable execution coordinates progress and recovery, but does not itself lock the invoice. The stage still needs an atomic worker claim to prevent duplicate deliveries from starting competing attempts, a recovery path for abandoned claims, and idempotent writes for retries. Commit the content before handing ownership onward, and make that handoff retryable; where they share a database, content, handoff state, and outbox intent can be committed in one transaction.

In this example, ownership stays with one stage while its internal operations run in parallel. An unowned event remains useful for independent subscribers such as analytics and notifications, but `owner = null` alone does not coordinate services that modify shared content.

## What the approach buys us

Services can evolve independently, new subscribers can react to existing events, and explicit ownership gives operators somewhere to start when a document gets stuck.

There is still coordination to build. Reliable handoffs, duplicate events, retries, and overdue work need handling. The shared `emit` API is a place to make those concerns reusable across services; EventBridge provides event routing, while the application supplies the workflow rules.

The choice is where to put that coordination. A durable workflow expresses the overall sequence in one place. Choreography spreads the sequence across services and their event contracts, giving each service responsibility for moving its part forward.
