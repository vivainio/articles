// Example: Queue-with-DLQ factory and reusable IAM policy library
//
// Patterns extracted from a production CDK codebase:
//
// 1. queueWithDlq() — creates an SQS queue + dead-letter queue pair
//    with consistent naming, SSL enforcement, and tagging.
//    CDK equivalent: a class method that returns sqs.Queue with DLQ.
//
// 2. policies{} — a library of IAM policy statements for common
//    access patterns (DynamoDB, S3+KMS, SQS, RDS Proxy, SSM).
//    CDK equivalent: a Policies class with ~15 static factory methods,
//    each returning iam.PolicyDocument. In Jsonnet these are just
//    functions that return statement objects for cfn.allow().
//
// The CDK version spreads these across two 400-line TypeScript classes.
// Here the same patterns fit in local functions + a service wiring example.

local aws = import '../lib/aws.libsonnet';
local actions = import '../lib/cfn-actions.libsonnet';
local cfn = import '../lib/cfn.libsonnet';

local service = 'order-service';
local stage = std.extVar('stage');
local prefix = service + '-' + stage;

// ── Queue-with-DLQ factory ─────────────────────────────────────────────
// CDK's createQueueWithDlq() auto-derives PascalCase IDs from kebab names,
// applies mandatory tags, and wires the redrive policy. Same idea here,
// but returns a { resources, queueRef, dlqRef, queueArn } object.

local queueWithDlq(baseName, visibilityTimeout=900, maxReceiveCount=10, tags=[]) =
  local queueName = baseName + '-q-' + prefix;
  local dlqName = baseName + '-dlq-' + prefix;
  // kebab-to-PascalCase for logical IDs
  local pascal = std.join('', [
    std.asciiUpper(part[0]) + part[1:]
    for part in std.split(baseName, '-')
  ]);
  {
    resources: {
      [pascal + 'Dlq']: {
        Type: 'AWS::SQS::Queue',
        Properties: {
          QueueName: dlqName,
          MessageRetentionPeriod: 1209600,  // 14 days
        } + (if tags != [] then { Tags: tags } else {}),
      },
      [pascal + 'Queue']: {
        Type: 'AWS::SQS::Queue',
        Properties: {
          QueueName: queueName,
          VisibilityTimeout: visibilityTimeout,
          RedrivePolicy: {
            deadLetterTargetArn: cfn.getAtt(pascal + 'Dlq', 'Arn'),
            maxReceiveCount: maxReceiveCount,
          },
        } + (if tags != [] then { Tags: tags } else {}),
      },
    },
    queueRef: cfn.ref(pascal + 'Queue'),
    dlqRef: cfn.ref(pascal + 'Dlq'),
    queueArn: cfn.getAtt(pascal + 'Queue', 'Arn'),
    queueLogical: pascal + 'Queue',
  };

// ── Policy library ─────────────────────────────────────────────────────
// Each function returns one or more IAM policy statements (not a full
// PolicyDocument — that's the Role's job). Compose with array concat.
//
// CDK equivalent: static methods on a Policies class, each returning
// new iam.PolicyDocument({ statements: [...] }).

local policies = {
  // DynamoDB: read, write, or full access to a named table (+ optional index)
  ddbRead(table)::
    [cfn.allow(actions.ddbRead, cfn.arn('dynamodb', 'table/' + table))],

  ddbWrite(table)::
    [cfn.allow(actions.ddbAll, cfn.arn('dynamodb', 'table/' + table))],

  ddbWithIndex(table, acts)::
    [cfn.allow(acts, [
      cfn.arn('dynamodb', 'table/' + table),
      cfn.arn('dynamodb', 'table/' + table + '/index/*'),
    ])],

  // S3: read/write with KMS condition for customer-managed key access
  s3ReadWrite(bucket)::
    [
      cfn.allow(actions.s3Read + actions.s3Write, 'arn:aws:s3:::' + bucket + '/*'),
      cfn.allow(actions.s3List, 'arn:aws:s3:::' + bucket),
    ],

  s3Read(bucket)::
    [
      cfn.allow(actions.s3Read, 'arn:aws:s3:::' + bucket + '/*'),
      cfn.allow(actions.s3List, 'arn:aws:s3:::' + bucket),
    ],

  // KMS via-service: scoped decryption through a specific AWS service
  kmsViaService(svc)::
    [cfn.allow(
      ['kms:Decrypt', 'kms:GenerateDataKey', 'kms:DescribeKey'],
      cfn.arn('kms', 'key/*'),
      condition={ StringEquals: { 'kms:ViaService': [cfn.sub(svc + '.${AWS::Region}.amazonaws.com')] } },
    )],

  // SQS: consume (for Lambda workers) or send (for producers)
  sqsConsume(queueArn)::
    [cfn.allow(actions.sqsConsume, queueArn)],

  sqsSend(queueArns)::
    [cfn.allow(actions.sqsSend, queueArns)],

  // RDS Proxy: IAM-authenticated database connection
  rdsProxyConnect(proxyResourceId, dbUser)::
    [cfn.allow(
      ['rds-db:connect'],
      cfn.sub('arn:${AWS::Partition}:rds-db:${AWS::Region}:${AWS::AccountId}:dbuser:' + proxyResourceId + '/' + dbUser),
    )],

  // SSM Parameter Store: read with optional KMS decrypt for SecureString
  ssmRead(paramPath, withDecrypt=false)::
    [cfn.allow(
      actions.ssmRead,
      cfn.arn('ssm', 'parameter' + paramPath),
    )]
    + (if withDecrypt then [cfn.allow(
         ['kms:Decrypt'],
         cfn.arn('kms', 'alias/aws/ssm'),
       )] else []),

  // Cross-account: assume a role in another account
  assumeRole(roleArn)::
    [cfn.allow(['sts:AssumeRole'], roleArn)],

  // Lambda: invoke another function
  invoke(fnArn)::
    [cfn.allow(actions.lambdaInvoke, fnArn)],
};

