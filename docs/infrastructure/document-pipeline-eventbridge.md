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
emit("DocumentUploaded", documentId="invoice-42", owner="extraction")
```

Once extraction has the document's text, it hands over to classification:

```text
emit("DocumentClassifiable", documentId="invoice-42", owner="classification")
```

These are conceptual calls. `emit` is our application's handoff API, built around EventBridge.

The key idea is **one owner for the document's next required action**. After upload, extraction owes the next action. After extraction, classification does. The handoff records who is responsible next and arranges delivery of the event.

EventBridge routes events; the application keeps track of responsibility. A shared record in a database such as DynamoDB could show:

```text
document: invoice-42
owner: review
status: waiting for approval
```

That makes a useful operational question easy to answer: “Who owes the next action, and how long have they been waiting?”

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
emit("ReviewRequested", documentId="invoice-42", owner="review")
```

The review service now owns the next action. The document can wait there for hours or days while the person decides. An EventBridge Scheduler timer could prompt the service to handle an expired review.

When the person approves, review hands the document to finalization:

```text
emit("DocumentApproved", documentId="invoice-42", owner="finalization")
```

Finalization stores the approved document and announces `DocumentFinalized`. The pipeline is complete, so there is no next owner.

Each service handles its own part of the process: review understands approval, and finalization understands storage. They share a small contract for events and handoffs.

## Other services can listen too

An event can have several listeners while only one service owns the next pipeline action.

For example, `DocumentApproved` could also update a dashboard, notify the uploader, or feed analytics. Those subscribers react independently. Adding an analytics subscriber does not require changing the review service.

This is where the event bus becomes useful beyond moving a document from one stage to another: the same business event can support new capabilities as the system grows.

## Durable functions still fit inside a stage

A service can use durable functions for its internal substeps, including parallel work and collecting results. From the rest of the pipeline's perspective, it still receives an assignment and emits a completion event.

EventBridge connects the services; durable functions can organize the work within a service.

## What the approach buys us

Services can evolve independently, new subscribers can react to existing events, and explicit ownership gives operators somewhere to start when a document gets stuck.

There is still coordination to build. Reliable handoffs, duplicate events, retries, and overdue work need handling. The shared `emit` API is a place to make those concerns reusable across services; EventBridge provides event routing, while the application supplies the workflow rules.

The choice is where to put that coordination. A durable workflow expresses the overall sequence in one place. Choreography spreads the sequence across services and their event contracts, giving each service responsibility for moving its part forward.
