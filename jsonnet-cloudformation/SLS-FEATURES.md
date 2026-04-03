# Serverless Framework features replaced by Jsonnet

A catalogue of Serverless Framework features, how they work internally, and
what replaces them in the Jsonnet approach.

## Variable interpolation

### `${self:...}` / `${opt:...}` — package-time resolution

SLS resolves these when running `sls package`. They become string literals in
the generated CloudFormation JSON. `${self:provider.stage}` becomes `"dev"`,
`${opt:region}` becomes `"eu-west-1"`.

**Jsonnet replacement:** `std.extVar('stage')` or a local variable. Resolved
at render time by passing `--ext-str stage=dev` on the command line.

### `#{AWS::AccountId}` — the `serverless-cf-vars` plugin

The plugin rewrites `#{...}` to `${...}` in the output JSON so that
CloudFormation's `Fn::Sub` resolves them at deploy time. Without the plugin,
SLS would try to resolve `${AWS::AccountId}` as its own variable and fail.
In the generated JSON these appear inside `Fn::Sub` expressions.

**Jsonnet replacement:** `cfn.sub('...${AWS::AccountId}...')` or
`cfn.arn(service, resource)` which generates `Fn::Sub` directly.

### `${file(path):field}` — file-based lookups

Resolved at package time. Common variants:

- **Build metadata:** `${file(build_info.yml):Branch}` — CI-generated file
  with branch, commit, build number. Injected into resource tags.
- **Stage-keyed config:** `${file(references.yml):${self:provider.stage}.subnetIds}`
  — a YAML file with per-stage values for VPC IDs, subnet lists, etc.

**Jsonnet replacement:**
- Build metadata → `std.extVar('branch')` etc., passed at render time.
- Stage-keyed config → `import 'config.json'` (Jsonnet natively imports JSON
  as objects) or `std.extVar` for individual values. YAML files need
  conversion to JSON first since Jsonnet has no YAML parser.

### `default-*` placeholder + `sed` — deploy-time string replacement

When one `sls package` output is deployed to multiple stages/regions, the
`serverless.yml` uses made-up defaults (`default-stage`, `default-kmskey`,
`default-region`, etc.) that appear as string literals in the generated JSON.
The deploy script then runs `sed -i "s/default-stage/${REAL_VALUE}/g"` on the
JSON before `sls deploy --package`.

This is global string replacement on machine-generated JSON. If the
placeholder appears in an unexpected context, or a real value contains the
placeholder string, things break silently. Larger services can have 8+
separate `sed` replacements in the deploy script.

Example from a typical deploy script:

```bash
sed -i -e "s/default-stage/${TARGET_STAGE}/g" cloudformation-template-update-stack.json
sed -i -e "s/default-region/${TARGET_REGION}/g" cloudformation-template-update-stack.json
sed -i -e "s|default-kmskey|${KMS_KEY_ARN}|g" cloudformation-template-update-stack.json
sed -i -e "s/default-snsTopic/${SNS_TOPIC_ARN}/g" cloudformation-template-update-stack.json
sed -i -e "s/default-apiToken/${API_TOKEN}/g" cloudformation-template-update-stack.json
sed -i -e "s/eu-west-1/${TARGET_REGION}/g" cloudformation-template-update-stack.json
```

Note the `eu-west-1` replacement — this is the default region from
`serverless.yml` that leaked into the generated JSON as a hardcoded literal,
requiring a second `sed` pass on top of the `default-region` replacement.

**Jsonnet replacement:** `std.extVar(...)` for every parameterized value.
Resolved at render time with no string replacement. This is often the single
biggest reliability win of the migration.

### `{{resolve:ssm:/path}}` — CloudFormation dynamic references

These pass through SLS untouched and are resolved by CloudFormation at deploy
time. Common for Splunk log destinations, VPC IDs, subnet IDs, KMS keys.

**Jsonnet replacement:** Keep as literal strings — they work in raw
CloudFormation JSON unchanged. Example:
`'{{resolve:ssm:/Monitoring/Splunk/Destination}}'`.

## Resource generation

### Lambda function expansion

A 7-line function definition in `serverless.yml`:

```yaml
functions:
  myHandler:
    handler: src/handler.main
    timeout: 30
```

Expands to 3 CloudFormation resources (the "Lambda triplet"):
- `AWS::Logs::LogGroup` — log group named `/aws/lambda/{service}-{stage}-{functionKey}`
- `AWS::Lambda::Function` — the function itself, with defaults from `provider`
- `AWS::Lambda::Version` — a version resource with a hash-based logical ID

**Jsonnet replacement:** `sls.lambdaFnG('MyHandler', { ... })` generates the
same three resources. The logical ID prefix is explicit rather than derived
from the function key.

### IAM role generation

`provider.iamRoleStatements` generates a single `AWS::IAM::Role` shared by
all functions in the service. SLS automatically includes CloudWatch Logs
permissions (CreateLogStream, CreateLogGroup, PutLogEvents) scoped to the
service name prefix.

**Jsonnet replacement:** `sls.iamRoleG(namePrefix, extraStatements)`. The
base log permissions are generated automatically; only pass the extra
statements.

### Deployment bucket

SLS creates an `AWS::S3::Bucket` with AES256 encryption and an HTTPS-only
bucket policy in every template. Some services override this with
`provider.deploymentBucket.name` to use a shared bucket.

