// Clean-room example: Lambda + DynamoDB + S3 + HTTP API with JWT
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
local partner = cfn.ref('PartnerAccountId');
local logDest = cfn.ref('LogDestinationArn');

local myApp = aws.lambda('MyApp', {
  FunctionName: service + '-' + stage + '-app',
  Handler: 'app.handler',
  Code: { S3Bucket: 'deploy-artifacts', S3Key: service + '/' + stage + '/package.zip' },
  Role: cfn.getArn('MyAppRole'),
  Environment: { Variables: { TABLE: table, BUCKET: bucket } },
});

{
  AWSTemplateFormatVersion: '2010-09-09',

  Parameters: {
    PartnerAccountId: cfn.param(description='AWS account ID allowed to invoke the function'),
    LogDestinationArn: cfn.param(description='Kinesis/Firehose destination ARN for log forwarding'),
    JwtIssuer: cfn.param(description='JWT issuer URL (e.g. https://example.auth0.com/)'),
    JwtAudience: cfn.param(description='JWT audience'),
  },

  Resources:
    myApp.resources

    // HTTP API with JWT-protected catch-all + unauthenticated /login
    + aws.httpApiG('MyApi', service + '-' + stage)
    + { MyApiAuth: aws.jwtAuthorizer('MyApi', 'jwt', cfn.ref('JwtIssuer'), [cfn.ref('JwtAudience')]) }
    + myApp.routes('MyApi', {
      Default: { routeKey: '$default', authorizerId: cfn.ref('MyApiAuth') },
      LoginGet: { routeKey: 'GET /login' },
      LoginPost: { routeKey: 'POST /login' },
    })

    + {
      MyAppRole: aws.lambdaRole(service + '-' + stage, [
        cfn.allow(actions.ddbAll, cfn.arn('dynamodb', 'table/' + table)),
        cfn.allow(actions.s3Read + actions.s3Write, 'arn:aws:s3:::' + bucket + '/*'),
        cfn.allow(actions.s3List, 'arn:aws:s3:::' + bucket),
      ]),
      DataTable: aws.table(table, 'id'),
      DataBucket: aws.bucket(bucket),
      TableNameParam: cfn.ssmOutput('/' + service + '/' + stage + '/table-name', cfn.ref('DataTable')),
      BucketNameParam: cfn.ssmOutput('/' + service + '/' + stage + '/bucket-name', cfn.ref('DataBucket')),

      // Forward Lambda logs to central logging
      MyAppLogForward: aws.logSubscription('/aws/lambda/' + service + '-' + stage + '-app', logDest),

      // Cross-account role: partner can invoke Lambda and read bucket
      PartnerRole: aws.assumableRole([partner], [
        cfn.allow(actions.lambdaInvoke, cfn.getArn(myApp.fn)),
        cfn.allow(actions.s3Read, 'arn:aws:s3:::' + bucket + '/*'),
        cfn.allow(actions.s3List, 'arn:aws:s3:::' + bucket),
      ]),
    },

  Outputs: {
    ApiEndpoint: cfn.output(cfn.sub('https://${MyApi}.execute-api.${AWS::Region}.${AWS::URLSuffix}')),
    FunctionArn: cfn.output(cfn.getArn(myApp.fn)),
    TableName: cfn.output(cfn.ref('DataTable')),
    BucketName: cfn.output(cfn.ref('DataBucket')),
  },
}
