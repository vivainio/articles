// Example 7: SAM-style SQS consumer — same output as sqs-worker.jsonnet
//
// The equivalent SAM template would be:
//
//   Transform: AWS::Serverless-2016-10-31
//   Resources:
//     Processor:
//       Type: AWS::Serverless::Function
//       Properties:
//         Handler: src/processor.handler
//         Runtime: nodejs20.x
//         ReservedConcurrentExecutions: 5
//         Events:
//           OrderEvent:
//             Type: SQS
//             Properties:
//               Queue: !GetAtt OrderQueue.Arn
//               BatchSize: 10

local sam = import '../lib/sam.libsonnet';
local cfn = import '../lib/cfn.libsonnet';

local service = 'order-processor';
local stage   = std.extVar('stage');
local tags    = cfn.tags({ Service: service, Stage: stage });

// ── AWS::Serverless::Function ────────────────────────────────────────────────
local processor = sam.Function('Processor', {
  Handler: 'src/processor.handler',
  Runtime: 'nodejs20.x',
  MemorySize: 256,
  Timeout: 30,
  CodeUri: 's3://my-deploy-bucket/' + service + '/' + stage + '/package.zip',
  ReservedConcurrentExecutions: 5,
  Environment: { Variables: { STAGE: stage, TABLE_NAME: 'orders-' + stage } },
  Tags: { Service: service, Stage: stage },
  Policies: [{
    Version: '2012-10-17',
    Statement: [
      {
        Effect: 'Allow',
        Action: ['sqs:ReceiveMessage', 'sqs:DeleteMessage', 'sqs:GetQueueAttributes'],
        Resource: [cfn.getAtt('OrderQueue', 'Arn')],
      },
      {
        Effect: 'Allow',
        Action: ['dynamodb:PutItem'],
        Resource: cfn.sub('arn:aws:dynamodb:${AWS::Region}:${AWS::AccountId}:table/orders-' + stage),
      },
    ],
  }],
  Events: {
    OrderEvent: {
      Type: 'SQS',
      Properties: {
        Queue: cfn.getAtt('OrderQueue', 'Arn'),
        BatchSize: 10,
      },
    },
  },
}, service=service, stage=stage);

// ── Assemble ─────────────────────────────────────────────────────────────────
{
  AWSTemplateFormatVersion: '2010-09-09',
  Resources:
    cfn.deploymentBucket
    + cfn.iamRole(service, stage, processor.extraStatements)
    + processor.resources
    + cfn.sqsQueue('OrderDLQ', tags=tags)
    + cfn.sqsQueue('OrderQueue',
      visibilityTimeout=180,
      dlqArn=cfn.getAtt('OrderDLQ', 'Arn'),
      maxReceiveCount=3,
      tags=tags,
    ),
  Outputs: {
    QueueUrl: cfn.output(cfn.ref('OrderQueue')),
    DLQUrl:   cfn.output(cfn.ref('OrderDLQ')),
  },
}
