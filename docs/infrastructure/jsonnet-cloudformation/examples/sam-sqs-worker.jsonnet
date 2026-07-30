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

local actions = import '../lib/cfn-actions.libsonnet';
local cfn = import '../lib/cfn.libsonnet';
local sam = import '../lib/sam.libsonnet';
local sls = import '../lib/sls.libsonnet';

local service = 'order-processor';
local stage = std.extVar('stage');
local tags = cfn.tags({ Service: service, Stage: stage });

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
  Policies: cfn.policies([
    cfn.allow(actions.sqsConsume, [cfn.getAtt('OrderQueue', 'Arn')]),
    cfn.allow(actions.ddbWrite, cfn.arn('dynamodb', 'table/orders-' + stage)),
  ]),
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
    sls.deploymentBucketG
    + sls.iamRoleG(service + '-' + stage, processor.extraStatements)
    + processor.resources
    + {
      OrderDLQ: sls.sqsQueue(tags=tags),
      OrderQueue: sls.sqsQueue(
        visibilityTimeout=180,
        dlqArn=cfn.getAtt('OrderDLQ', 'Arn'),
        maxReceiveCount=3,
        tags=tags,
      ),
    },
  Outputs: {
    QueueUrl: cfn.output(cfn.ref('OrderQueue')),
    DLQUrl: cfn.output(cfn.ref('OrderDLQ')),
  },
}