**Jsonnet replacement:** `sls.deploymentBucketG` (a constant). When a shared
bucket is used, omit this entirely.

### Schedule events

```yaml
events:
  - schedule:
      rate: cron(0 2 * * ? *)
      enabled: true
      input: '{"path": "/cleanup", "httpMethod": "GET"}'
```

Expands to 2 resources: `AWS::Events::Rule` + `AWS::Lambda::Permission`.

**Jsonnet replacement:** `sls.scheduleEventG(logicalName, schedule, enabled, ruleName)`.

### SQS event source

```yaml
events:
  - sqs:
      arn: !GetAtt MyQueue.Arn
      batchSize: 10
```

Expands to `AWS::Lambda::EventSourceMapping`. SLS also auto-adds
`sqs:ReceiveMessage`, `sqs:DeleteMessage`, `sqs:GetQueueAttributes` to the
IAM role.

**Jsonnet replacement:** `sls.sqsEventSource(functionLogical, queueArn, batchSize)`.
Remember to include the SQS consume permissions in `extraStatements` — Jsonnet
won't auto-add them.

### REST API (API Gateway v1)

```yaml
events:
  - http:
      path: '{proxy+}'
      method: any
      cors: true
      private: true
```

Expands to a large resource tree: `ApiGateway::RestApi`, `Resource` per path
segment, `Method` per route, CORS `OPTIONS` mock per path, `Deployment`,
`Lambda::Permission`, and optionally `ApiKey` + `UsagePlan` + `UsagePlanKey`
when `private: true` is set.

**Jsonnet replacement:** `sls.restApiG()` + `sls.apiResource()` +
`sls.apiMethod()` + `sls.corsOptions()` + `sls.apiDeployment()` +
`sls.apiLambdaPermission()`, or use `sam.Api()` which generates the full
tree from route declarations.

### HTTP API (API Gateway v2)

Simpler than REST API. Expands to: `ApiGatewayV2::Api`, `Stage`,
`Integration` per function, `Route` per event, `Lambda::Permission`.

**Jsonnet replacement:** `sls.httpApiG()` + `sls.httpApiFnG()`, or
`sam.HttpApi()`.

## Plugins

### `serverless-wsgi`

Wraps a Python WSGI app (Flask, Django) as a Lambda handler. Generates a
`wsgi_handler.py` that translates API Gateway events to WSGI requests.
Importantly, this means there are **no explicit `events`** on the function in
`serverless.yml` — the API Gateway is generated implicitly by the plugin, not
by SLS's event system. The function's handler is `wsgi_handler.handler`.

**Jsonnet replacement:** The `wsgi_handler.py` file is application code and
stays unchanged. The API Gateway resources still need to be generated — either
explicitly with `sls.restApiG()` etc., or by declaring an `http` event that
routes `{proxy+}` to the function.

### `serverless-python-requirements`

Bundles Python dependencies from `requirements.txt` into the deployment
package. Supports `dockerizePip` for cross-platform compilation and
`pipCmdExtraArgs` for platform-specific wheels.

**Jsonnet replacement:** None — this is a packaging concern, not
infrastructure. Replace with a build script that runs `pip install -t` or
uses Docker to build the package. The Jsonnet template just references the
pre-built artifact via `Code.S3Key` or `Code.S3Bucket`.

### `serverless-cf-vars`

See `#{AWS::AccountId}` above. Converts `#{...}` to `${...}` in the output
so CloudFormation pseudo-parameters work in string values.

**Jsonnet replacement:** Not needed. Jsonnet outputs JSON directly, and
`cfn.sub(...)` generates `Fn::Sub` intrinsics natively.

### `serverless-step-functions`

Allows defining Step Functions state machines inline in `serverless.yml`
under a `stepFunctions` top-level key. Generates
`AWS::StepFunctions::StateMachine` plus an IAM role.

**Jsonnet replacement:** `sfn.libsonnet` helpers for state machine
definitions, or inline Jsonnet objects. The state machine JSON is just data
— Jsonnet's object merging and local functions can factor out repeating
state patterns (e.g. Wait → Task → Verify loops).

## Build/deploy pipeline

### `sls package`

Generates CloudFormation JSON + packages code into a zip. Writes to
`.serverless/` or a `--package` output directory. Resolves all `${self:...}`
interpolation at this point.

**Jsonnet replacement:** `jsonnet --ext-str stage=... template.jsonnet > template.json`.
Code packaging is a separate build step (zip + upload to S3).

### `sls deploy --package`

Uploads the pre-packaged artifact to S3 and creates/updates the
CloudFormation stack. When used with the `sed` pattern, the deploy script
patches the generated JSON before calling `sls deploy`.

**Jsonnet replacement:**
`aws cloudformation deploy --template-file template.json --stack-name ... --capabilities CAPABILITY_NAMED_IAM`.
Or `sam deploy --template-file template.json` if targeting SAM output.

### Post-deploy orchestration

Some deploy scripts do more than just CloudFormation — they parse `sls deploy`
stdout for API keys/URLs, write values to SSM Parameter Store, create SSM
documents, register with proxies, etc. These steps are outside the template
and remain as shell scripts regardless of what generates the CloudFormation.
