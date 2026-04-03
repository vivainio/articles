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

local service = 'snapshot-cleanup';
local stage   = std.extVar('stage');
local tags = cfn.tags({ Service: service, Stage: stage });

{
  AWSTemplateFormatVersion: '2010-09-09',

  Resources:
    cfn.deploymentBucket
    + cfn.iamRole(service + '-' + stage, [
      cfn.allow(['ec2:DescribeSnapshots', 'ec2:DeleteSnapshot'], '*'),
    ])
    + cfn.lambdaFn(
      logicalName='Worker',
      functionName=service + '-' + stage + '-worker',
      handler='handler.cleanup',
      s3Key='serverless/' + service + '/' + stage + '/package.zip',
      runtime='python3.12',
      memory=512,
      timeout=600,
      tags=tags,
    )
    + cfn.scheduleEvent('Worker', 'cron(0 3 * * ? *)', enabled=true),

  Outputs: {
    WorkerFunctionArn: cfn.output(cfn.getAtt('WorkerLambdaFunction', 'Arn')),
  },
}
