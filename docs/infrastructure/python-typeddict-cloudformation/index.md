# CloudFormation with Python TypedDicts

The [Jsonnet article](../jsonnet-cloudformation/index.md) replaces
framework-generated CloudFormation with a small library of helpers that return
plain data. Python can play the same role. The two ingredients are:

- **dicts** for the template itself — ordered, mergeable with `|`, and
  serialized with `json.dumps`.
- **`TypedDict`** to describe the shape of each resource, so a type checker
  catches typos and wrong types before CloudFormation does.

There is no CDK, no jsii, no Node.js and no transform. The Python file *is* the
template generator, and its output is plain JSON you can diff.

## Contents

- [The idea](#the-idea) — helpers return typed dicts
- [The library](#the-library) — intrinsics, resources, factories, kwargs
- [The example](#the-example) — the SQS worker from the Jsonnet article
- [What the type checker catches](#what-the-type-checker-catches)
- [Comparison with Jsonnet](#comparison-with-jsonnet)
- [Trade-offs](#trade-offs)

## The idea

A Jsonnet helper such as `sls.sqsQueue(...)` returns a JSON object. In Python
the equivalent is a function that returns a `dict`, annotated with a
`TypedDict` that describes which keys must be there:

```python
class QueueProps(TypedDict):
    VisibilityTimeout: int
    RedrivePolicy: NotRequired[RedrivePolicy]
    Tags: NotRequired[list[Tag]]

class Queue(TypedDict):
    Type: str
    Properties: QueueProps
```

`TypedDict` is erased at runtime. A `Queue` is just a `dict`, so
`json.dumps(template)` works with no serializer, and the types cost nothing.
The checking happens statically, in `mypy`, `pyright` or `ty`.

## The library

The full file is [`examples/cfn.py`](examples/cfn.py) (about 170 lines). The
interesting parts are below.

### Intrinsic functions

CloudFormation keys like `Fn::GetAtt` are not valid Python identifiers, so they
need the functional `TypedDict` syntax:

```python
Ref = TypedDict("Ref", {"Ref": str})
GetAtt = TypedDict("GetAtt", {"Fn::GetAtt": list[str]})
Sub = TypedDict("Sub", {"Fn::Sub": str})

Value = str | int | Ref | GetAtt | Sub   # anything allowed where a scalar goes

def get_att(logical: str, attr: str) -> GetAtt:
    return {"Fn::GetAtt": [logical, attr]}
```

Because `Value` is a union, a property typed `Value` accepts either a literal or
an intrinsic, which is exactly how CloudFormation behaves.

### Resources and factories

Each resource type gets a properties `TypedDict`. Optional properties use
`NotRequired`:

```python
class FunctionProps(TypedDict):
    FunctionName: str
    Handler: str
    Runtime: str
    Role: Value
    Code: Code
    MemorySize: NotRequired[int]
    Timeout: NotRequired[int]
    ReservedConcurrentExecutions: NotRequired[int]
    ...

Resource = Queue | Role | Function | EventSourceMapping
Resources = dict[str, Resource]
```

### Keyword arguments instead of dict literals

A properties `TypedDict` can also type a function's `**kwargs` with
`Unpack` ([PEP 692](https://peps.python.org/pep-0692/), Python 3.12 or
`typing_extensions`). The factory then takes properties as keyword arguments,
and the type checker still validates every name, type and required key:

```python
def function(**props: Unpack[FunctionProps]) -> Function:
    return {"Type": "AWS::Lambda::Function", "Properties": props}
```

Nested structures work the same way: a `TypedDict` class is callable with
keyword arguments and returns a plain dict, so `Code(S3Bucket="b", S3Key="k")`
is checked like a constructor but costs nothing at runtime. The result has no
quoted keys and no braces except where a value is a genuine free-form map.

Where kwargs do not fit, keep dict literals: intrinsic keys such as
`"Fn::GetAtt"` are not identifiers (use helper functions like `get_att`), and
a conditionally built dict still needs `**props`, which is checked less
strictly.

Factories keep the ordinary Python-function feel of Jsonnet helpers, including
optional pieces:

```python
def queue(visibility_timeout=30, dlq_arn=None, max_receive_count=3, tags=None) -> Queue:
    props: QueueProps = {"VisibilityTimeout": visibility_timeout}
    if dlq_arn is not None:
        props["RedrivePolicy"] = {"deadLetterTargetArn": dlq_arn,
                                  "maxReceiveCount": max_receive_count}
    if tags:
        props["Tags"] = tags
    return {"Type": "AWS::SQS::Queue", "Properties": props}
```

## The example

This is [`examples/sqs_worker.py`](examples/sqs_worker.py), the Python twin of
the Jsonnet SQS consumer: a Lambda triggered by a queue, a dead-letter queue,
and a limit of five concurrent executions.

```python
service = "order-processor"
stage = sys.argv[1] if len(sys.argv) > 1 else "dev"
t = cfn.tags(Service=service, Stage=stage)

resources: Resources = {
    "ExecutionRole": cfn.lambda_role(f"{service}-{stage}", [
        cfn.allow(cfn.SQS_CONSUME, [cfn.get_att("OrderQueue", "Arn")]),
        cfn.allow(cfn.DDB_WRITE, cfn.arn("dynamodb", f"table/orders-{stage}")),
    ]),
    "Processor": cfn.function(
        FunctionName=f"{service}-{stage}-processor",
        Handler="src/processor.handler",
        Runtime="nodejs20.x",
        Role=cfn.get_att("ExecutionRole", "Arn"),
        Code=cfn.Code(S3Bucket="deploy-artifacts", S3Key=f"{service}/{stage}/package.zip"),
        MemorySize=256,
        Timeout=30,
        Environment=cfn.Environment(Variables={"STAGE": stage, "TABLE_NAME": f"orders-{stage}"}),
        ReservedConcurrentExecutions=5,
        Tags=t,
    ),
    "ProcessorEventSourceMapping": cfn.sqs_event_source("Processor", cfn.get_att("OrderQueue", "Arn")),
    "OrderDLQ": cfn.queue(tags=t),
    "OrderQueue": cfn.queue(
        visibility_timeout=180,
        dlq_arn=cfn.get_att("OrderDLQ", "Arn"),
        tags=t,
    ),
}

template: Template = {
    "AWSTemplateFormatVersion": "2010-09-09",
    "Resources": resources,
    "Outputs": {
        "QueueUrl": {"Value": cfn.ref("OrderQueue")},
        "DLQUrl": {"Value": cfn.ref("OrderDLQ")},
    },
}

print(json.dumps(template, indent=2))
```

Generate and deploy the same way as with Jsonnet:

```sh
python examples/sqs_worker.py prod > prod.json
aws cloudformation deploy --template-file prod.json --stack-name order-processor-prod \
    --capabilities CAPABILITY_IAM
```

Stage comes from `argv` here instead of Jsonnet's `--ext-str`; one source file
still produces every stage.

## What the type checker catches

With `mypy --strict` the example passes cleanly. Introduce two mistakes — a
misspelled property and a string where CloudFormation wants a number:

```python
MemorySise=256,     # typo
Timeout="30",       # wrong type
```

and the checker reports them before any template exists:

```text
bad.py:2: error: Unexpected keyword argument "MemorySise" for "function"; did you mean "MemorySize"?  [call-arg]
bad.py:2: error: Argument "Timeout" to "function" has incompatible type "str"; expected "int"  [arg-type]
```

Editors also autocomplete property names and flag missing required keys as you
type. Jsonnet cannot do any of this: `MemorySise` is a perfectly valid field
name, and you find out at `cfn-lint` time or on deploy.

## Comparison with Jsonnet

| | Jsonnet | Python + TypedDict |
|---|---|---|
| Output | JSON, plain data | JSON, plain data |
| Runtime needed | one ~2 MB `jsonnet` binary | Python (already there for many teams) |
| Merge | `+` deep-merges objects | `\|` is **shallow**; nested overrides need explicit code |
| Property typos | found by `cfn-lint` or deploy | found by the type checker while editing |
| Evaluation | hermetic — no I/O, no side effects | anything Python can do, including network calls |
| Key ordering | sorted unless `--preserve-field-order` | insertion order, always |
| Laziness | fields evaluated on demand | eager |
| Shared vocabulary | one more language to learn | language the team already writes Lambdas in |

Deep merge is the biggest behavioral difference. In Jsonnet,
`defaults + props` merges `Environment.Variables` key by key. In Python
`defaults | props` replaces the whole `Environment` value. If you want
Jsonnet's behavior for overrides, write one small recursive `merge()` helper
and use it consistently.

## Trade-offs

**What you gain**

- Static checking of resource shapes with tools you likely already run.
- Ordinary Python for loops, comprehensions, `dataclass`es and tests. A
  `pytest` that renders each template and runs `cfn-lint` on it takes a few
  lines.
- No new language for a Python team.

**What you give up**

- **Hermeticity.** Nothing stops a template generator from reading environment
  variables, calling AWS, or depending on the clock. The Jsonnet guarantee that
  the output is a pure function of the inputs is a discipline in Python, not a
  property.
- **Coverage.** The types are hand-written, so they only describe the resources
  you wrote them for. CloudFormation has a published resource specification,
  and generating `TypedDict`s from it is possible but is a project of its own —
  and that is roughly what CDK's generated constructs are. Fall back to
  `dict[str, Any]` for the long tail.
- **Runtime validation.** `TypedDict` does nothing when the program runs. A
  value from `json.load` or an untyped call is not checked. Keep `cfn-lint` in
  CI regardless.
- **Union narrowing is fiddly.** `Resource = Queue | Role | ...` distinguishes
  members only by shape, and every member has `Type: str`, so reading a resource
  back generically means checking `Type` by hand. Using `Literal["AWS::SQS::Queue"]`
  for `Type` fixes that at the cost of more boilerplate.

## When to pick which

If your team already reviews `.jsonnet` and values a generator that cannot do
anything but emit data, stay with Jsonnet. If your team is Python-first and
would rather get red squiggles than a failed change set, this approach gives
most of the benefit with tools already installed.

The migration path is unchanged: capture the CloudFormation your framework
generated, factor the repeating patterns into helpers, and verify that the
rendered JSON matches the original (`diff <(python gen.py | jq -S .) <(jq -S . original.json)`)
and that the change set is empty before executing anything.
