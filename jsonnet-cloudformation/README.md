# Ejecting Serverless with Jsonnet

## Why leave

Serverless Framework v4 switched to a commercial license. Deployments now
require a Serverless Inc. account, report telemetry to their dashboard, and
organizations above a revenue threshold need a paid subscription. The
open-source v3 branch is frozen — no security patches, no new runtime support.

If you have dozens of services in production, this means either paying per seat
for a build tool that wraps CloudFormation, or migrating. Most teams start
evaluating alternatives at this point.

### The usual alternatives

**AWS SAM** is the natural first stop. It's AWS-native, open source, and
`AWS::Serverless::Function` is a clean abstraction. The problem is the SAM
transform: your template is rewritten by CloudFormation at deploy time. When
something goes wrong, you're debugging resources you didn't declare. You can
run `sam build` to preview the expansion, but the authoritative template — the
one CloudFormation actually acts on — is generated server-side. You traded one
black box for another.

**AWS CDK** is popular but carries real costs. It requires a Node.js runtime
and `npm install` for every project, pulling in hundreds of transitive
dependencies. `cdk synth` runs your TypeScript/Python through a full
compilation step to emit CloudFormation JSON — on a cold `node_modules` this
takes 20-60 seconds even for small stacks. CI pipelines need a Node runtime
image, `npx cdk` bootstrapping, and CDK-specific IAM permissions. For teams
whose Lambda functions are Python or Go, maintaining a Node toolchain solely
for the deployment layer is overhead that never pays for itself. CDK also
generates CloudFormation with machine-generated logical IDs (hashes), making
diffs and troubleshooting harder than hand-written templates.

**Terraform** is a legitimate option but means adopting an entirely new state
management model, HCL syntax, and provider versioning. If your infrastructure
is already CloudFormation, switching to Terraform is a bigger migration than
the problem you're solving.

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
instant.

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

The migration is mechanical:

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
