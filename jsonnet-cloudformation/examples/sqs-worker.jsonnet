// Example 3: SQS consumer with dead-letter queue
//
// A Lambda function triggered by an SQS queue, with a DLQ for failed messages
// and ReservedConcurrentExecutions to limit parallelism.
//
// The equivalent serverless.yml would be:
//
//   service: order-processor
//   provider:
//     name: aws
//     runtime: nodejs20.x
//     stage: dev
//     iamRoleStatements:
//       - Effect: Allow
//         Action: [sqs:ReceiveMessage, sqs:DeleteMessage, sqs:GetQueueAttributes]
//         Resource: !GetAtt OrderQueue.Arn
//       - Effect: Allow
//         Action: [dynamodb:PutItem]
//         Resource: !Sub "arn:aws:dynamodb:${AWS::Region}:${AWS::AccountId}:table/orders-${self:provider.stage}"
//   functions:
//     processor:
//       handler: src/processor.handler
//       reservedConcurrency: 5
//       events:
//         - sqs:
//             arn: !GetAtt OrderQueue.Arn
//             batchSize: 10
//   resources:
//     Resources:
//       OrderDLQ: ...
//       OrderQueue: ...

local cfn = import '../lib/cfn.libsonnet';
local sls = import '../lib/sls.libsonnet';
local actions = import '../lib/cfn-actions.libsonnet';

local service = 'order-processor';
local stage   = std.extVar('stage');

local tags = cfn.tags({
  Service: service,
  Stage: stage,
});

{
  AWSTemplateFormatVersion: '2010-09-09',

  Resources:
    sls.deploymentBucketG
    + sls.iamRoleG(service + '-' + stage, [
      cfn.allow(actions.sqsConsume, [cfn.getAtt('OrderQueue', 'Arn')]),
      cfn.allow(actions.ddbWrite, cfn.sub('arn:aws:dynamodb:${AWS::Region}:${AWS::AccountId}:table/orders-' + stage)),
    ])

    // Lambda consumer — limited to 5 concurrent executions
    + sls.lambdaFnG('Processor', {
      FunctionName: service + '-' + stage + '-processor',
      Handler: 'src/processor.handler',
      Code: { S3Key: 'serverless/' + service + '/' + stage + '/package.zip' },
      Runtime: 'nodejs20.x',
      MemorySize: 256,
      Timeout: 30,
      Environment: { Variables: { STAGE: stage, TABLE_NAME: 'orders-' + stage } },
      Tags: tags,
      ReservedConcurrentExecutions: 5,
    })

    + {
      // SQS event source mapping (from `events: - sqs:`)
      ProcessorEventSourceMapping: sls.sqsEventSource('ProcessorLambdaFunction', 'OrderQueue', batchSize=10),

      // Dead-letter queue
      OrderDLQ: sls.sqsQueue(tags=tags),

      // Main queue with redrive policy
      OrderQueue: sls.sqsQueue(
        visibilityTimeout=180,
        dlqArn=cfn.getAtt('OrderDLQ', 'Arn'),
        maxReceiveCount=3,
        tags=tags,
      ),
    },

  Outputs: {
    QueueUrl: cfn.output(cfn.ref('OrderQueue')),
    DLQUrl:   cfn.output(cfn.ref('OrderDLQ')),
  },
}
