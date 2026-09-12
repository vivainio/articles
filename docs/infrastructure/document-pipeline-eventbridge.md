# A Document Processing Pipeline with EventBridge Choreography

*2026-09-12*

The [durable-functions version](document-pipeline-durable-functions.md) of this pipeline puts one function in charge: a single `DurableContext` owns the whole flow, and every stage is a call that function makes. This is the other shape — no owner of the *business logic*. Split, OCR, classify, review-routing, and finalize are independent Lambdas, and none of them knows what the others do.

What they share is how a stage reports that it's done: one call, `emit(eventType, docId, ...fields)`. A stage never touches DynamoDB or EventBridge itself — `emit` is the entire interface between a stage and the rest of the system.

Worth separating two reasons the orchestrator exists, because they don't kick in at the same time. The audit log and the "everything currently pending-review" dashboard are worth having from the very first two events — even a `DocumentReadyForOcr` → `DocumentOcrDone` flow with no fan-in and nothing to race benefits from every transition being recorded somewhere queryable, and that's true regardless of how simple the flow is. The gate logic — fan-in counters, race resolution — only shows up once a flow actually has a join or two triggers competing for the same outcome; for a plain linear chain, `gate` is just a passthrough and the orchestrator is doing nothing but logging and re-publishing.

## The pipeline as events

| event | emitted by | consumed by |
|---|---|---|
| `DocumentUploaded` | S3 notification | split |
| `PageReady` (one per page) | split | OCR |
| `PageExtracted` | OCR | fan-in gate |
| `DocumentClassifiable` | fan-in gate, once all pages are in | classify |
| `DocumentClassified` | classify | router (review or finalize) |
| `DocumentApproved` / `ReviewTimedOut` | approval link / scheduled timeout | race gate |

## Calling it: `emit(...)`

This is the interesting part — every stage's whole contract with the pipeline:

```
# split, after splitting the file
emit(DocumentUploaded, docId, bucket, key)

# OCR, after one page
emit(PageExtracted, docId, pageIndex, text)

# classify
emit(DocumentClassified, docId, classification)

# approval link
emit(DocumentApproved, docId)

# scheduled timeout, instead of a person
emit(ReviewTimedOut, docId)
```

`emit` invokes the orchestrator Lambda. What the orchestrator does with the call is comparatively uninteresting — log it, run a gate, publish whatever comes out:

```
orchestrator(eventType, docId, fields):
    log(docId, eventType, fields)
    for out in gate(eventType, docId, fields):
        publish(out.eventType, out.docId, out.fields)
```

## Where linear choreography needs state

Two gates are the only non-trivial logic in the whole thing.

**Fan-in** — nothing else knows when all the pages are in:

```
gate(PageExtracted, docId, fields):
    done = incr_counter(docId, fields.pageIndex)   # idempotent: ignores a page seen before
    if done == total_pages(docId):
        yield DocumentClassifiable(docId)
```

**Race** — approval and a timeout can both fire for the same document:

```
gate(DocumentApproved | ReviewTimedOut, docId, fields):
    if claim_decision(docId, eventType):   # conditional write, first writer wins
        yield (eventType, docId, fields)
    # else: already decided, no-op
```

Everywhere else, `gate` just re-yields its input unchanged — the orchestrator's log-and-publish wrapper still runs, but nothing contends on shared state.

The DynamoDB counter and conditional write above are one way to implement these two gates, not the definition of the pattern — from outside, a gate is still just event(s) in, event(s) out, and nothing downstream needs to know what happened inside it. A durable execution works just as well as the internals of either: the fan-in gate could be one execution per document (`executionName=docId`) whose whole body is `context.map(ocr_step, pages, config=MapConfig(max_concurrency=5))`, letting the platform's checkpointing stand in for `incr_counter`; the race gate could be an execution that does nothing but `context.wait_for_callback(timeout=...)` and returns whichever came first, letting the runtime resolve the race instead of a conditional write. Either way it's one stage's implementation detail, the same way "call Textract" is — it doesn't make this "a durable-functions pipeline with EventBridge wrapped around it," any more than a stage calling DynamoDB makes the whole thing "a DynamoDB pipeline."

## The log doubles as the audit trail

EventBridge itself keeps no memory of a document's path once an event's delivered, so `log` is the only history that exists:

```
log(docId, eventType, fields):
    append(docId, timestamp, eventType, fields)      # immutable, one item per call
    upsert_projection(docId, currentStage=eventType)  # answers "everything pending-review" without a scan
```

## Threading context forward

A stage only sees the fields on the event that triggered it — without help, `classify` would have to manually re-forward `bucket`/`key` three stages later just so `finalize` can still see them. `log` merges an allow-listed set of fields into a per-document context row instead, and `publish` merges that row back in:

