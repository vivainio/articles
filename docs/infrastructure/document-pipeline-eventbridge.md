# A Document Processing Pipeline with EventBridge Choreography

*2026-09-12*

The [durable-functions version](document-pipeline-durable-functions.md) of this pipeline puts one function in charge: a single `DurableContext` owns the whole flow, and every stage is a call that function makes. This is the other shape — no owner of the *business logic*. Each stage is an independent Lambda that does its own work — split, OCR, classify, review-routing, finalize — and none of them knows what the others do. That's choreography instead of orchestration.

What they do share is how a stage reports that it's finished: not by writing to DynamoDB and calling EventBridge itself, but by invoking one small Lambda — call it the orchestrator — and handing it the result. That Lambda is the only thing that ever touches the table and the only thing that ever calls `PutEvents`.

## The pipeline as events

Same stages as the durable version — split, OCR per page, classify, maybe review, finalize:

| detail-type | emitted by (via the orchestrator) | consumed by |
|---|---|---|
| `DocumentUploaded` | S3 event notification (via EventBridge) | split Lambda |
| `PageReady` (one per page) | split Lambda | OCR Lambda |
| `PageExtracted` | OCR Lambda | orchestrator's fan-in gate |
| `DocumentClassifiable` | orchestrator, once all pages are in | classify Lambda |
| `DocumentClassified` | classify Lambda | router (review or finalize) |
| `DocumentApproved` / `ReviewTimedOut` | approval Function URL / EventBridge Scheduler | orchestrator's race gate |

Every row's "emitted by" is really "asked the orchestrator to emit" — no stage Lambda holds an EventBridge client or a table handle directly.

## One Lambda owns the write and the publish

A stage Lambda's whole job is: do the work, then tell the orchestrator what happened. It invokes it directly — a synchronous Lambda-to-Lambda call, no HTTP hop, no bus round-trip for this part:

```python
def handler(event, context):
    detail = event["detail"]
    result = textract_service.extract(detail["page"])

    lambda_client.invoke(
        FunctionName="pipeline-orchestrator",
        InvocationType="Event",
        Payload=json.dumps({
            "documentId": detail["documentId"],
            "detailType": "PageExtracted",
            "payload": {"pageIndex": detail["pageIndex"], "text": result.text},
        }),
    )
```

The orchestrator's job, for every call it receives, is always the same three steps — append the audit-log entry, run whatever gate logic that `detailType` needs, and publish whatever event comes out the other end:

```python
def orchestrator_handler(event, context):
    document_id, detail_type, payload = event["documentId"], event["detailType"], event.get("payload", {})

    record_event(document_id, detail_type, payload)          # audit log + projection
    outcome = apply_gate(document_id, detail_type, payload)  # fan-in / race logic, or a no-op passthrough

    for next_event in outcome:
        events_client.put_events(Entries=[{
            "Source": "documents.pipeline",
            "DetailType": next_event["detailType"],
            "Detail": json.dumps(next_event["payload"]),
        }])
```

For a plain linear stage, `apply_gate` does nothing but forward: `PageReady` in, `PageReady` out, no state touched. For the two points that aren't linear, it's where the logic below actually lives. This is the same shape the durable article's "writers call an API, not the table" argument reaches for — centralizing the table schema in one place — applied here to the publish step as well, since in choreography there's no platform underneath doing that bookkeeping for you.

## Where linear choreography needs state

Two shapes break the "event carries everything, no shared state" model, and both live inside `apply_gate`:

**Fan-in.** `PageExtracted` fires once per page, but classification needs all of them, and no single event knows how many siblings exist or how many have already landed:

```python
def apply_gate(document_id, detail_type, payload):
    if detail_type != "PageExtracted":
        return [{"detailType": detail_type, "payload": payload}]

    resp = table.update_item(
        Key={"documentId": document_id},
        UpdateExpression="ADD pagesDone :one",
        ExpressionAttributeValues={":one": 1},
        ReturnValues="ALL_NEW",
    )
    if resp["Attributes"]["pagesDone"] == resp["Attributes"]["pagesTotal"]:
        return [{"detailType": "DocumentClassifiable", "payload": {"documentId": document_id}}]
    return []
```

This is the only place in the pipeline that needs a counter, not a general-purpose state machine, and it's now the orchestrator's problem, not the OCR Lambda's.

**Race resolution.** Approval and a review timeout are two independent triggers for the same document, and both can fire — a reviewer clicks "approve" moments before the scheduled timeout goes off. Whichever call reaches the orchestrator second has to no-op instead of also finalizing/archiving:

```python
    if detail_type in ("DocumentApproved", "ReviewTimedOut"):
        try:
            table.update_item(
                Key={"documentId": document_id},
                UpdateExpression="SET status = :decided",
                ConditionExpression="status = :pending",
                ExpressionAttributeValues={
                    ":decided": "approved" if detail_type == "DocumentApproved" else "rejected",
                    ":pending": "pending-review",
                },
            )
        except ClientError as e:
            if e.response["Error"]["Code"] == "ConditionalCheckFailedException":
                return []  # already decided by the other trigger
        return [{"detailType": detail_type, "payload": payload}]
```

Both cases reduce to the same thing: a join or a race needs exactly one piece of shared, checkable state per document, contended among only the gate branches actually racing on it — and because both branches live in the same orchestrator, that contention is explicit in one function instead of split across two Lambdas that each think they're the only writer.

## The audit log and current-state query

`record_event`, called on every single invocation regardless of `detailType`, is what makes the orchestrator also the audit log — not an optional add-on this time, since EventBridge itself keeps no memory of a document's path once each event has been delivered. Durable functions get execution history from the platform for free; here, this table is the only place that history exists at all.

Append-only: `document_id` as partition key, `timestamp#detailType` as sort key, one immutable item per call:

```python
def record_event(document_id, detail_type, payload):
    table.put_item(Item={
        "documentId": document_id,
        "sortKey": f"{int(time.time() * 1000)}#{detail_type}",
        "detailType": detail_type,
        "payload": payload,
    })
```

That answers "what happened to document X" as a query over one partition key. It doesn't answer "show me everything currently `pending-review`" cheaply — that needs knowing no *later* event exists for each document, which a log alone can't tell you without a scan. `record_event` also upserts a second item, `document_id` → `currentStage`, `updatedAt`, with a GSI on `currentStage`, so the dashboard query doesn't touch the log's shape at all.

## Threading context forward without re-passing it

A stage Lambda only knows the fields on the event that triggered it. Without help, that means `classify` has to manually forward `bucket`/`key` from three stages back just so `finalize` can still see them — every stage becomes responsible for re-threading fields it never actually uses. Since the orchestrator already reads and writes a per-document row for the current-state projection, it can do the threading instead: merge an allow-listed set of fields from each incoming payload into that row, then merge the row back into whatever it publishes.

```python
FORWARDED_FIELDS = {
    "DocumentUploaded": ("bucket", "key"),
    "DocumentClassified": ("classification",),
}

def record_event(document_id, detail_type, payload):
    table.put_item(Item={  # unchanged: append-only log entry
        "documentId": document_id,
        "sortKey": f"{int(time.time() * 1000)}#{detail_type}",
        "detailType": detail_type,
        "payload": payload,
    })

    fields = {k: payload[k] for k in FORWARDED_FIELDS.get(detail_type, ()) if k in payload}
    if fields:
        expr = ", ".join(f"context.#{k} = :{k}" for k in fields)
        context_table.update_item(
            Key={"documentId": document_id},
            UpdateExpression=f"SET {expr}",
            ExpressionAttributeNames={f"#{k}": k for k in fields},
            ExpressionAttributeValues={f":{k}": v for k, v in fields.items()},
        )

def enrich(document_id, payload):
    context = context_table.get_item(Key={"documentId": document_id}, ConsistentRead=True)
    return {**context.get("Item", {}).get("context", {}), **payload}
```

`orchestrator_handler` calls `enrich(document_id, next_event["payload"])` before publishing, so `DocumentClassifiable` goes out carrying `bucket`/`key` even though nothing between `split` and the fan-in gate ever touched them.

Two things keep this from turning into an unbounded blob: the allow-list is explicit per `detailType` — the orchestrator threads forward the handful of fields something downstream actually needs, not the raw payload of every event that ever fired for the document — and the read is strongly consistent, since a stage can call the orchestrator again moments after a previous call updated the same row and a stale read would silently drop a field that should already be there. If a field belongs to a fan-in (per-page text, say), it stays out of the allow-list entirely and out of `context` — that data lives in the log or in S3, referenced by pointer, not flattened into every event downstream.

## Waits and timeouts without a wait primitive

`context.wait(duration)` has no EventBridge equivalent — the bus doesn't hold anything between an event being published and a rule matching it. A review deadline needs something to actually schedule a future call: [EventBridge Scheduler](https://docs.aws.amazon.com/scheduler/latest/UserGuide/what-is-scheduler.html) creates a one-time schedule that invokes the orchestrator directly at a specific timestamp, the same way a stage Lambda would:

```python
scheduler_client.create_schedule(
    Name=f"review-timeout-{document_id}",
    ScheduleExpression=f"at({timeout_timestamp})",
    Target={
        "Arn": ORCHESTRATOR_FUNCTION_ARN,
        "RoleArn": SCHEDULER_ROLE_ARN,
        "Input": json.dumps({"documentId": document_id, "detailType": "ReviewTimedOut", "payload": {}}),
    },
    FlexibleTimeWindow={"Mode": "OFF"},
)
```

Targeting the orchestrator's function ARN instead of routing back through EventBridge means the timeout gets the same audit-log entry and the same race-gate treatment as every other call — there's no separate "did this get logged" question for the timeout path. If approval arrives first, the approval handler deletes the schedule (`scheduler_client.delete_schedule`) as a courtesy; the conditional write in the race gate already makes a late `ReviewTimedOut` a no-op even if the delete is skipped or races.

## Human approval, one hop later

The durable version's Function URL calls `SendDurableExecutionCallbackSuccess` with a callback ID. Here there's no execution to call back into — the Function URL checks the click is legitimate and invokes the orchestrator, same as any other stage:

```python
def handler(event, context):
    if not verify_signed_link(event):
        return {"statusCode": 403}

    document_id = event["queryStringParameters"]["documentId"]
    lambda_client.invoke(
        FunctionName="pipeline-orchestrator",
        InvocationType="Event",
        Payload=json.dumps({"documentId": document_id, "detailType": "DocumentApproved", "payload": {}}),
    )
    return {"statusCode": 200}
```

Same reason a Function URL is needed at all — a browser can't hold IAM credentials to call the orchestrator itself — but the authorization model is now "does this Lambda's own logic accept the click," not "does IAM authorize this specific callback ID against this specific execution." That's less machinery, but also less for free: the durable version got per-execution authorization from the platform; here the Function URL's handler is fully responsible for making sure `documentId` isn't just guessable from the URL.

## Bounded fan-out without `context.map`

`context.map(..., config=MapConfig(max_concurrency=5))` gave the durable pipeline a hard cap on simultaneous Textract calls, checkpointed per page. The orchestrator doesn't help here — it sits downstream of the OCR Lambda, not in front of it — so the cap still has to come from an SQS queue between the `PageReady` rule and the OCR Lambda, with the Lambda's event-source-mapping batch size and reserved concurrency doing the throttling. A 200-page document still enqueues 200 messages instantly, but only 5 are ever in flight against Textract at once. The checkpoint-per-page property is gone, though: if the Lambda crashes mid-batch, SQS redelivers the whole message (page) from scratch, since the only durable record of "this page is done" is the `PageExtracted` call that made it to the orchestrator.

## Idempotency and at-least-once delivery

Durable functions gave two guarantees for free: deduped execution starts and non-re-running completed steps. Neither the `lambda_client.invoke` calls nor EventBridge give any of that — both are at-least-once, so the orchestrator can receive the same `PageExtracted` call twice. `record_event`'s append is harmless either way (a duplicate log line, no different from an audit log seeing the same thing twice), but the fan-in gate's `ADD pagesDone :one` is not — a duplicate delivery double-counts a page and the fan-in fires early or never. That gate needs its own idempotency key:

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

catching the conditional-check failure as "already counted, ignore." Any gate branch that isn't a pure append needs this same treatment — there's no runtime doing it underneath, the way checkpointed steps did.

## Where this beats durable functions, and where it doesn't

Choreography wins when the stages genuinely belong to different teams or services that shouldn't need to touch a shared orchestrator *function* to add a new subscriber — anyone can listen for `DocumentClassified` on the bus without coordinating with whoever owns the pipeline, even though every stage that *reports progress* funnels through the one small Lambda above. That's a narrower, cheaper thing to own than a durable execution's control flow: the orchestrator here never decides what a stage does or in what order stages run, only that every transition gets logged and published consistently.

It loses on everything the durable-execution runtime was doing for free: no checkpointing, no built-in wait, no bounded fan-out, no dedup, and — unlike the durable version, where the DynamoDB log was an optional dashboard convenience — no execution history unless the orchestrator's `record_event` is actually wired into every stage, since here it's the *only* record of a document's path, not a nice-to-have alongside one the platform already gives you. All of that was rebuilt here with DynamoDB, EventBridge Scheduler, SQS, and conditional writes — each piece small, but each one now code you own and can get wrong. For a pipeline with one real owner and no reason for arbitrary other services to hook into the middle of it, that's a worse trade than a single durable function. It's the right shape specifically when "who else needs to react to this event" is a real, growing question.
