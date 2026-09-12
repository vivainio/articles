# A Document Processing Pipeline with EventBridge Choreography

*2026-09-12*

The [durable-functions version](document-pipeline-durable-functions.md) of this pipeline puts one function in charge: a single `DurableContext` owns the whole flow, and every stage is a call that function makes. This is the other shape — no owner. Each stage is an independent Lambda subscribed to an EventBridge rule; it does its work and fires an event, and whichever Lambdas are listening for that event type do their own work in turn. Nobody holds the control flow. That's choreography instead of orchestration, and it changes what you have to build by hand.

Most of a pipeline like this turns out to need nothing extra — an event carries what the next subscriber needs, and the rule's pattern match *is* the routing logic. The discipline is knowing exactly which two or three points stop being linear.

## The pipeline as events

Same stages as the durable version — split, OCR per page, classify, maybe review, finalize — but each is a Lambda triggered by a rule matching a `detail-type` on one bus, emitting the next `detail-type` when it's done:

| detail-type | emitted by | consumed by |
|---|---|---|
| `DocumentUploaded` | S3 event notification (via EventBridge) | split Lambda |
| `PageReady` (one per page) | split Lambda | OCR Lambda |
| `PageExtracted` | OCR Lambda | fan-in counter |
| `DocumentClassifiable` | fan-in counter | classify Lambda |
| `DocumentClassified` | classify Lambda | router (review or finalize) |
| `ReviewTimeoutScheduled` | router | EventBridge Scheduler |
| `DocumentApproved` / `DocumentRejected` | approval Function URL | finalize/archive Lambda |

No item in this table is a "coordinator" — each Lambda knows only the event type it subscribes to and the event type it emits.

## The linear stages

A rule is just a pattern match on `source` and `detail-type`:

```json
{
    "source": ["documents.pipeline"],
    "detail-type": ["PageReady"]
}
```

The OCR Lambda behind that rule does one page and emits the next event — no different from a plain message-passing system:

```python
def handler(event, context):
    detail = event["detail"]
    result = textract_service.extract(detail["page"])

    events_client.put_events(Entries=[{
        "Source": "documents.pipeline",
        "DetailType": "PageExtracted",
        "Detail": json.dumps({
            "documentId": detail["documentId"],
            "pageIndex": detail["pageIndex"],
            "text": result.text,
        }),
    }])
```

That's the whole stage. It has no idea how many pages the document has, doesn't know what happens after classification, and doesn't need to.

## Where linear choreography needs state

Two shapes break the "event carries everything, no shared state" model:

**Fan-in.** `PageExtracted` fires once per page, but classification needs all of them, and no single event knows how many siblings exist or how many have already landed. A DynamoDB item per document (`document_id` → `pages_total`, `pages_done`) updated by each `PageExtracted` handler, emitting `DocumentClassifiable` only when `pages_done == pages_total`, is the minimum viable version:

```python
def handler(event, context):
    detail = event["detail"]
    resp = table.update_item(
        Key={"documentId": detail["documentId"]},
        UpdateExpression="ADD pagesDone :one",
        ExpressionAttributeValues={":one": 1},
        ReturnValues="ALL_NEW",
    )
    if resp["Attributes"]["pagesDone"] == resp["Attributes"]["pagesTotal"]:
        events_client.put_events(Entries=[{
            "Source": "documents.pipeline",
            "DetailType": "DocumentClassifiable",
            "Detail": json.dumps({"documentId": detail["documentId"]}),
        }])
```

This is the only place in the pipeline that needs a counter, not a general-purpose state machine.

**Race resolution.** Approval and a review timeout are two independent triggers for the same document, and both can fire — a reviewer clicks "approve" moments before the scheduled timeout goes off. Whichever handler runs second has to check "has this document already been decided?" and no-op, or the pipeline double-finalizes or finalizes-then-archives. A conditional write against the same per-document item handles it:

```python
try:
    table.update_item(
        Key={"documentId": document_id},
        UpdateExpression="SET status = :decided",
        ConditionExpression="status = :pending",
        ExpressionAttributeValues={":decided": "approved", ":pending": "pending-review"},
    )
except ClientError as e:
    if e.response["Error"]["Code"] == "ConditionalCheckFailedException":
        return  # already decided by the other trigger
```

Both cases reduce to the same thing: a join or a race needs exactly one piece of shared, checkable state per document, touched only by the handlers actually contending on it. Everywhere else, keep the linear event-to-subscriber shape.

## Waits and timeouts without a wait primitive

`context.wait(duration)` has no EventBridge equivalent — the bus doesn't hold anything between an event being published and a rule matching it. A review deadline needs something to actually schedule a future event: [EventBridge Scheduler](https://docs.aws.amazon.com/scheduler/latest/UserGuide/what-is-scheduler.html) creates a one-time schedule that fires `ReviewTimedOut` at a specific timestamp, targeting the same PutEvents call a `wait_for_callback` timeout would have produced:

