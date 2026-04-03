// aws.libsonnet — Clean-room CloudFormation helpers with no SLS/SAM baggage.
//
// No fixed logical IDs, no deployment bucket, no naming conventions.
// The user picks every key. G = returns object for + merging.
//
// Usage:
//   local cfn = import 'lib/cfn.libsonnet';
//   local aws = import 'lib/aws.libsonnet';
//
//   {
//     Resources:
//       aws.lambdaG('App', {
//         FunctionName: 'my-fn',
//         Handler: 'app.handler',
//         Code: { S3Bucket: 'my-bucket', S3Key: 'pkg.zip' },
//         Role: cfn.getAtt('AppRole', 'Arn'),
//       })
//       + {
//         AppRole: aws.lambdaRole('my-fn', [
//           cfn.allow(['dynamodb:GetItem'], cfn.arn('dynamodb', 'table/t')),
//         ]),
//       },
//   }

local cfn = import 'cfn.libsonnet';

{
  // ── Lambda triplet (G) ───────────────────────────────────────────────────
  // Expands to: {prefix}LogGroup + {prefix}Function + {prefix}Version.
  //
  // props is the AWS::Lambda::Function Properties object.
  // Required: FunctionName, Handler, Code, Role.
  // Defaults: Runtime python3.12, MemorySize 128, Timeout 300.
  lambdaG(prefix, props)::
    local functionName = props.FunctionName;
    local defaults = {
      Runtime: 'python3.12',
      MemorySize: 128,
      Timeout: 300,
    };
    {
      [prefix + 'LogGroup']: {
        Type: 'AWS::Logs::LogGroup',
        Properties: { LogGroupName: '/aws/lambda/' + functionName },
      },
      [prefix + 'Function']: {
        Type: 'AWS::Lambda::Function',
        Properties: defaults + props,
        DependsOn: [prefix + 'LogGroup'],
      },
      [prefix + 'Version']: {
        Type: 'AWS::Lambda::Version',
        DeletionPolicy: 'Retain',
        Properties: { FunctionName: { Ref: prefix + 'Function' } },
      },
    },


  // ── Lambda execution role ────────────────────────────────────────────────
  // Returns a single IAM::Role value with Lambda trust policy and
  // CloudWatch Logs permissions scoped to the given function name prefix.
  // Pass additional statements for service-specific access.
  lambdaRole(logPrefix, statements=[], managedPolicies=[]):: {
    Type: 'AWS::IAM::Role',
    Properties: {
      AssumeRolePolicyDocument: {
        Version: '2012-10-17',
        Statement: [{
          Effect: 'Allow',
          Principal: { Service: 'lambda.amazonaws.com' },
          Action: 'sts:AssumeRole',
        }],
      },
      Policies: [{
        PolicyName: 'policy',
        PolicyDocument: {
          Version: '2012-10-17',
          Statement: [
            cfn.allow(
              ['logs:CreateLogStream', 'logs:CreateLogGroup', 'logs:TagResource'],
              cfn.arn('logs', 'log-group:/aws/lambda/' + logPrefix + '*:*'),
            ),
            cfn.allow(
              ['logs:PutLogEvents'],
              cfn.arn('logs', 'log-group:/aws/lambda/' + logPrefix + '*:*:*'),
            ),
          ] + statements,
        },
      }],
    } + (if managedPolicies != [] then { ManagedPolicyArns: managedPolicies } else {}),
  },


  // ── DynamoDB table (on-demand) ─────────────────────────────────────────
  // Returns a single resource value. PAY_PER_REQUEST, key type defaults to S.
  //   DataTable: aws.table('my-table', 'id')
  //   DataTable: aws.table('my-table', 'pk', 'sk')
  table(name, hashKey, rangeKey=null, hashType='S', rangeType='S')::
    local hashAttr = { AttributeName: hashKey, AttributeType: hashType };
    local rangeAttr = { AttributeName: rangeKey, AttributeType: rangeType };
    {
      Type: 'AWS::DynamoDB::Table',
      Properties: {
        TableName: name,
        BillingMode: 'PAY_PER_REQUEST',
        AttributeDefinitions:
          [hashAttr] + (if rangeKey != null then [rangeAttr] else []),
        KeySchema:
          [{ AttributeName: hashKey, KeyType: 'HASH' }]
          + (if rangeKey != null then [{ AttributeName: rangeKey, KeyType: 'RANGE' }] else []),
      },
    },


  // ── S3 bucket ────────────────────────────────────────────────────────────
  // Returns a single resource value. AES256 encryption by default.
  //   DataBucket: aws.bucket('my-bucket')
  bucket(name):: {
    Type: 'AWS::S3::Bucket',
    Properties: {
      BucketName: name,
      BucketEncryption: {
        ServerSideEncryptionConfiguration: [{
          ServerSideEncryptionByDefault: { SSEAlgorithm: 'AES256' },
        }],
      },
    },
  },


  // ── Schedule event (G) ───────────────────────────────────────────────────
  // Expands to: {prefix}Rule + {prefix}Permission.
  scheduleG(prefix, functionLogical, schedule, enabled=true):: {
    [prefix + 'Rule']: {
      Type: 'AWS::Events::Rule',
      Properties: {
        ScheduleExpression: schedule,
        State: if enabled then 'ENABLED' else 'DISABLED',
        Targets: [{
          Arn: cfn.getAtt(functionLogical, 'Arn'),
          Id: prefix + 'Target',
        }],
      },
    },
    [prefix + 'Permission']: {
      Type: 'AWS::Lambda::Permission',
      Properties: {
        FunctionName: cfn.getAtt(functionLogical, 'Arn'),
        Action: 'lambda:InvokeFunction',
        Principal: 'events.amazonaws.com',
        SourceArn: cfn.getAtt(prefix + 'Rule', 'Arn'),
      },
    },
  },
}
