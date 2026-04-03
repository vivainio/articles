# Ejecting Serverless with Jsonnet

## Why leave

Serverless Framework v4 [switched to a commercial
license](https://www.serverless.com/blog/serverless-framework-v4-a-new-model).
Deployments now require a Serverless Inc. account, report telemetry to their
dashboard, and organizations above a revenue threshold need a paid
subscription. The open-source v3 branch is frozen — no security patches, no
new runtime support. (See also the [Hacker News
discussion](https://news.ycombinator.com/item?id=43421598) on the license
change.)

If you have dozens of services in production, this means either paying per seat
for a build tool that wraps CloudFormation, or migrating. Most teams start
evaluating alternatives at this point.

### Why not SAM?

AWS SAM is the natural first stop. It's AWS-native, open source, and
`AWS::Serverless::Function` is a clean abstraction. But SAM only provides a
handful of built-in resource types (`Function`, `Api`, `HttpApi`,
`SimpleTable`, and a few others). The moment you need something outside that
set — a custom IAM policy, an SQS queue with a DLQ, a CloudWatch alarm — you
drop back to plain CloudFormation YAML with no templating, no functions, and no
way to reduce repetition. SAM gives you abstractions for the easy parts but
leaves you on your own for everything else. On top of that, the SAM transform
is a black box: your template is rewritten by CloudFormation at deploy time.
When something goes wrong, you're debugging resources you didn't declare. You
can run `sam build` to preview the expansion, but the authoritative template —
the one CloudFormation actually acts on — is generated server-side. You traded
one black box for another.

### Why not CDK?

AWS CDK is popular but carries real costs. Even if you write your
infrastructure in Python or C#, CDK's core runs on Node.js — you still need a
Node runtime, `node_modules`, and the full tree of npm dependencies in every
project and CI pipeline. `cdk synth` runs your code through jsii (the
cross-language bridge) and Node to emit CloudFormation JSON — on a cold
`node_modules` this takes 20-60 seconds even for small stacks. CI pipelines
need a Node runtime image, `npx cdk` bootstrapping, and CDK-specific IAM
permissions. For teams whose Lambda functions are Python or C#, maintaining a
Node toolchain (plus the Python/C# toolchain you actually chose) solely for
the deployment layer is overhead that never pays for itself.

CDK also generates CloudFormation with machine-generated logical IDs (hashes
like `MyFunctionServiceRole3AC7B20E`), deeply nested metadata blocks, and
CDK-internal parameters that make the synthesized template nearly unreadable.
Reviewing a `cdk diff` in a pull request means staring at hundreds of lines of
machine-generated JSON that no human authored — you're trusting the abstraction
rather than reviewing the infrastructure.

CDK shines when you have large, complex infrastructure with dozens of
interdependent resources — but for typical serverless stacks (a few Lambdas, an
API Gateway, some queues), it's overkill.

### Why not Terraform?

Terraform is a legitimate option but means adopting an entirely new state
management model, HCL syntax, and provider versioning. Terraform also [switched
to the Business Source
License](https://www.hashicorp.com/en/blog/hashicorp-adopts-business-source-license)
in 2023, so you'd be trading one licensing problem for another. If your
infrastructure is already CloudFormation, switching to Terraform is a bigger
migration than the problem you're solving.

### What we actually need

The Serverless Framework did two things:

1. **Boilerplate reduction** — a 7-line function definition expanded to 120+
   lines of CloudFormation JSON.
2. **Deploy orchestration** — packaging code, uploading to S3, calling
   `cloudformation deploy`.

Item 2 is a shell script. The real value was always item 1. The question
is: can we get the same boilerplate reduction without a framework, without a
transform, and without a Node.js build step?

### Jsonnet

[Jsonnet](https://jsonnet.org/) is a data templating language from Google. It
compiles to JSON. It has functions, imports, and object merging — enough to
build a library of helpers that generate CloudFormation resources. The binary
is a single ~2MB executable with no runtime dependencies. Compilation is
instant. Jsonnet is already widely used for generating Kubernetes manifests
(via [Tanka](https://tanka.dev/) and ksonnet) — templating large, repetitive
JSON/YAML configurations is exactly what it was designed for, and
CloudFormation is the same kind of problem. The official
[tutorial](https://jsonnet.org/learning/tutorial.html) is a good starting
point for learning the language, though you may want to skip it if you're a
recovering alcoholic — the reasons will become clear once you visit.

Jsonnet gives you the same power of abstraction as CDK — functions, local
variables, imports, conditionals, array comprehensions, object merging — but
everything stays declarative. There is no imperative runtime, no constructors
building a resource graph in memory. You define data, not procedures. The
output of a Jsonnet file *is* the template, not a side effect of running a
program. And unlike CDK, there is no `node_modules` directory, no transitive
dependency tree, and no 20-60 second `cdk synth` step. The Jsonnet binary is a
single ~2 MB executable with zero runtime dependencies, and it compiles
templates in milliseconds — fast enough that you never notice it.

The approach: write a Jsonnet library where each helper returns a flat object
of CloudFormation resources. Merge them with `+`. Run `jsonnet` to emit plain
JSON. Deploy with `aws cloudformation deploy`. No framework, no transform, no
`node_modules`.

## The migration path

You don't need to rewrite anything from scratch. The Serverless Framework
already generated the CloudFormation for you — every `sls deploy` submitted a
JSON template to CloudFormation, and that template is still sitting in your
deployment bucket or in the CloudFormation console under the stack's Template
tab.

The migration is mechanical — and mechanical work is exactly what AI coding
agents excel at. A tool like Claude Code can read your existing CloudFormation
JSON, factor it into library calls, and verify the output matches the original.
This repository includes a sample Claude Code skill for this workflow:
[`skills/exit-serverless-to-jsonnet/SKILL.md`](skills/exit-serverless-to-jsonnet/SKILL.md).

The steps:

1. **Capture** the current generated CloudFormation JSON for each service
   (`sls package` writes it to `.serverless/cloudformation-template-update-stack.json`,
   or pull it from the deployed stack with
   `aws cloudformation get-template --stack-name my-service-dev`).

2. **Identify the repeating patterns.** Every template has the same structure:
   deployment bucket, IAM execution role, the Lambda triplet (LogGroup +
   Function + Version) per function, event wiring (schedule rules, SQS
   mappings, API Gateway resource trees). These are the constructs presented
   in this article.

3. **Factor out** each pattern into a library call. The 120-line Lambda triplet
   becomes `cfn.lambdaFn(...)`. The 50-line CORS OPTIONS mock becomes
   `cfn.corsOptions(...)`. Service-specific resources (DynamoDB tables, custom
   IAM statements) stay as inline Jsonnet objects.

4. **Verify** by diffing the Jsonnet output against the captured original:
   `diff <(jsonnet my-service.jsonnet) captured-original.json`. The resource
   structure should match — key names, types, properties. Minor differences
   in JSON key ordering are expected (Jsonnet sorts alphabetically).

5. **Deploy** the Jsonnet-generated template to the *existing* stack.
   CloudFormation computes a changeset against the current state. If the
   logical IDs and resource properties match, the changeset is empty — a
   no-op deploy that confirms the migration is correct.

This is a low-risk migration: you're replacing the *source* of the template,
not the deployed infrastructure. The stack, the Lambda functions, the API
Gateway — everything stays in place. CloudFormation only acts on differences,
and if there are none, nothing changes.

This matters because moving resources between CloudFormation stacks is painful.
If a stack owns a DynamoDB table or an SQS queue, you can't just declare it in
a new stack — CloudFormation will try to create a new one, and the old stack
still holds the original. Migrating stateful resources across stacks requires
`DeletionPolicy: Retain`, manual imports, and careful ordering to avoid data
loss. CDK makes this worse: because it generates logical IDs from hashes of the
construct path, even renaming a construct or moving it in the tree changes the
logical ID, which CloudFormation interprets as "delete the old resource and
create a new one." The safest path is to keep your existing stacks and change
only how the template is generated — which is exactly what this approach does.

The same approach works for SAM templates: run `sam build` to get the expanded
CloudFormation, then factor it into `sam.libsonnet` calls that produce the
same output.

## The boilerplate problem

A typical `serverless.yml` function definition:

```yaml
functions:
  worker:
    handler: handler.cleanup
    runtime: python3.12
    memorySize: 512
    timeout: 600
    events:
      - schedule: cron(0 3 * * ? *)
```

This 7-line declaration expands to ~120 lines of CloudFormation JSON:

- `AWS::Logs::LogGroup` — CloudWatch log group
- `AWS::Lambda::Function` — the function itself
- `AWS::Lambda::Version` — immutable version snapshot
- `AWS::Events::Rule` — the cron schedule
- `AWS::Lambda::Permission` — allows EventBridge to invoke the function
- `AWS::IAM::Role` — execution role with log permissions
- `AWS::S3::Bucket` + `BucketPolicy` — deployment artifact storage

The same is true for SAM's `AWS::Serverless::Function` — the SAM transform
expands it to the same set of resources at deploy time.

Both approaches hide the generated CloudFormation from you. When something goes
wrong, you're debugging a template you didn't write.

## The Jsonnet approach

Write a Jsonnet library where each helper returns a flat object of
CloudFormation resources:

```jsonnet
local cfn = import 'lib/cfn.libsonnet';

{
  AWSTemplateFormatVersion: '2010-09-09',
  Resources:
    cfn.deploymentBucket
    + cfn.iamRole('my-service', 'dev', [...])
    + cfn.lambdaFn(logicalName='Worker', functionName='my-service-dev-worker', ...)
    + cfn.scheduleEvent('Worker', 'cron(0 3 * * ? *)'),
}
```

Run `jsonnet my-service.jsonnet` and you get plain CloudFormation JSON — no
transform, no framework, no plugins. What you see is what deploys.

## What the library wraps

Each helper maps to what SLS/SAM auto-generated from a high-level declaration:

| SLS / SAM concept | Library helper | CFN resources generated |
|---|---|---|
| `functions:` entry | `cfn.lambdaFn(...)` | LogGroup + Function + Version |
| `events: - schedule:` | `cfn.scheduleEvent(...)` | Events::Rule + Lambda::Permission |
| `events: - sqs:` | `cfn.sqsEventSource(...)` | Lambda::EventSourceMapping |
| `events: - http:` | `cfn.apiMethod(...)` + `cfn.corsOptions(...)` | Method + CORS OPTIONS mock |
| `events: - httpApi:` | `cfn.httpApiFn(...)` | Integration + Routes + Permission |
| `provider.iamRoleStatements` | `cfn.iamRole(...)` | IAM::Role with scoped log perms |
| `provider.apiKeys` | (manual) | ApiKey + UsagePlan + UsagePlanKey |
| implicit | `cfn.deploymentBucket` | S3::Bucket + BucketPolicy |
| SLS log-subscription plugin | `cfn.lambdaFn(..., logDestination=...)` | Logs::SubscriptionFilter |

## Examples

### 1. Scheduled worker (54 lines → 8 resources)

A Lambda function triggered by a cron schedule. The simplest serverless
pattern.

→ [`examples/scheduled-worker.jsonnet`](examples/scheduled-worker.jsonnet)

### 2. REST API with CORS (103 lines → 25 resources)

A single Lambda function behind API Gateway v1 with five routes, CORS OPTIONS
on each path, and API key authentication. This is where the compression is
most dramatic — API Gateway v1 generates enormous amounts of boilerplate.

→ [`examples/rest-api.jsonnet`](examples/rest-api.jsonnet)

### 3. SQS consumer with DLQ (99 lines → 9 resources)

A Lambda function polling an SQS queue, with a dead-letter queue for failures
and `ReservedConcurrentExecutions` to limit parallelism.

→ [`examples/sqs-worker.jsonnet`](examples/sqs-worker.jsonnet)

### 4. HTTP API with JWT auth (84 lines → 16 resources)

API Gateway v2 (HTTP API) with a JWT authorizer. The modern alternative to
REST API — no resource tree, no CORS mocks, auto-deploy stage.

→ [`examples/http-api-jwt.jsonnet`](examples/http-api-jwt.jsonnet)

## Multi-stage from a single file

Every example accepts `stage` as an external variable:

```sh
jsonnet --ext-str stage=dev  examples/scheduled-worker.jsonnet > dev.json
jsonnet --ext-str stage=prod examples/scheduled-worker.jsonnet > prod.json
```

One source file generates all stages. No near-identical copies.

## Deploying code separately

The Serverless Framework bundled code deployment with infrastructure: it zipped
your handler, uploaded it to S3, and pointed `Code.S3Key` at the new artifact
in the CloudFormation template. Every deploy was a full stack update, even if
only the function code changed.

Once you manage the template yourself, you can separate the two concerns:

1. **Infrastructure changes** (new resources, IAM policy updates, environment
   variable changes) go through `aws cloudformation deploy` as before.
2. **Code-only changes** use `aws lambda update-function-code --function-name
   my-service-dev-worker --zip-file fileb://package.zip` — no CloudFormation
   involved, completes in seconds.

This is faster and simpler for day-to-day development. You don't need to
maintain S3 keys in your template or manage artifact versioning in a deployment
bucket. The template's `Code` property becomes a one-time bootstrap value (or
points to a fixed S3 path that your CI overwrites).

The trade-off: CloudFormation rollbacks won't roll back code changes made
outside the stack. In practice this rarely matters — if a code deploy breaks
something, you redeploy the previous version with `update-function-code`. But
if you need atomic infrastructure + code rollbacks (e.g. a new DynamoDB table
and the code that uses it must deploy or fail together), keep the S3-based
approach for those stacks.

## Comparison

For a REST API with 5 routes:

| Approach | Source lines | What deploys | Build dependency |
|---|---|---|---|
| Raw CloudFormation JSON | ~800 | Exactly what you wrote | None |
| Serverless Framework v4 | ~45 | Generated CFN (opaque) | Node.js + SLS account |
| SAM template | ~110 | SAM transform output (opaque) | Python or Node.js |
| AWS CDK (TypeScript) | ~60 | Generated CFN (hashed IDs) | Node.js + npm install + cdk synth |
| **Jsonnet + cfn.libsonnet** | **~100** | **Exactly what you wrote** | **Single binary, no deps** |
| **Jsonnet + sam.libsonnet** | **~80–97** | **Exactly what you wrote** | **Single binary, no deps** |

The Jsonnet source is comparable in size to SAM, but the output is plain
CloudFormation with no transform step. You can diff it, review it in PRs, and
`cfn-lint` it directly. The sam.libsonnet layer is even more concise because
it auto-generates the API Gateway resource tree from event declarations.

## How it works

Every helper is a Jsonnet function that returns a plain object:

```jsonnet
lambdaFn(logicalName='Worker', functionName='svc-dev-worker', handler='h.main', ...)
// returns:
// {
//   WorkerLogGroup: { Type: 'AWS::Logs::LogGroup', ... },
//   WorkerLambdaFunction: { Type: 'AWS::Lambda::Function', ... },
//   WorkerLambdaVersion: { Type: 'AWS::Lambda::Version', ... },
// }
```

Objects are merged with `+`:

```jsonnet
Resources:
  cfn.deploymentBucket           // S3 bucket + policy
  + cfn.iamRole(...)             // IAM role
  + cfn.lambdaFn(...)            // LogGroup + Function + Version
  + cfn.scheduleEvent(...)       // Events::Rule + Permission
```

This is the key design: each helper is independent, there's no hidden state,
and the output is a flat resource map that CloudFormation consumes directly.

### Custom abstractions

Because Jsonnet has functions, imports, and object merging, you can build the
same kind of project-level abstractions that CDK users create with custom
constructs. A common example is enforcing a standard set of tags on every
resource:

```jsonnet
local standardTags(service, stage) = {
  Tags: [
    { Key: 'Service', Value: service },
    { Key: 'Stage', Value: stage },
    { Key: 'Team', Value: 'platform' },
    { Key: 'ManagedBy', Value: 'cloudformation' },
  ],
};

// Apply to every resource that supports tags:
lambdaFn(logicalName, functionName, handler, ..., tags=standardTags(service, stage))
```

Another example: CloudFormation intrinsic functions like `Fn::GetAtt` and
`Fn::Sub` are verbose when written inline. The library provides shorthands:

```jsonnet
// These one-liners in cfn.libsonnet:
getAtt(logical, attr):: { 'Fn::GetAtt': [logical, attr] },
sub(str):: { 'Fn::Sub': str },
ref(logical):: { Ref: logical },

// Turn this:
Resource: [{ 'Fn::GetAtt': ['OrderQueue', 'Arn'] }],

// Into this:
Resource: [cfn.getAtt('OrderQueue', 'Arn')],
```

A more realistic example: your company wants every Lambda's CloudWatch logs
forwarded to a central Kinesis Data Firehose for log aggregation. Instead of
copy-pasting the subscription filter into every service, you put the pattern in
a shared library as a mixin that you merge alongside the Lambda:

```jsonnet
// lib/company.libsonnet — shared abstractions across all services
{
  // Returns a SubscriptionFilter resource that forwards a Lambda's logs
  // to the central Firehose. Merge with `+` next to cfn.lambdaFn().
  logForwarding(logicalName, functionName, firehoseArn, roleArn):: {
    [logicalName + 'LogSubscription']: {
      Type: 'AWS::Logs::SubscriptionFilter',
      DependsOn: logicalName + 'LogGroup',
      Properties: {
        LogGroupName: '/aws/lambda/' + functionName,
        FilterPattern: '',
        DestinationArn: firehoseArn,
        RoleArn: roleArn,
      },
    },
  },
}
```

Services compose it with `+`, just like any other resource block:

```jsonnet
local co = import 'lib/company.libsonnet';

Resources:
  cfn.lambdaFn(logicalName='Worker', functionName=fnName, ...)
  + co.logForwarding('Worker', fnName, firehoseArn, logRoleArn)
  + cfn.scheduleEvent('Worker', 'cron(0 3 * * ? *)'),
```

No wrapping, no override — `cfn.lambdaFn` stays untouched and the mixin is
just another object merged in. This is the same pattern CDK teams achieve with
custom constructs, but the abstraction is a pure data transformation: you can
print the output, diff it, and reason about it without running anything.

## Replacing SAM with sam.libsonnet

If you're already using SAM templates (or thinking in SAM terms), there's a
second library — `sam.libsonnet` — that accepts SAM-shaped declarations and
expands them to raw CloudFormation through `cfn.libsonnet`.

### Why replace SAM?

SAM templates are concise. A function with five API routes is about 40 lines.
But the SAM transform is a black box: you submit a template with
`AWS::Serverless::Function` and CloudFormation expands it at deploy time. You
can run `sam build` to preview, but in production you're trusting the
transform. When something goes wrong, you're debugging resources you didn't
declare.

`sam.libsonnet` performs the same expansion at build time. The developer writes
SAM-shaped input, but the output is plain CloudFormation — no `Transform:`
header, no deploy-time surprises.

### How it works

SAM's `AWS::Serverless::Function` puts events *inside* the function as an
`Events:` map. The transform then generates the external resources (API Gateway
methods, EventSourceMappings, permissions). `sam.libsonnet` does the same:

```jsonnet
local sam = import 'lib/sam.libsonnet';
local cfn = import 'lib/cfn.libsonnet';

local fn = sam.Function('Api', {
  Handler: 'app.handler',
  CodeUri: 's3://my-bucket/package.zip',
  Events: {
    GetItems:  { Type: 'Api', Properties: { Path: '/items', Method: 'get' } },
    PostItems: { Type: 'Api', Properties: { Path: '/items', Method: 'post' } },
  },
});

local api = sam.Api('MyApi', {
  StageName: 'dev',
}, functions=[fn], service='my-service');

{
  AWSTemplateFormatVersion: '2010-09-09',
  Resources:
    cfn.iamRole('my-service', 'dev', fn.extraStatements)
    + fn.resources     // LogGroup + Function + Version
    + api.resources,   // RestApi + Resources + Methods + CORS + Deployment
}
```

The `sam.Function()` call returns:
- `.resources` — the Lambda triplet (and any non-API event resources)
- `.extraStatements` — IAM statements extracted from `Policies:` (pass to `cfn.iamRole`)
- `.apiEvents` / `.httpApiEvents` — collected for the API expander

The `sam.Api()` call consumes those collected events and generates the full API
Gateway resource tree, CORS OPTIONS mocks, deployment, and permissions — the
same expansion the SAM transform would perform.

### SAM Globals

SAM's `Globals:` section provides defaults merged into every function. The
Jsonnet equivalent is a local object you pass to each `sam.Function()`:

```jsonnet
local globals = {
  Function: {
    Runtime: 'python3.12',
    Timeout: 300,
    Tags: { Team: 'platform', Service: 'my-service' },
    Environment: { Variables: { STAGE: stage } },
  },
};

local fn = sam.Function('Api', { ... }, globals=globals.Function);
```

Tags and environment variables are merged (function-level overrides Globals).
Runtime, timeout, and memory use function-level if set, otherwise fall back
to Globals.

### SAM examples

These produce the same CloudFormation output as the direct cfn.libsonnet
examples, but with SAM-style input:

| Example | Lines | Resources |
|---|---|---|
| [`sam-rest-api.jsonnet`](examples/sam-rest-api.jsonnet) — REST API + CORS + API key | 97 | 28 |
| [`sam-http-api-jwt.jsonnet`](examples/sam-http-api-jwt.jsonnet) — HTTP API v2 + JWT | 80 | 16 |
| [`sam-sqs-worker.jsonnet`](examples/sam-sqs-worker.jsonnet) — SQS consumer + DLQ | 81 | 9 |

### Mapping SAM resource types to library calls

| SAM resource type | `sam.libsonnet` call | What it expands to |
|---|---|---|
| `AWS::Serverless::Function` | `sam.Function(name, props, globals)` | LogGroup + Function + Version + event resources |
| `AWS::Serverless::Api` | `sam.Api(name, props, functions)` | RestApi + Resource tree + Methods + CORS + Deployment + ApiKey |
| `AWS::Serverless::HttpApi` | `sam.HttpApi(name, props, functions)` | ApiGatewayV2::Api + Stage + Authorizers + Integration + Routes |
| `Globals:` | Plain Jsonnet object passed to `Function()` | Merged into each function's defaults |
| `Events: { Type: Schedule }` | Expanded inside `Function()` | Events::Rule + Lambda::Permission |
| `Events: { Type: SQS }` | Expanded inside `Function()` | Lambda::EventSourceMapping |
| `Events: { Type: Api }` | Collected, expanded by `Api()` | Method + CORS OPTIONS + Permission |
| `Events: { Type: HttpApi }` | Collected, expanded by `HttpApi()` | Route + Integration + Permission |

### Two layers, one output

The two libraries complement each other:

- **`cfn.libsonnet`** — low-level helpers, one per CFN resource pattern. You
  wire resources together explicitly. Maximum control.
- **`sam.libsonnet`** — high-level SAM-shaped interface. Events are declared
  inline, API resource trees are generated automatically. Calls `cfn.libsonnet`
  under the hood.

Both produce the same plain CloudFormation JSON. Choose based on how much
automation you want vs. how much control you need.

## Trade-offs

**What you gain:**
- No commercial license, no telemetry, no vendor account
- No Node.js runtime in your CI pipeline
- No deploy-time transform — what you commit is what CloudFormation sees
- Output is diffable, lintable (`cfn-lint`), and reviewable in PRs
- Multi-stage is a one-liner (`--ext-str stage=prod`)
- Build step is instant — `jsonnet` compiles in milliseconds, not seconds
- Library is ~800 lines of Jsonnet you can read and modify in an afternoon

**What you lose:**
- No plugin ecosystem (SLS) or policy templates (SAM)
- You maintain the library yourself (but it's small)
- Logical ID naming requires care when updating existing stacks in-place
- No `sls deploy` or `sam deploy` — you write a deploy script around
  `aws cloudformation deploy` (which is what those tools call anyway)

## Getting started

1. Install Jsonnet: `brew install jsonnet` / `apt install jsonnet`
2. Copy `lib/cfn.libsonnet` into your project (and `lib/sam.libsonnet` if you
   want the SAM-style interface)
3. Write a `.jsonnet` file importing the library
4. Render: `jsonnet --ext-str stage=dev my-service.jsonnet > template.json`
5. Validate: `aws cloudformation validate-template --template-body file://template.json`
6. Deploy: `aws cloudformation deploy --template-file template.json --stack-name my-service-dev --capabilities CAPABILITY_NAMED_IAM`

## Caveats

**Key ordering.** The Go implementation of Jsonnet (`jsonnet-go`, which is what
`brew install go-jsonnet` and most package managers ship) sorts object keys
alphabetically by default. This means your output JSON will have `Resources`
before `AWSTemplateFormatVersion`, and properties within each resource will be
reordered. CloudFormation doesn't care about key order, but it makes the output
harder to diff against hand-written templates or the original Serverless/SAM
output, and reduces the readability of the generated JSON.

I maintain a fork of jsonnet-go that adds a `--preserve-field-order` flag:
[github.com/vivainio/go-jsonnet-fork](https://github.com/vivainio/go-jsonnet-fork).
With this flag, keys appear in the order you wrote them in the `.jsonnet` file,
which makes diffs cleaner and the output easier to read. I plan to propose this
for upstream after more usage.

**Not yet battle-tested.** This approach has not been used for any production
serverless stack yet. The library and examples are functional but unproven at
scale. Any loss of resources or data resulting from deploying these templates is
your responsibility. Always review the CloudFormation changeset before deploying
— `aws cloudformation deploy` shows the diff, and you should read every line of
it before confirming.

**AI-authored content.** All prose, library code, and examples in this
repository were authored by Claude Opus 4.6 and reviewed by a (presumed)
human.
