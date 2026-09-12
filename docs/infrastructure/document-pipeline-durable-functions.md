# A Document Processing Pipeline with Lambda Durable Functions

*2026-09-11*

Document pipelines are the canonical case for durable orchestration: a file lands in a bucket, you extract and classify it, sometimes a human has to sign off, and only then does it get filed away. The steps are simple; the plumbing to survive a multi-hour approval wait, a Textract throttle, or a cold restart is not. Historically that plumbing was a Step Functions state machine with a pile of ASL JSON, or a hand-rolled DynamoDB table tracking which stage each document was in. AWS Lambda's [durable execution](https://docs.aws.amazon.com/lambda/latest/dg/durable-getting-started.html) feature collapses most of that into a decorator and a context object — you write the pipeline as one function, and the runtime checkpoints it for you.

This is a walkthrough of building that pipeline, plus where durable functions genuinely replace Step Functions and where they don't.

## What a durable function actually is

You mark a handler `@durable_execution` and it receives a `DurableContext` alongside the usual event:

```python
from aws_durable_execution_sdk_python import DurableContext, durable_execution

@durable_execution
def lambda_handler(event, context: DurableContext):
    ...
```

Everything interesting happens through `context`:

- **`context.step(fn, name=...)`** runs a unit of work and checkpoints the result. If the execution is interrupted and replayed, steps that already completed return their stored result instead of re-running.
- **`context.wait(duration)`** suspends the execution — for seconds or for weeks. While suspended, the environment is recycled and you are not billed for compute.
- **`context.map(fn, items, config=MapConfig(max_concurrency=N))`** fans a step out over a list with bounded concurrency, still checkpointed per item.
- **`context.wait_for_callback(...)`** pauses until an external system posts a result back in, with a timeout.

The mental model is replay-based: on every resume, your function body runs again from the top, but each `context.step()` call short-circuits to its saved result until execution reaches the point it actually needs to resume from. That's why step bodies have to be idempotent — a step can be attempted more than once before its checkpoint is durably recorded, even though you'll never see a *completed* step re-run.

## A note on terminology

"Step" gets overloaded fast once a pipeline has business stages that don't map cleanly onto `context.step()`, so it's worth pinning down what everything in this article actually means before going further:

- **Step** — specifically `context.step(fn, name=...)`. Runs *inline*, in the current invocation, and returns before the function moves on. It never suspends the execution and never involves anything outside this Lambda environment. "Extract text from this page" is a step.
- **Stage** — an informal term for a phase of the *business* workflow ("extraction," "review," "indexing"), used in this article when talking about the pipeline's shape rather than the SDK. A stage might be implemented as one step, or as a wait, an invoke, a `wait_for_callback`, or a `map` over several of those — the word doesn't imply a particular primitive.
- **Execution** — one running instance of the whole durable function, from its first invocation to its final return. It has an identity (an execution name, for the idempotent-start dedup covered earlier) and can be suspended and resumed many times over a lifetime that might span days.
- **Orchestrator** — this article's name for the durable execution that owns the pipeline's overall control flow — the thing deciding what happens next, not a specific SDK type. Everything in "The pipeline" section runs inside the orchestrator.
- **Hand-off** — what happens when a stage's work isn't done by code running inside the orchestrator's own invocation, but by something else the orchestrator has to suspend and wait on: another Lambda function, an external service, a human. This is the case this section's "Step vs. hand-off" split below is about.
- **Callback** — the specific mechanism (`wait_for_callback`, and the `SendDurableExecutionCallback*` API on the other end) by which a hand-off to something that *doesn't* return a value directly reports its result back into a suspended orchestrator.

The distinction that actually matters for how you write the code: **is the next stage something the orchestrator calls, or something the orchestrator calls out to and gets called back by?** A stage that's pure logic, or a synchronous call to a Lambda function whose ARN you have, is a step or an `invoke` — the orchestrator is in the driver's seat the whole time. A stage that's a human, an asynchronous external process, or anything whose completion doesn't arrive as a direct return value needs a hand-off via `wait_for_callback` — the orchestrator suspends and something else has to actively reach back in.

## The pipeline

Take a document upload pipeline: extract text per page, classify the document, route anything sensitive or low-confidence to a human reviewer, then finalize. In plain durable-function code:

```python
from aws_durable_execution_sdk_python import (
    DurableContext,
    durable_execution,
    WaitConfig,
)
from aws_durable_execution_sdk_python.config import MapConfig

@durable_execution
def lambda_handler(event, context: DurableContext):
    document_id = event["documentId"]
    bucket, key = event["bucket"], event["key"]

    # Step 1: split into pages, checkpointed once
    pages = context.step(
        lambda _: split_service.split_pages(bucket, key),
        name="split-pages",
    )

    # Step 2: OCR each page in parallel, bounded so we don't blow
    # through Textract's TPS limit
    def ocr_page(ctx, page, index):
        return ctx.step(
            lambda _: textract_service.extract(page),
            name=f"ocr-page-{index}",
        )

    ocr_results = context.map(
        ocr_page,
        pages,
        name="ocr-pages",
        config=MapConfig(max_concurrency=5),
    )

    # Step 3: classify using the combined text
    classification = context.step(
        lambda _: classifier_service.classify(ocr_results.get_results()),
        name="classify-document",
    )

    # Step 4: route for human review if required
    if classification["requiresReview"]:
        def notify_reviewer(callback_id):
            notification_service.send_review_request(
                document_id=document_id,
                reviewers=classification["reviewers"],
                callback_id=callback_id,
            )

        approval = context.wait_for_callback(
            notify_reviewer,
            name="review-callback",
            config=WaitConfig(timeout=86400),  # up to 24h, no compute billed while waiting
        )

        if not (approval and approval.get("approved")):
            context.step(
                lambda _: document_service.archive(document_id, approval.get("reason") if approval else "timed_out"),
                name="archive-rejected",
            )
            return {"documentId": document_id, "status": "rejected"}

    # Step 5: finalize and store
    finalized = context.step(
        lambda _: document_service.finalize(document_id, classification),
        name="finalize-document",
    )

    return {"documentId": document_id, "status": "finalized", "storedAt": finalized["location"]}
```

A few things worth calling out:

- The `context.map` bound to `max_concurrency=5` limits concurrent page work within one document. It does not bound aggregate Textract traffic across documents, and concurrency is not a requests-per-second limit. Shared downstream quotas still need admission control or rate limiting and retry backoff. Completed page steps replay from their saved results.
- The review wait can legitimately sit for a day. Nothing is polling, no Lambda instance is warm and billing — the execution is suspended and resumed when the callback arrives.
- Rejection and approval are just branches in ordinary code. There's no separate "choice state" to wire up.

## Scaling to a million documents

The natural question once this is a real pipeline: what happens at volume — a million documents landing over a day, each going through its own extract/classify/review/finalize? The instinct is often to build a coordinator — one Lambda that tracks every document's stage in a DynamoDB table and drives them forward. For this system, that instinct is backwards, and the relevant numbers explain why:

- **A single durable execution is capped at 3,000 operations (steps, waits, callbacks) and 100 MB of cumulative checkpointed payload.** A coordinator execution trying to drive a million documents through their own `context.map`/`context.step` calls would blow through 3,000 operations after a few hundred documents, long before it reached the millionth.
- **The platform already scales to that concurrency without one.** The current [documented quota](https://docs.aws.amazon.com/lambda/latest/dg/gettingstarted-limits.html) for concurrently *running* durable executions — including suspended review waits — is 5 million per Region, or 10 million in the specified higher-quota Regions, with increases available. This is a capacity limit, not a throughput guarantee: starts, checkpoints, callbacks, active Lambda compute, and downstream services have their own limits.

So the right shape is **one durable execution per document**, not one coordinator fanning out over many. Start each with `executionName` set to the document ID (the idempotent-start dedup from earlier), and let a million of them run independently, each suspended or progressing on its own schedule. The fan-out, checkpointing, and resumption-on-callback that a hand-rolled coordinator would have to implement is exactly what the durable-execution runtime is already doing for every one of those executions — building a coordinator on top would mean re-implementing the scheduler underneath it.

DynamoDB still has a job here, just a narrower one: as a **read-model, not an orchestrator**. Each per-document execution writes its own status (`extracting`, `pending-review`, `done`) into a table keyed by `document_id` as a side effect of its steps. That gives you a queryable "show me everything stuck in review right now" or a dashboard — something the Lambda execution APIs don't give you cheaply across a million separate executions — without that table ever deciding what happens next for any document.

## Letting downstream services report their own progress

The pipeline's own steps aren't the only writers to that table — the indexing service, a reviewer's approval, any hand-off from the "Callbacks aren't just for humans" section can all contribute a status update as they finish their piece. Two decisions matter here that are easy to get wrong once multiple independent services are writing:

**Keep an append-only history alongside current state.** Give each reported event a stable identity, document/run identity, and causation metadata. Timestamps alone do not guarantee unique keys or causal order. Separate history entries avoid overwriting previous reports, but concurrent writers and late events still require explicit rules for updating current state. Store large results by immutable S3 reference. Define retention and access controls for the history rather than treating an audit trail as automatic.

**Writers call an API, not the table.** Rather than handing every downstream service its own IAM grant to `PutItem` on the tracking table, put a single Lambda in front of it — invoked directly by services running inside your account, and reachable through the same thin Function-URL translator as the callback API for anything external (a third-party webhook app can hit that translator the same way it would to resolve a callback; the translator is a natural place to do both jobs). That Lambda is the only thing that ever touches the table directly, which means the schema is owned in one place and can change without touching every downstream service's code — the callers just know "call this function with a document ID, a stage name, and a payload."

An append-only log does not by itself answer "which documents are currently pending review?" Maintain a current-state projection for that query, but derive it from accepted transitions rather than the last report to arrive. One recording Lambda still has concurrent invocations. Use transactional or conditional updates, stable event IDs, and processing-run versions to prevent stale reports from regressing state. A dashboard index may be eventually consistent; it must not arbitrate workflow decisions.

Recording a completion and resolving a callback are separate writes. If both are required, durably accept the report and persist a retryable callback-delivery intent, then reconcile uncertain results. Otherwise a crash between the calls can leave the dashboard and execution disagreeing. Callback acceptance also needs to be distinguished from a late report received after timeout.

The [EventBridge companion](document-pipeline-eventbridge.md) makes the responsible service explicit through ownership handoffs. A durable execution can also publish domain events for independent subscribers or implement the internal work of one such service. Required workflow control and optional event subscriptions need not use the same mechanism.

## How the callback actually gets resumed

`context.wait_for_callback` hands your notification function a `callback_id`. Whatever you do with it — email a link, post a Slack button, whatever — the reviewer's action has to end up calling back into Lambda with that ID. The external caller needs IAM permission scoped to the specific execution:

```json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "SendCallbacks",
            "Effect": "Allow",
            "Action": [
                "lambda:SendDurableExecutionCallbackSuccess",
                "lambda:SendDurableExecutionCallbackFailure",
                "lambda:SendDurableExecutionCallbackHeartbeat"
            ],
            "Resource": "arn:aws:lambda:us-east-1:123456789012:function:myDurableFunction:*"
        }
    ]
}
```

Whether that needs an HTTP hop at all depends on who's calling back in. If the trigger already runs inside AWS with an IAM role — another Lambda, a Step Functions task, an EventBridge rule — it can call `send_durable_execution_callback_success` directly with the SDK, no HTTP layer at all. A human clicking "Approve" in a browser or email is different: a browser can't safely hold AWS credentials to sign that call itself, so something still has to sit in front of it — a Lambda **Function URL** is the simplest option (skip API Gateway's resources/stages entirely) behind a Lambda that checks the click is legitimate and then calls `SendDurableExecutionCallbackSuccess` with the callback ID and a payload (`{"approved": true, "comments": "..."}`). Lambda authorizes that call against the execution's ARN, not against the reviewer, so the review UI itself can be as dumb as a signed link — the identity check happens in the handler behind the Function URL, not in IAM.

This is IAM authentication, not a webhook-with-a-secret — the caller needs SigV4-signed AWS credentials and an identity policy granting `SendDurableExecutionCallback*`. That rules out calling it directly from a reviewer's browser or an email link; something holding IAM credentials (a Lambda function, an ECS task, a CI job) has to make the call on the reviewer's behalf, after checking whatever auth the review UI itself uses. It's also scoped tighter than the function: a durable execution is a sub-resource of a specific function *version*, so the policy's `Resource` needs the `:*` qualifier (`arn:aws:lambda:us-east-1:123456789012:function:myDurableFunction:*`) to actually match — an unqualified function ARN won't authorize the callback.

## How an execution actually resumes

`DurableContext` exposes several operations — Step, Wait, Callback, Invoke, Parallel, Map, and a child-context grouping — but underneath all of them, a *suspended* execution only wakes back up for a small number of reasons:

**A clock runs out — `context.wait(duration)`.** Pure time-based resume, no external actor involved. Give it a duration — a fixed number of seconds, or a computed offset like "until 2am" — and the runtime suspends billing nothing, then wakes the execution back up on its own once the time elapses. Nothing outside Lambda needs to know the execution exists.

**An authenticated signal arrives — `context.wait_for_callback(...)`.** Suspends until something calls `SendDurableExecutionCallbackSuccess` (or `...Failure`) with the matching `callback_id`, exactly as described above. It's really callback-*or*-timer, though: `wait_for_callback` takes a `timeout`, and if nothing calls back in time it resumes anyway via the first mechanism, just with a timed-out result instead of a payload — which is why the article's approval example treats "explicitly rejected" and "never answered" the same way, in the same `if not (approval and approval.get("approved"))` branch.

`SendDurableExecutionCallbackHeartbeat` sits next to this but isn't a third resume trigger — it doesn't wake anything up, it just resets the timeout clock on a still-pending callback, for something like "the reviewer opened the form and is still filling it in, don't expire this yet."

There's actually a third: **`context.invoke(target_arn, payload, name=...)`** calls another Lambda function directly and suspends the orchestrator until it returns — the docs use the word "suspends" here too, the same as `wait`. The difference from `wait_for_callback` is who's doing the signaling: with `wait_for_callback`, some external actor has to independently call `SendDurableExecutionCallbackSuccess` with a `callback_id` you handed it yourself. With `invoke`, the platform is managing that same signal-and-resume mechanism *for you* — you never see a callback ID, because Lambda already knows exactly which invocation it's waiting on and resumes the orchestrator automatically when that invocation's response comes back. In the terms from the note above, it's on the "orchestrator calls" side of the split, not the "hand-off" side — the orchestrator is in the driver's seat the whole time, picking the callee and using its return value directly — it just isn't inline the way a `context.step()` is, since the callee can take a long time and the orchestrator suspends for it.

So the honest count is: a clock, an external caller you have to wire up yourself, or another Lambda invocation the platform tracks on your behalf — reach for `invoke` whenever the next stage can be expressed as "call this function ARN and use its return value," and fall back to `wait_for_callback` only when it can't (a human, an async external process, anything that doesn't hand you a result through a Lambda response).

`context.map` / `context.parallel` don't add a fourth: they run branches concurrently and join on all of them, but each branch resumes via a clock, a callback, or an invoke individually — map/parallel is the fan-out-and-join shape wrapped around those primitives, not a resume mechanism of its own (this is the "wait for many streams" pattern from the scaling section: N branches, each on its own timer, callback, or invoke, `map` as the barrier that waits for all of them).

## Callbacks aren't just for humans

Everything above framed `wait_for_callback` around a human clicking "Approve," but the same mechanism is how the orchestrator gets **richer results back from another service**, not just a yes/no. Say the pipeline hands the document off to a separate indexing service — triggered off the `EventBridge` event from the "signaling completion downstream" pattern — and the orchestrator's next step genuinely can't proceed until indexing reports back a real result (an index ID, a confidence score). There's no event type for "resume that paused execution," so the downstream service doesn't reply by firing another event — it calls the callback API directly, using the callback ID that rode along in the original dispatch:

```python
def dispatch_to_indexer(callback_id):
    events_client.put_events(Entries=[{
        "Source": "documents.pipeline",
        "DetailType": "IndexingRequested",
        "Detail": json.dumps({
            "documentId": document_id,
            "s3Location": extracted_location,
            "callbackId": callback_id,
        }),
    }])

index_result = context.wait_for_callback(
    dispatch_to_indexer,
    name="indexing-callback",
    config=WaitConfig(timeout=3600),
)
```

The indexer Lambda — triggered by an EventBridge rule matching `IndexingRequested` — does its work, then reports back by calling the callback API instead of publishing another event:

```python
def handler(event, context):
    detail = event["detail"]
    result = do_indexing(detail["s3Location"])

    lambda_client.send_durable_execution_callback_success(
        CallbackId=detail["callbackId"],
        Payload=json.dumps({"indexId": result.index_id, "confidence": result.confidence}),
    )
```

Whatever's in `Payload` comes back out as `index_result` once the orchestrator resumes — the actual data flows back through this channel, not just a signal. (`CallbackId`/`Payload` here are inferred field names by analogy with the rest of the API, not confirmed against a literal parameter reference.)

Two things differ from the human-approval case:

- **No HTTP hop needed.** The indexer already runs inside AWS with an IAM role, so it calls the SDK method directly — no Function URL, no browser-can't-hold-credentials problem to work around.
- **The IAM grant is static, not per-execution.** The indexer's execution role needs `lambda:SendDurableExecutionCallback*` scoped to the orchestrator function's ARN (`...function:myOrchestrator:*`), set up once at deploy time. The API authorizes each call using the `callback_id` supplied at call time plus that standing resource permission — not a fresh grant minted per execution.

And this is the dividing line for when to reach for a callback at all versus the plain fan-out from the "signaling completion downstream" section: if the orchestrator doesn't actually need the indexer's result to proceed, skip the callback and let the indexer fire its own completion event for whoever else cares. Use `wait_for_callback` specifically when the orchestrator's own next step is gated on that result coming back.

## Idempotency isn't optional

The SDK gives you two guarantees for free: execution names dedupe accidental double-starts (POST the same `documentId` as the execution name and a retried upload event won't spawn a second pipeline run), and completed steps replay from checkpoint instead of re-executing. What it doesn't give you is idempotency inside a step that's still in flight — if the Lambda environment dies between "Textract call succeeded" and "checkpoint written," the step retries and calls Textract again. For read-only operations like `classify` or `extract` that's harmless. For `finalize-document`, which presumably writes a database row, it means the write itself needs to be safe to repeat — an upsert keyed by `document_id`, not an `INSERT`.

## Handling a dynamic flow

The pipeline above has a fixed shape — split, OCR, classify, maybe-review, finalize. Real document pipelines usually aren't that tidy: an invoice needs one review stage, a contract needs two, a scanned form with a bad OCR score needs a re-scan step that a clean PDF skips entirely. Because a durable function is just code, that's not a different feature — it's an `if` or a `for` loop, same as it would be in normal code. `context.map`'s page-level fan-out is already an example of a dynamic step count: the number of OCR steps is however many pages `split_service.split_pages` returns, decided at runtime.

The same works for variable review stages, driven off the classification result:

```python
classification = context.step(
    lambda _: classifier_service.classify(ocr_results.get_results()),
    name="classify-document",
)

for stage_index, stage in enumerate(classification["reviewStages"]):
    def notify_reviewer(callback_id, stage=stage):
        notification_service.send_review_request(
            document_id=document_id,
            reviewers=stage["reviewers"],
            callback_id=callback_id,
        )

    approval = context.wait_for_callback(
        notify_reviewer,
        name=f"review-callback-{stage_index}",
        config=WaitConfig(timeout=stage["timeoutSeconds"]),
    )

    if not (approval and approval.get("approved")):
        context.step(
            lambda _: document_service.archive(document_id, approval.get("reason") if approval else "timed_out"),
            name=f"archive-rejected-{stage_index}",
        )
        return {"documentId": document_id, "status": "rejected", "atStage": stage_index}
```

`classification["reviewStages"]` might be an empty list for an invoice and a two-element list for a contract — the loop runs zero, one, or however many times the data says it should. Nothing about durable execution requires the flow to be static; Step Functions would need this expressed as a `Map` state or nested `Choice` states, but here it's a `for` loop.

The one rule that makes this safe is **determinism on replay**: since the handler body re-runs from the top on every resume, whatever decides the branch has to come out the same way every time, or the replay desyncs from its own checkpoint history. In practice that means:

- **Base branches on checkpointed step results**, like `classification["reviewStages"]` above, not on a fresh, un-stepped call to the classifier made directly in the handler body — a second classifier call could return something different on replay.
- **Give dynamic steps stable, derivable names**, like `f"review-callback-{stage_index}"`, so a resumed execution can match each step back to the right checkpoint. A name built from `uuid.uuid4()` or the current timestamp would mint a new identity every replay and never find its checkpoint.
- **Keep non-deterministic reads inside a step.** `datetime.now()` or `random.random()` called directly in the handler body re-evaluates on every replay and can flip a branch that already committed one way. Called inside `context.step(...)`, the value is captured once and replayed from checkpoint like anything else.

That's the same constraint every replay-based durable-execution model has (Temporal and Azure Durable Functions included) — it's not specific to document pipelines, but it's the thing that bites first when a "fixed" pipeline like the one above grows a dynamic branch and nobody moves the branching logic into a step.

## Where this beats Step Functions, and where it doesn't

The pitch for durable functions is that the orchestration *is* the code — no ASL, no separate state machine definition to keep in sync with the handler logic, no console diagrams that drift from what the Lambdas actually do. For a pipeline like this one, owned by one team and living in one repo, that's a real simplification: one file, normal control flow, `if`/`for` instead of `Choice`/`Map` states.

Step Functions still wins when the workflow needs to be legible to people who don't read the code — the visual execution history is genuinely useful for "why did this document get stuck" support questions — or when the pipeline fans out to non-Lambda targets (ECS tasks, Glue jobs, a direct DynamoDB write) that Step Functions integrates natively and durable functions would have to shell out to via SDK calls inside a step. And if your steps are already thin wrappers around other AWS services, Step Functions' direct service integrations avoid a Lambda invocation per step entirely.

For a document pipeline that's mostly "call Textract, call a classifier, wait for a person, write a row" — code someone is going to read top to bottom, with a wait measured in hours and a fan-out measured in pages — durable functions are the better fit, and there's a lot less to build to get there.
