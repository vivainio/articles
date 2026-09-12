# A Document Processing Pipeline with EventBridge Choreography

*2026-09-12*

The [durable-functions version](document-pipeline-durable-functions.md) of this pipeline puts one function in charge: a single `DurableContext` owns the whole flow, and every stage is a call that function makes. This is the other shape — no owner of the *business logic*. Split, OCR, classify, review-routing, and finalize are independent Lambdas, and none of them knows what the others do.

What they share is how a stage reports that it's done: one call, `emit(eventType, docId, ...fields)`. A stage never touches DynamoDB or EventBridge itself — `emit` is the entire interface between a stage and the rest of the system.

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

## Where this beats durable functions, and where it doesn't

Choreography wins when stages genuinely belong to different teams that shouldn't need to touch a shared owner to add a new subscriber — anyone can listen for `DocumentClassified` on the bus without coordinating with whoever owns the pipeline, even though every stage still funnels its own progress through the one `emit` call. That's a narrower thing to own than a durable execution's control flow: the orchestrator never decides what a stage does or in what order stages run, only that every transition gets logged and published consistently.

It loses everything the durable-execution runtime did for free: no checkpointing, no built-in wait, no bounded fan-out, no dedup, and no execution history unless `log` is actually wired into every stage — here it's the *only* record of a document's path, not a dashboard convenience alongside one the platform already gives you. All of it gets rebuilt with DynamoDB, EventBridge Scheduler, SQS, and conditional writes — each piece small, but each one now yours to get wrong. For a pipeline with one real owner and no reason for outside services to hook into the middle of it, that's a worse trade than a single durable function. It's the right shape specifically when "who else needs to react to this event" is a real, growing question.