```
log(docId, eventType, fields):
    append(...)
    merge_into_context(docId, allowlist(eventType, fields))

publish(eventType, docId, fields):
    put_events(eventType, docId, {**context_of(docId), **fields})
```

Keep the allow-list explicit per event type — the whole raw payload of every event ever fired would blow past DynamoDB's item size and EventBridge's event size limits. Per-page OCR text stays out of it entirely; that lives in the log (or S3), referenced by pointer, not flattened into every later event.

## Waits and timeouts without a wait primitive

No `context.wait(duration)` equivalent — something has to actually schedule a future call. EventBridge Scheduler creates a one-time schedule that calls `emit` directly:

```
schedule_once(at=deadline, call=emit(ReviewTimedOut, docId))
```

If approval wins the race, cancel the schedule as a courtesy — the conditional write in the race gate already makes a late timeout a no-op even if the cancel is skipped.

## Human approval, one hop later

No callback ID to authorize against, so the Function URL just checks the click and emits:

```
handler(request):
    if not verify_signed_link(request): return 403
    emit(DocumentApproved, docId)
```

Durable functions got per-execution authorization from the platform for that call; here the handler alone is responsible for `docId` not being guessable from the URL.

## Bounded fan-out without `context.map`

The orchestrator sits downstream of OCR, not in front of it, so it can't cap concurrency. That still needs an SQS queue between the `PageReady` rule and OCR, with reserved concurrency on the function doing the throttling — a 200-page document enqueues instantly but only a handful run at once. The checkpoint-per-page property is gone: if OCR crashes mid-page, SQS redelivers the whole message, since the only durable record of "this page is done" is the `PageExtracted` call that already reached the orchestrator.

## Idempotency and at-least-once delivery

`emit` and EventBridge are both at-least-once, so any gate touching shared state needs its own dedup — `incr_counter` above only counts a `pageIndex` it hasn't seen, and `claim_decision` is a conditional write for the same reason. A gate that just re-yields its input needs nothing extra; a gate that mutates state does, since nothing underneath is doing that for it the way checkpointed steps did.

It's not just retry-until-delivered on the bus-to-target hop, either: `PutEvents` itself has no idempotency token — nothing like SQS FIFO's `MessageDeduplicationId` — so a retried `emit` call after a dropped response is indistinguishable from two genuinely separate events. There's no layer anywhere in this chain that will collapse a duplicate for you; the gates above are doing real work, not defensive overkill.

## Scaling to a million documents

The durable article answered this with "one execution per document, and the platform carries it" — but a durable execution is still a resident thing: it counts against a documented concurrency quota (1,000,000 concurrently *running* executions, including ones parked in a review wait) and each one is capped at 3,000 operations and 100MB of checkpointed payload. Choreography has no equivalent object to cap, because nothing is resident. A document sitting in `pending-review` isn't occupying any AWS-managed workflow slot — it's a few hundred bytes in a DynamoDB item, and between events, that's the *entire* footprint. There's no "concurrently waiting workflows" ceiling to raise, because there's no workflow anywhere to count.

What actually limits this design at volume is ordinary infrastructure math instead: DynamoDB throughput on whatever partition key the tables use (spread across `docId`, this scales horizontally same as any other table), and Lambda's regional concurrency for however many stages are *actively* running at a given instant — not how many documents are merely waiting on something. A million documents parked in review at once cost a million small items sitting idle; a million durable executions parked the same way are each still a tracked, quota-consuming platform object even while suspended.

## Where this beats durable functions, and where it doesn't

Two real wins, not one: no shared owner services need to coordinate with to add a subscriber — anyone can listen for `DocumentClassified` without touching whoever owns the pipeline — and no platform-level ceiling on how many documents can be in flight, since a waiting document is just data, not a resource. What the orchestrator does own is narrow: not what a stage does or in what order stages run, only that every transition gets logged and published consistently.

The price is everything the durable-execution runtime did for free: no checkpointing, no built-in wait, no bounded fan-out, no dedup, and no execution history unless `log` is actually wired into every stage — here it's the *only* record of a document's path, not a dashboard convenience alongside one the platform already gives you. All of it gets rebuilt with DynamoDB, EventBridge Scheduler, SQS, and conditional writes — each piece small, but each one now yours to get wrong. For a pipeline with one real owner, no reason for outside services to hook into the middle of it, and volume nowhere near durable execution's quota, that's a worse trade than a single durable function. It's the right shape when either "who else needs to react to this event" or "how many of these can be in flight at once" is a real, growing question.
