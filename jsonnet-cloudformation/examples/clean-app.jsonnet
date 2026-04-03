// Clean-room example: Lambda + DynamoDB + S3 bucket
//
// Uses aws.libsonnet — no Serverless Framework conventions, no fixed
// logical IDs, no deployment bucket. Every resource name is explicit.

local cfn = import '../lib/cfn.libsonnet';
local aws = import '../lib/aws.libsonnet';
local actions = import '../lib/cfn-actions.libsonnet';

local service = 'my-app';
local stage = std.extVar('stage');
local table = service + '-' + stage;
local bucket = service + '-' + stage + '-data';

{
  AWSTemplateFormatVersion: '2010-09-09',

  Resources:
    aws.lambdaG('App', {
      FunctionName: service + '-' + stage + '-app',
      Handler: 'app.handler',
      Code: { S3Bucket: 'deploy-artifacts', S3Key: service + '/' + stage + '/package.zip' },
      Role: cfn.getArn('AppRole'),
      Environment: { Variables: { TABLE: table, BUCKET: bucket } },
    })
    + {
      AppRole: aws.lambdaRole(service + '-' + stage, [
        cfn.allow(actions.ddbAll, cfn.arn('dynamodb', 'table/' + table)),
        cfn.allow(actions.s3Read + actions.s3Write, 'arn:aws:s3:::' + bucket + '/*'),
        cfn.allow(actions.s3List, 'arn:aws:s3:::' + bucket),
      ]),
      DataTable: aws.table(table, 'id'),
      DataBucket: aws.bucket(bucket),
      TableNameParam: cfn.ssmOutput('/' + service + '/' + stage + '/table-name', cfn.ref('DataTable')),
      BucketNameParam: cfn.ssmOutput('/' + service + '/' + stage + '/bucket-name', cfn.ref('DataBucket')),
    },

  Outputs: {
    FunctionArn: cfn.output(cfn.getArn('AppFunction')),
    TableName: cfn.output(cfn.ref('DataTable')),
    BucketName: cfn.output(cfn.ref('DataBucket')),
  },
}
