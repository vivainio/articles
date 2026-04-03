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
local sls = import '../lib/sls.libsonnet';
local actions = import '../lib/cfn-actions.libsonnet';

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
    sls.deploymentBucketG
    + sls.iamRoleG(service + '-dev', [
      cfn.allow(actions.s3Read + actions.s3Write, cfn.sub('arn:aws:s3:::${Stage}-data-bucket/*')),
    ], managedPolicies=[
      'arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole',
    ])
    + sls.lambdaFnG('Processor', {
      FunctionName: service + '-processor',
      Handler: 'src/processor.handler',
      Code: { S3Key: 'serverless/' + service + '/package.zip' },
      Runtime: 'python3.12',
      MemorySize: 1024,
      Timeout: 300,
      Environment: { Variables: {
        DB_PASSWORD: cfn.ref('DbPassword'),
        STAGE: cfn.ref('Stage'),
        BUCKET: cfn.sub('${Stage}-data-bucket'),
      } },
      VpcConfig: {
        SecurityGroupIds: [cfn.ref('LambdaSG')],
        SubnetIds: cfn.ref('SubnetIds'),
      },
    })
    + sls.scheduleEventG('Processor', 'rate(1 hour)')
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
