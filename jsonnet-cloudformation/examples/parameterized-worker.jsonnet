// Example 8: Parameterized worker with CloudFormation input parameters
//
// Demonstrates cfn.param() and cfn.ssmParam() for stacks that accept
// configuration at deploy time — useful when the same template is deployed
// across accounts or environments with different VPCs, secrets, or settings.
//
// Deploy with:
//   aws cloudformation deploy \
//     --template-file template.json \
//     --stack-name data-processor-dev \
//     --parameter-overrides Stage=dev VpcId=vpc-0abc1234 \
//     --capabilities CAPABILITY_NAMED_IAM

local cfn = import '../lib/cfn.libsonnet';

local service = 'data-processor';

{
  AWSTemplateFormatVersion: '2010-09-09',

  Parameters: {
    Stage: cfn.param(
      default='dev',
      allowed=['dev', 'staging', 'prod'],
      description='Deployment stage',
    ),
    VpcId: cfn.param(
      type='AWS::EC2::VPC::Id',
      description='VPC to deploy into',
    ),
    SubnetIds: cfn.param(
      type='List<AWS::EC2::Subnet::Id>',
      description='Subnets for Lambda VPC config',
    ),
    DbPassword: cfn.ssmParam(
      '/data-processor/db-password',
      description='Database password from SSM Parameter Store',
    ),
    NotificationEmail: cfn.param(
      description='Email for alarm notifications',
    ),
  },

  Resources:
    cfn.deploymentBucket
    + cfn.iamRole(service, cfn.ref('Stage'), [
      {
        Effect: 'Allow',
        Action: ['s3:GetObject', 's3:PutObject'],
        Resource: cfn.sub('arn:aws:s3:::${Stage}-data-bucket/*'),
      },
    ], managedPolicies=[
      'arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole',
    ])
    + cfn.lambdaFn(
      logicalName='Processor',
      functionName=service + '-processor',
      handler='src/processor.handler',
      s3Key='serverless/' + service + '/package.zip',
      runtime='python3.12',
      memory=1024,
      timeout=300,
      env={
        DB_PASSWORD: cfn.ref('DbPassword'),
        STAGE: cfn.ref('Stage'),
        BUCKET: cfn.sub('${Stage}-data-bucket'),
      },
      vpcConfig={
        SecurityGroupIds: [cfn.ref('LambdaSG')],
        SubnetIds: cfn.ref('SubnetIds'),
      },
    )
    + cfn.scheduleEvent('Processor', 'rate(1 hour)')
    + {
      // Security group — pass-through as raw Jsonnet
      LambdaSG: {
        Type: 'AWS::EC2::SecurityGroup',
        Properties: {
          GroupDescription: service + ' Lambda security group',
          VpcId: cfn.ref('VpcId'),
        },
      },
    },

  Outputs: {
    FunctionArn: cfn.output(cfn.getAtt('ProcessorLambdaFunction', 'Arn')),
    SecurityGroup: cfn.exportOutput(
      cfn.ref('LambdaSG'),
      cfn.sub('${Stage}-data-processor-sg'),
    ),
  },
}