```python
scheduler_client.create_schedule(
    Name=f"review-timeout-{document_id}",
    ScheduleExpression=f"at({timeout_timestamp})",
    Target={
        "Arn": EVENTBRIDGE_PUT_EVENTS_TARGET_ARN,
        "RoleArn": SCHEDULER_ROLE_ARN,
        "EventBridgeParameters": {"DetailType": "ReviewTimedOut", "Source": "documents.pipeline"},
        "Input": json.dumps({"documentId": document_id}),
    },
    FlexibleTimeWindow={"Mode": "OFF"},
)
```

If approval arrives first, the approval handler deletes the schedule (`scheduler_client.delete_schedule`) as part of the same conditional-write transaction from the race-resolution case above — belt-and-suspenders, since the conditional write already makes a late `ReviewTimedOut` a no-op even if the delete is skipped or races.

## Human approval, one hop later

The durable version's Function URL calls `SendDurableExecutionCallbackSuccess` with a callback ID. Here there's no execution to call back into — the Function URL just does what any other stage does, checks the click is legitimate, and publishes an event:

```python
def handler(event, context):
    if not verify_signed_link(event):
        return {"statusCode": 403}

    document_id = event["queryStringParameters"]["documentId"]
    events_client.put_events(Entries=[{
        "Source": "documents.pipeline",
        "DetailType": "DocumentApproved",
        "Detail": json.dumps({"documentId": document_id}),
    }])
    return {"statusCode": 200}
```

Same reason a Function URL is needed at all — a browser can't hold IAM credentials to call PutEvents itself — but the authorization model is now "does this Lambda's own logic accept the click," not "does IAM authorize this specific callback ID against this specific execution." That's less machinery, but also less for free: the durable version got per-execution authorization from the platform; here the Function URL's handler is fully responsible for making sure `documentId` isn't just guessable from the URL.

## Bounded fan-out without `context.map`

`context.map(..., config=MapConfig(max_concurrency=5))` gave the durable pipeline a hard cap on simultaneous Textract calls, checkpointed per page. EventBridge rules invoke Lambda directly with no concurrency knob of their own, so the cap has to come from somewhere else — an SQS queue between the rule and the OCR Lambda, with the Lambda's event-source-mapping batch size and the function's reserved concurrency doing the throttling:

```json
{
    "Source": ["documents.pipeline"],
    "DetailType": ["PageReady"]
}
```
routed to an SQS queue as the rule's target, with the OCR Lambda's reserved concurrency set to 5. A 200-page document still enqueues 200 messages instantly, but only 5 are ever in flight against Textract at once — the checkpoint-per-page property is gone, though: if the Lambda crashes mid-batch, SQS redelivers the whole message (page) from scratch, since there's no per-item completion record short of the `PageExtracted` event itself having gone out.

## Idempotency and at-least-once delivery

Durable functions gave two guarantees for free: deduped execution starts and non-re-running completed steps. EventBridge gives neither — it's at-least-once delivery, so any handler can run twice for the same event. The `PageExtracted` counter update above is safe as written (an `ADD` is not idempotent by itself, but a duplicate delivery would double-count a page and the fan-in would fire early or never) — in practice that update needs a per-page idempotency key too:

```python
table.update_item(
    Key={"documentId": document_id},
    UpdateExpression="ADD pagesDone :one, processedPages :page_set",
    ConditionExpression="NOT contains(processedPages, :page)",
    ExpressionAttributeValues={
        ":one": 1,
        ":page_set": {page_index},
        ":page": page_index,
    },
)
```

catching the conditional-check failure as "already counted, ignore." Every handler in the chain that isn't purely stateless read-and-forward needs this same treatment — there's no runtime doing it underneath, the way checkpointed steps did.

## Where this beats durable functions, and where it doesn't

Choreography wins when the stages genuinely belong to different teams or services that shouldn't need to touch a shared orchestrator to add a new subscriber — anyone can listen for `DocumentClassified` without coordinating with whoever owns the pipeline. It's also the natural fit if some of those stages already publish EventBridge events for other reasons; there's no separate integration layer to build.

It loses on everything the durable-execution runtime was doing for free: no checkpointing, no execution history to inspect when a document gets stuck, no built-in wait, no bounded fan-out, no dedup. All five had to be rebuilt here with DynamoDB, EventBridge Scheduler, SQS, and conditional writes — each one small, but each one now code you own and can get wrong. For a pipeline with one real owner and no reason for arbitrary other services to hook into the middle of it, that's a worse trade than a single durable function. It's the right shape specifically when "who else needs to react to this event" is a real, growing question.