// ── ECR repository factory ─────────────────────────────────────────────
// A shared ECR repo needs the same 7 actions listed for CodeBuild and
// again for cross-account principals. The YAML original copy-pastes the
// action list twice per repo, and duplicates the entire template when a
// second repo is needed. Here, one function covers both cases.

local ecrRepo(name, crossAccountIds=[], tags=[]) = {
  Type: 'AWS::ECR::Repository',
  Properties: {
    RepositoryName: name,
    RepositoryPolicyText: {
      Version: '2012-10-17',
      Statement:
        [{
          Sid: 'CodeBuildAccess',
          Effect: 'Allow',
          Principal: { Service: 'codebuild.amazonaws.com' },
          Action: actions.ecrAll,
        }]
        + (if crossAccountIds != [] then [{
             Sid: 'CrossAccountAccess',
             Effect: 'Allow',
             Principal: {
               AWS: ['arn:aws:iam::' + id + ':root' for id in crossAccountIds],
             },
             Action: actions.ecrAll,
           }] else []),
    },
  } + (if tags != [] then { Tags: tags } else {}),
};

// ── Service wiring ─────────────────────────────────────────────────────
// A sample app with an API Lambda, two SQS workers, and shared resources.
// Shows how the queue factory and policy library compose.

local tags = cfn.tags({ Service: service, Stage: stage });

local inboundQueue = queueWithDlq('inbound', tags=tags);
local enrichQueue = queueWithDlq('enrich', tags=tags);  // default 900s matches Lambda timeout

local tableName = service + '-work-' + stage;
local bucketName = service + '-store-' + stage;
local proxyId = 'prx-0123456789abcdef0';  // from SSM in real usage

// Compose the role's policy from small, testable pieces
local workerStatements =
  policies.ddbWrite(tableName)
  + policies.s3ReadWrite(bucketName)
  + policies.kmsViaService('s3')
  + policies.kmsViaService('dynamodb')
  + policies.sqsConsume(inboundQueue.queueArn)
  + policies.sqsConsume(enrichQueue.queueArn)
  + policies.rdsProxyConnect(proxyId, 'app_user')
  + policies.ssmRead('/' + service + '/' + stage + '/*');

local apiStatements =
  policies.ddbRead(tableName)
  + policies.s3Read(bucketName)
  + policies.kmsViaService('s3')
  + policies.sqsSend([inboundQueue.queueArn])
  + policies.ssmRead('/' + service + '/' + stage + '/*', withDecrypt=true);

local apiLambda = aws.lambda('Api', {
  FunctionName: prefix + '-api',
  Handler: 'api.handler',
  Code: { S3Bucket: 'deploy-artifacts', S3Key: service + '/' + stage + '/package.zip' },
  Role: cfn.getArn('ApiRole'),
  Environment: { Variables: {
    STAGE: stage,
    TABLE_NAME: tableName,
    BUCKET_NAME: bucketName,
    INBOUND_QUEUE_URL: inboundQueue.queueRef,
  } },
});

local workerLambda = aws.lambda('Worker', {
  FunctionName: prefix + '-worker',
  Handler: 'worker.handler',
  Code: { S3Bucket: 'deploy-artifacts', S3Key: service + '/' + stage + '/package.zip' },
  Role: cfn.getArn('WorkerRole'),
  MemorySize: 256,
  Timeout: 900,
  Environment: { Variables: {
    STAGE: stage,
    TABLE_NAME: tableName,
    BUCKET_NAME: bucketName,
    ENRICH_QUEUE_URL: enrichQueue.queueRef,
  } },
});

{
  AWSTemplateFormatVersion: '2010-09-09',
  Description: service + ' (' + stage + ') — API + SQS workers',

  Resources:
    // Queues (factory creates both queue + DLQ per call)
    inboundQueue.resources
    + enrichQueue.resources

    // Lambdas
    + apiLambda.resources
    + workerLambda.resources

    // SQS event source mappings
    + { InboundMapping: workerLambda.sqsSource(inboundQueue.queueLogical) }
    + { EnrichMapping: workerLambda.sqsSource(enrichQueue.queueLogical) }

    // HTTP API wired to the API Lambda
    + aws.httpApiG('Api', prefix)
    + apiLambda.routes('Api', {
      Default: { routeKey: '$default' },
    })

    // Roles built from policy library
    + {
      ApiRole: aws.lambdaRole(prefix + '-api', apiStatements),
      WorkerRole: aws.lambdaRole(prefix + '-worker', workerStatements),

      // DynamoDB work table
      WorkTable: aws.table(tableName, 'pk', 'sk'),

      // S3 store bucket
      StoreBucket: aws.bucket(bucketName),

      // ECR repos — same factory, different cross-account lists
      AppRepo: ecrRepo(service + '-app', tags=tags),
      RuntimeRepo: ecrRepo(service + '-runtime',
                           crossAccountIds=['111111111111', '222222222222'],
                           tags=tags),
    },

  Outputs: {
    ApiEndpoint: cfn.output(cfn.sub('https://${Api}.execute-api.${AWS::Region}.${AWS::URLSuffix}')),
    InboundQueueUrl: cfn.output(inboundQueue.queueRef),
    EnrichQueueUrl: cfn.output(enrichQueue.queueRef),
  },
}
