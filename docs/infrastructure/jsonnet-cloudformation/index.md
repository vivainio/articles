# Ejecting Serverless with Jsonnet

## Contents

- [Why leave](#why-leave) — SAM, CDK, and what we actually need
- [The migration path](#the-migration-path) — how to port existing stacks
- [The boilerplate problem](#the-boilerplate-problem) — what SLS/SAM hide from you
- [The Jsonnet approach](#the-jsonnet-approach) — what the replacement looks like
- [What the library wraps](#what-the-library-wraps) — mapping SLS/SAM concepts to helpers
- [Examples](#examples) — scheduled worker, REST API, SQS consumer, HTTP API
- [Multi-stage from a single file](#multi-stage-from-a-single-file)
- [Deploying code separately](#deploying-code-separately) — update-function-code vs S3
- [Comparison](#comparison) — source lines, output transparency, build deps
- [How it works](#how-it-works) — object merging and custom abstractions
- [Replacing SAM with sam.libsonnet](#replacing-sam-with-samlibsonnet) — SAM-shaped input, plain CFN output
- [Beyond serverless](#beyond-serverless-greenfield-cloudformation) — resource factories, policy libraries, config-driven stacks
- [Targeting SAM output](#targeting-sam-output) — when to let SAM do the expansion
- [Trade-offs](#trade-offs) — what you gain and lose
- [Getting started](#getting-started)
- [Caveats](#caveats) — key ordering, maturity, AI authorship

## Why leave

Serverless Framework v4 [switched to a commercial
license](https://www.serverless.com/blog/serverless-framework-v4-a-new-model).
Deployments now require a Serverless Inc. account, report telemetry to their
dashboard, and organizations above a revenue threshold need a paid
subscription. The open-source v3 branch is frozen — no security patches, no
new runtime support.

If you have dozens or even hundreds of services in production, this means either paying per seat
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
leaves you on your own for everything else.

### Why not CDK?

AWS CDK is popular but carries real costs. Even if you write your
infrastructure in Python or C#, CDK's core runs on Node.js — you still need a
Node runtime, `node_modules`, and the full tree of npm dependencies in every
project and CI pipeline. `cdk synth` runs your code through jsii (the
cross-language bridge) and Node to emit CloudFormation JSON — on a cold
`node_modules` this takes 20-60 seconds even for small stacks. If you use
TypeScript (the most common CDK language), add the compilation step on top —
`tsc` or `ts-node` adds its own startup overhead to every synth. CI pipelines
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

There's also the migration problem: CDK creates its own stacks with its own
logical IDs. You can't deploy CDK to your existing Serverless/SAM stacks —
you'd be creating entirely new stacks alongside the old ones, then migrating
stateful resources (DynamoDB tables, SQS queues, S3 buckets) from the old
stacks to the new ones. That means `DeletionPolicy: Retain`, manual imports,
and careful ordering — one mistake and you lose data.

CDK shines when you're building from scratch with large, complex infrastructure
— but for migrating existing serverless stacks, it's the wrong tool.

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
everything stays declarative. Declarative here means: data goes in, JSON comes
out, and nothing else happens. There are no side effects — no file writes, no
network calls, no mutable state. You define data, not procedures. The output of
a Jsonnet file *is* the template, not a side effect of running a program. And unlike CDK, there is no `node_modules` directory, no transitive
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
   becomes `sls.lambdaFnG(...)`. The 50-line CORS OPTIONS mock becomes
   `sls.corsOptions(...)`. Service-specific resources (DynamoDB tables, custom
   IAM statements) stay as inline Jsonnet objects.

4. **Verify** by diffing the Jsonnet output against the captured original:
   `diff <(jsonnet my-service.jsonnet) captured-original.json`. The resource
   structure should match — key names, types, properties. Minor differences
   in JSON key ordering are expected (Jsonnet [sorts alphabetically](#caveats)).

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
local sls = import 'lib/sls.libsonnet';

{
  AWSTemplateFormatVersion: '2010-09-09',
  Resources:
    sls.deploymentBucketG
    + sls.iamRoleG('my-service-dev', [...])
    + sls.lambdaFnG('Worker', { FunctionName: 'my-service-dev-worker', Handler: '...', ... })
    + sls.scheduleEventG('Worker', 'cron(0 3 * * ? *)'),
}
```

Run `jsonnet my-service.jsonnet` and you get plain CloudFormation JSON — no
transform, no framework, no plugins. What you see is what deploys.

## What the library wraps

Each helper maps to what SLS/SAM auto-generated from a high-level declaration:

| SLS / SAM concept | Library helper | CFN resources generated |
|---|---|---|
| `functions:` entry | `sls.lambdaFnG(...)` | LogGroup + Function + Version |
| `events: - schedule:` | `sls.scheduleEventG(...)` | Events::Rule + Lambda::Permission |
| `events: - sqs:` | `sls.sqsEventSource(...)` | Lambda::EventSourceMapping |
| `events: - http:` | `sls.apiMethod(...)` + `sls.corsOptions(...)` | Method + CORS OPTIONS mock |
| `events: - httpApi:` | `sls.httpApiFnG(...)` | Integration + Routes + Permission |
| `provider.iamRoleStatements` | `sls.iamRoleG(...)` | IAM::Role with scoped log perms |
| `provider.apiKeys` | (manual) | ApiKey + UsagePlan + UsagePlanKey |
| implicit | `sls.deploymentBucketG` | S3::Bucket + BucketPolicy |
| SLS log-subscription plugin | `sls.lambdaFnG(..., logDestination=...)` | Logs::SubscriptionFilter |

## Examples

Each `.jsonnet` file has a matching `.yaml` file next to it containing the
expanded CloudFormation output, so you can see what the template generates
without installing Jsonnet.

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

### 5. Parameterized worker (91 lines → 5 resources)

A VPC-attached Lambda with CloudFormation input parameters: stage selection
with `AllowedValues`, VPC/subnet IDs, an SSM parameter for secrets, and a
cross-stack export. Demonstrates `cfn.param()`, `cfn.ssmParam()`, and
`cfn.exportOutput()`.

→ [`examples/parameterized-worker.jsonnet`](examples/parameterized-worker.jsonnet)

### 6. Clean-room stack (~50 lines → 10 resources)

A production-shaped stack built with `aws.libsonnet` — no Serverless Framework
conventions, no fixed logical IDs. Lambda + DynamoDB table + S3 bucket + IAM
role + cross-account invoker role + log forwarding to Kinesis + SSM parameter
exports. Every resource name is explicit and visible in the source.

→ [`examples/clean-app.jsonnet`](examples/clean-app.jsonnet)

### 7. Internal ALB with target-group factory (231 lines → 18 resources)

Three node types (AppServer, JobRunner, Gateway) each need an internal ALB
with 1–4 target groups. A `tgPair()` factory produces a matching TargetGroup +
Listener per port, and `internalAlb()` assembles the full ALB + security group +
N pairs from a compact config. Optional S3 access-log attributes, HTTPS
certificate wiring, and a `tgArns` handle for plugging into ASGs.

→ [`examples/load-balancer.jsonnet`](examples/load-balancer.jsonnet)

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
| **Jsonnet + sls.libsonnet** | **~100** | **Exactly what you wrote** | **Single binary, no deps** |
| **Jsonnet + sam.libsonnet** | **~80–97** | **Exactly what you wrote** | **Single binary, no deps** |

The Jsonnet source is comparable in size to SAM, but the output is plain
CloudFormation with no transform step. You can diff it, review it in PRs, and
`cfn-lint` it directly. The sam.libsonnet layer is even more concise because
it auto-generates the API Gateway resource tree from event declarations.

## How it works

Every helper is a Jsonnet function that returns a plain object:

```jsonnet
lambdaFnG('Worker', { FunctionName: 'svc-dev-worker', Handler: 'h.main', ... })
// returns:
// {
//   WorkerLogGroup: { Type: 'AWS::Logs::LogGroup', ... },
//   WorkerLambdaFunction: { Type: 'AWS::Lambda::Function', ... },
//   WorkerLambdaVersion: { Type: 'AWS::Lambda::Version', ... },
// }
```

Functions ending in **G** (for "group") return `{ LogicalId: Resource, ... }`
objects containing multiple resources — merge them with `+`. All other
functions return a single resource value, used as `{ LogicalId: sls.helper(...) }`:

```jsonnet
Resources:
  sls.deploymentBucketG              // S3 bucket + policy (fixed keys)
  + sls.iamRoleG(...)                // IAM role (fixed key)
  + sls.lambdaFnG(...)             // LogGroup + Function + Version
  + sls.scheduleEventG(...)        // Events::Rule + Permission
  + {
    OrderDLQ: sls.sqsQueue(...),   // single resource — key is the CFN logical ID
    OrderQueue: sls.sqsQueue(...),
  }
```

The G functions expand a name prefix into multiple derived resource keys.
Single-resource helpers return bare values, so the logical ID is visible in
your source — matching the CloudFormation output. Each helper is independent,
there's no hidden state, and the output is a flat resource map that
CloudFormation consumes directly.

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
lambdaFnG('Handler', { ..., Tags: standardTags(service, stage) })
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
  // to the central Firehose. Merge with `+` next to sls.lambdaFnG().
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
  sls.lambdaFnG('Worker', { FunctionName: fnName, Handler: '...', ... })
  + co.logForwarding('Worker', fnName, firehoseArn, logRoleArn)
  + sls.scheduleEventG('Worker', 'cron(0 3 * * ? *)'),
```

No wrapping, no override — `sls.lambdaFnG` stays untouched and the mixin is
just another object merged in. This is the same pattern CDK teams achieve with
custom constructs, but the abstraction is a pure data transformation: you can
print the output, diff it, and reason about it without running anything.

A simpler but equally useful pattern is a shared constants file — mapping
human-readable names to AWS account numbers, region codes, and other
magic strings that would otherwise be scattered across templates:

```jsonnet
// lib/constants.libsonnet
{
  regions: {
    dub: 'eu-west-1',
    fra: 'eu-central-1',
    iad: 'us-east-1',
    pdx: 'us-west-2',
  },
  accounts: {
    dev:     '111111111111',
    staging: '222222222222',
    prod:    '333333333333',
  },
  firehose: {
    logArn: 'arn:aws:firehose:eu-west-1:111111111111:deliverystream/central-logs',
    roleArn: 'arn:aws:iam::111111111111:role/firehose-log-role',
  },
}
```

Every service imports the same file. Account numbers never change, but
`constants.accounts.prod` is easier to review in a PR than a bare
12-digit number — and you can't typo it.

Unlike CDK, the abstraction can never get in the way. In CDK, when a construct
doesn't expose the property you need, you're stuck — you have to use escape
hatches, cast to `CfnResource`, or fight the type system. In Jsonnet, every
helper returns a plain object. If a helper doesn't do what you need, you merge
in a raw CloudFormation block with `+` right next to it — no escape hatch, no
special API, just data. High-level helpers and low-level resources coexist in
the same file, in the same `Resources:` object, with the same merge operator.

CDK also makes reorganization painful: moving a resource from one construct to
another changes its logical ID (because the construct path is part of the
hash), which CloudFormation treats as a delete-and-recreate. CDK has a
"refactor" mode to handle this, but it's another thing to know about and get
right. In Jsonnet, logical IDs are just object keys — you control them
directly, and moving code between files or functions doesn't change anything in
the output.

## Replacing SAM with sam.libsonnet

If you're already using SAM templates (or thinking in SAM terms), there's a
second library — `sam.libsonnet` — that accepts SAM-shaped declarations and
expands them to raw CloudFormation through `sls.libsonnet`.

### Why replace SAM?

SAM templates are concise. A function with five API routes is about 40 lines.
But the SAM transform is a black box: you submit a template with
`AWS::Serverless::Function` and CloudFormation expands it at deploy time. You
can run `sam build` to preview, but in production you're trusting the
transform. When something goes wrong, you're debugging resources you didn't
declare.

SAM also doesn't support custom abstractions — there's no way to define
reusable patterns like the company-wide log forwarding mixin shown earlier.
You get the built-in resource types and nothing else.

`sam.libsonnet` performs the same expansion at build time. The developer writes
SAM-shaped input, but the output is plain CloudFormation — no `Transform:`
header, no deploy-time surprises.

### How it works

SAM's `AWS::Serverless::Function` puts events *inside* the function as an
`Events:` map. The transform then generates the external resources (API Gateway
methods, EventSourceMappings, permissions). `sam.libsonnet` does the same:

```jsonnet
local sam = import 'lib/sam.libsonnet';
local sls = import 'lib/sls.libsonnet';

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
    sls.iamRoleG('my-service-dev', fn.extraStatements)
    + fn.resources     // LogGroup + Function + Version
    + api.resources,   // RestApi + Resources + Methods + CORS + Deployment
}
```

The `sam.Function()` call returns:
- `.resources` — the Lambda triplet (and any non-API event resources)
- `.extraStatements` — IAM statements extracted from `Policies:` (pass to `sls.iamRoleG`)
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

These produce the same CloudFormation output as the direct sls.libsonnet
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

### Libraries

Four libraries, pick the level that fits:

- **`cfn.libsonnet`** — general-purpose CloudFormation helpers: intrinsic
  function shorthands (`getAtt`, `getArn`, `sub`, `ref`, `arn`), IAM policy
  builders (`allow`, `deny`, `policies`), parameter and output helpers,
  SSM parameter exports, and tag conversion.
- **`aws.libsonnet`** — clean-room resource helpers with no SLS/SAM
  conventions: `lambdaG`, `lambdaRole`, `serviceRole`, `assumableRole`,
  `table`, `bucket`, `logSubscription`, `scheduleG`. No fixed logical IDs —
  you pick every resource name.
- **`sls.libsonnet`** — serverless resource builders that match Serverless
  Framework naming: `lambdaFnG`, `iamRoleG`, `deploymentBucketG`, API Gateway,
  SQS, and schedule event wiring. Use for migrating existing SLS stacks in-place.
- **`sam.libsonnet`** — high-level SAM-shaped interface. Events are declared
  inline, API resource trees are generated automatically. Calls `sls.libsonnet`
  under the hood.

For new projects, start with `cfn` + `aws`. For migrating existing Serverless
Framework stacks, use `cfn` + `sls` (or `sam`) to preserve logical IDs.
All produce the same plain CloudFormation JSON.

## Beyond serverless — greenfield CloudFormation

This article started as an SLS migration guide, but the same approach works
for any CloudFormation stack. The `cfn.libsonnet` and `aws.libsonnet` libraries
have no Serverless Framework conventions — they're general-purpose helpers for
writing CloudFormation as Jsonnet. Once you have functions, imports, and object
merging, the patterns that emerge go well beyond Lambda and API Gateway.

### Resource factories

The most common pattern: a function that takes a config object and returns a
bundle of related resources. The caller gets back a handle with `Ref`s and
`GetAtt`s for wiring into other resources.

- **Internal ALB** — `internalAlb()` produces ALB + security group + N
  target-group/listener pairs from a port list. Three node types with different
  port configurations use the same factory.
  → [`load-balancer.jsonnet`](examples/load-balancer.jsonnet) (231 lines → 18 resources)

- **Static site** — `staticSite()` produces S3 bucket + OAC + CloudFront
  distribution + CloudFront Function + bucket policy. An array of site configs
  is iterated with `std.foldl` to merge all resources.
  → [`static-site.jsonnet`](examples/static-site.jsonnet) (289 lines → 15 resources)

- **Queue with DLQ** — `queueWithDlq()` creates an SQS queue + dead-letter
  queue pair with consistent naming and redrive policy.
  → [`sample-patterns.jsonnet`](examples/sample-patterns.jsonnet) (278 lines → 23 resources)

### IAM policy libraries

IAM policies are the worst offender for copy-paste in CloudFormation. The same
`kms:Decrypt` + `kms:GenerateDataKey` block shows up on every role that touches
an encrypted resource, differing only in the key ARN. A policy library turns
these into composable functions:

```jsonnet
local workerStatements =
  policies.ddbWrite(tableName)
  + policies.s3ReadWrite(bucketName)
  + policies.kmsViaService('s3')
  + policies.sqsConsume(inboundQueue.queueArn)
  + policies.ssmRead('/' + service + '/' + stage + '/*');
```

Each function returns an array of IAM policy statements. Compose them with `+`
and pass the result to a role builder. See the policy library and ECR
repository factory in
[`sample-patterns.jsonnet`](examples/sample-patterns.jsonnet).

### Config-driven encryption

KMS keys with service-specific grants follow a rigid structure — the key
resource, an alias, and a grant policy that varies by consumer. A factory
function parameterized by service name and principal ARNs eliminates the
repetition.
→ [`kms-keys.jsonnet`](examples/kms-keys.jsonnet) (152 lines → 12 resources)

### Deny-all-except bucket policies

A locked-down S3 bucket that denies all access except from a whitelist of IAM
roles is a common compliance pattern. The interesting part is generating the
`StringNotLike` condition from an array of role ARNs.
→ [`protected-bucket.jsonnet`](examples/protected-bucket.jsonnet) (191 lines → 6 resources)

### Step Functions

State machine definitions are deeply nested JSON that benefits from Jsonnet's
ability to build objects from smaller pieces. A helper library
(`sfn.libsonnet`) provides shorthand for common states, and the machine
definition composes them with `+`.
→ [`step-functions.jsonnet`](examples/step-functions.jsonnet) (245 lines → 7 resources)

### Starting a greenfield project

For a new project that has nothing to migrate:

1. Copy `lib/cfn.libsonnet` and `lib/aws.libsonnet` into your repo
2. Copy `lib/cfn-actions.libsonnet` if you want pre-defined IAM action lists
3. Write `.jsonnet` files importing these libraries
4. Add project-specific factories as local functions or in a `lib/` file

There's no framework to initialize, no bootstrap step, and no convention to
follow beyond "functions return objects, merge with `+`." Start with inline
local functions. Extract to a shared `.libsonnet` file when the same pattern
appears in a second stack.

## Targeting SAM output

Everything above assumes Jsonnet replaces SAM by expanding to raw
CloudFormation. But Jsonnet can also produce SAM templates — just emit
`Transform: 'AWS::Serverless-2016-10-31'` and use `AWS::Serverless::Function`
directly. This makes sense when your existing SAM template already works and
the complexity is elsewhere: duplicated IAM policies across multiple roles,
repeated VPC/tag/environment blocks across functions, or derived values that
are awkward to thread through CloudFormation `!Sub` and `!Ref`. Jsonnet handles
composition and deduplication; SAM handles Lambda packaging and the
`sam deploy` workflow. The output is JSON, and `sam deploy --template-file`
accepts JSON the same as YAML. If you prefer YAML for readability or
diff-friendliness, a one-liner in your build script converts the output:
`jsonnet template.jsonnet | python3 -c 'import sys,json,yaml; yaml.dump(json.load(sys.stdin),sys.stdout,default_flow_style=False)'`.
This is the pragmatic choice when the SAM transform is earning its keep and you don't want
to rewrite working infrastructure just to avoid it.

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
2. Copy `lib/cfn.libsonnet` and `lib/sls.libsonnet` into your project (and
   `lib/sam.libsonnet` if you want the SAM-style interface, or `lib/aws.libsonnet`
   for clean-room templates with no SLS naming conventions)
3. Write a `.jsonnet` file importing the library
4. Render: `jsonnet --ext-str stage=dev my-service.jsonnet > template.json`
5. Validate: `aws cloudformation validate-template --template-body file://template.json`
6. Package: `aws cloudformation package --template-file template.json --s3-bucket my-deploy-bucket --output-template-file packaged.json`
   (uploads Lambda code referenced by local paths, rewrites `Code` to S3 URIs)
7. Deploy: `aws cloudformation deploy --template-file packaged.json --stack-name my-service-dev --capabilities CAPABILITY_NAMED_IAM`

## Caveats

**Key ordering.** The Go implementation of Jsonnet (`jsonnet-go`, which is what
`brew install go-jsonnet` and most package managers ship) sorts object keys
alphabetically by default. This means your output JSON will have `Resources`
before `AWSTemplateFormatVersion`, and properties within each resource will be
reordered. CloudFormation doesn't care about key order, but it makes the output
harder to diff against hand-written templates or the original Serverless/SAM
output, and reduces the readability of the generated JSON.

I maintain a fork of jsonnet-go that adds a `--preserve-field-order` flag.
Pre-built binaries are available at
[github.com/vivainio/go-jsonnet-fork v0.22.1-fork.1](https://github.com/vivainio/go-jsonnet-fork/releases/tag/v0.22.1-fork.1).
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

## Related writing

- [What Cloudflare's Free Tier Gives Vibe Coders](../../building/cloudflare-free-tier.md)
  looks at a much smaller cloud stack where the deployment model is part of the
  appeal.
- [My Vibing Flow](../../ai-agents/my-vibing-flow.md) describes the
  agent-assisted working style behind experiments like this one.
