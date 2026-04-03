// Example 1: Scheduled Lambda worker
//
// A single Lambda function triggered by a CloudWatch cron schedule.
// This is the simplest serverless pattern — a periodic background job.
//
// The equivalent serverless.yml would be:
//
//   service: snapshot-cleanup
//   provider:
//     name: aws
//     runtime: python3.12
//     stage: dev
//     iamRoleStatements:
//       - Effect: Allow
//         Action: [ec2:DescribeSnapshots, ec2:DeleteSnapshot]
//         Resource: "*"
//   functions:
//     worker:
//       handler: handler.cleanup
//       memorySize: 512
//       timeout: 600
//       events:
//         - schedule:
//             rate: cron(0 3 * * ? *)
//             enabled: true

local cfn = import '../lib/cfn.libsonnet';
local sls = import '../lib/sls.libsonnet';

local service = 'snapshot-cleanup';
local stage = std.extVar('stage');
local tags = cfn.tags({ Service: service, Stage: stage });

{
  AWSTemplateFormatVersion: '2010-09-09',

  Resources:
    sls.deploymentBucketG
    + sls.iamRoleG(service + '-' + stage, [
      cfn.allow(['ec2:DescribeSnapshots', 'ec2:DeleteSnapshot'], '*'),
    ])
    + sls.lambdaFnG('Worker', {
      FunctionName: service + '-' + stage + '-worker',
      Handler: 'handler.cleanup',
      Code: { S3Key: 'serverless/' + service + '/' + stage + '/package.zip' },
      Runtime: 'python3.12',
      MemorySize: 512,
      Timeout: 600,
      Tags: tags,
    })
    + sls.scheduleEventG('Worker', 'cron(0 3 * * ? *)', enabled=true),

  Outputs: {
    WorkerFunctionArn: cfn.output(cfn.getAtt('WorkerLambdaFunction', 'Arn')),
  },
}
