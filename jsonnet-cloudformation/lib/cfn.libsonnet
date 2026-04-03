// cfn.libsonnet — Jsonnet helpers that generate raw CloudFormation JSON.
//
// These helpers recreate what the Serverless Framework (and SAM transform)
// auto-generate from high-level declarations. Each function returns a flat
// object of CFN resources that you merge with `+`.
//
// Usage:
//   local cfn = import 'lib/cfn.libsonnet';
//   {
//     AWSTemplateFormatVersion: '2010-09-09',
//     Resources:
//       cfn.deploymentBucket
//       + cfn.iamRole('my-service-dev', [...])
//       + cfn.lambdaFn(logicalName='Handler', ...)
//   }

{
  // ── Intrinsic function shorthands ─────────────────────────────────────────
  getAtt(logical, attr):: { 'Fn::GetAtt': [logical, attr] },
  sub(str):: { 'Fn::Sub': str },
  ref(logical):: { Ref: logical },

  // ── IAM policy shorthands ──────────────────────────────────────────────────
  allow(actions, resource, condition=null)::
    { Effect: 'Allow', Action: actions, Resource: resource }
    + (if condition != null then { Condition: condition } else {}),

  deny(actions, resource, condition=null)::
    { Effect: 'Deny', Action: actions, Resource: resource }
    + (if condition != null then { Condition: condition } else {}),

  policies(statements):: [{ Version: '2012-10-17', Statement: statements }],

  // ── Parameter shorthands ───────────────────────────────────────────────────
  param(type='String', default=null, description=null, allowed=null)::
    { Type: type }
    + (if default != null then { Default: default } else {})
    + (if description != null then { Description: description } else {})
    + (if allowed != null then { AllowedValues: allowed } else {}),

  ssmParam(path, description=null)::
    { Type: 'AWS::SSM::Parameter::Value<String>', Default: path }
    + (if description != null then { Description: description } else {}),

  // ── Output shorthands ──────────────────────────────────────────────────────
  output(value):: { Value: value },
  exportOutput(value, name):: { Value: value, Export: { Name: name } },

  // ── Tags ───────────────────────────────────────────────────────────────────
  // Convert { Key: Value } object to CFN Tags array format.
  tags(obj):: [{ Key: k, Value: obj[k] } for k in std.objectFields(obj)],


  // ── Deployment Bucket ──────────────────────────────────────────────────────
  // S3 bucket + HTTPS-only policy. Present in every SLS-generated template.
  deploymentBucket:: {
    ServerlessDeploymentBucket: {
      Type: 'AWS::S3::Bucket',
      Properties: {
        BucketEncryption: {
          ServerSideEncryptionConfiguration: [{
            ServerSideEncryptionByDefault: { SSEAlgorithm: 'AES256' },
          }],
        },
      },
    },
    ServerlessDeploymentBucketPolicy: {
      Type: 'AWS::S3::BucketPolicy',
      Properties: {
        Bucket: { Ref: 'ServerlessDeploymentBucket' },
        PolicyDocument: {
          Statement: [{
            Action: 's3:*',
            Effect: 'Deny',
            Principal: '*',
            Resource: [
              { 'Fn::Join': ['', ['arn:', { Ref: 'AWS::Partition' }, ':s3:::', { Ref: 'ServerlessDeploymentBucket' }, '/*']] },
              { 'Fn::Join': ['', ['arn:', { Ref: 'AWS::Partition' }, ':s3:::', { Ref: 'ServerlessDeploymentBucket' }]] },
            ],
            Condition: { Bool: { 'aws:SecureTransport': false } },
          }],
        },
      },
    },
  },


  // ── IAM Execution Role ─────────────────────────────────────────────────────
  // Shared by all Lambda functions in a service. Base log permissions are
  // always included; pass extra statements for service-specific access.
  iamRole(namePrefix, extraStatements=[], managedPolicies=[]):: {
    IamRoleLambdaExecution: {
      Type: 'AWS::IAM::Role',
      Properties: {
        AssumeRolePolicyDocument: {
          Version: '2012-10-17',
          Statement: [{
            Effect: 'Allow',
            Principal: { Service: ['lambda.amazonaws.com'] },
            Action: ['sts:AssumeRole'],
          }],
        },
        Policies: [{
          PolicyName: namePrefix + '-lambda',
          PolicyDocument: {
            Version: '2012-10-17',
            Statement: [
              {
                Effect: 'Allow',
                Action: ['logs:CreateLogStream', 'logs:CreateLogGroup', 'logs:TagResource'],
                Resource: [{ 'Fn::Sub': 'arn:${AWS::Partition}:logs:${AWS::Region}:${AWS::AccountId}:log-group:/aws/lambda/' + namePrefix + '*:*' }],
              },
              {
                Effect: 'Allow',
                Action: ['logs:PutLogEvents'],
                Resource: [{ 'Fn::Sub': 'arn:${AWS::Partition}:logs:${AWS::Region}:${AWS::AccountId}:log-group:/aws/lambda/' + namePrefix + '*:*:*' }],
              },
            ] + extraStatements,
          },
        }],
        Path: '/',
        RoleName: { 'Fn::Join': ['-', [namePrefix, { Ref: 'AWS::Region' }, 'lambdaRole']] },
      } + (if managedPolicies != [] then { ManagedPolicyArns: managedPolicies } else {}),
    },
  },


  // ── Lambda Function ────────────────────────────────────────────────────────
  // Expands to: LogGroup + Lambda::Function + Lambda::Version.
  // Optionally: Logs::SubscriptionFilter (when logDestination is set).
  //
  // This is the core abstraction. In serverless.yml each `functions:` entry
  // became exactly these resources. In SAM, AWS::Serverless::Function
  // expands to the same set.
  lambdaFn(
    logicalName,
    functionName,
    handler,
    s3Key,
    codeSha256='',
    runtime='python3.12',
    memory=128,
    timeout=300,
    role='IamRoleLambdaExecution',
    env={},
    tags=[],
    vpcConfig=null,
    reservedConcurrency=null,
    s3Bucket=null,
    logDestination=null,
  )::
    local lg  = logicalName + 'LogGroup';
    local fn  = logicalName + 'LambdaFunction';
    local ver = logicalName + 'LambdaVersion';
    local sub = logicalName + 'LogSubscriptionFilter';
    local bucket = if s3Bucket != null then s3Bucket else { Ref: 'ServerlessDeploymentBucket' };
    {
      [lg]: {
        Type: 'AWS::Logs::LogGroup',
        Properties: { LogGroupName: '/aws/lambda/' + functionName },
      },
      [fn]: {
        Type: 'AWS::Lambda::Function',
        Properties: {
          Code: { S3Bucket: bucket, S3Key: s3Key },
          FunctionName: functionName,
          Handler: handler,
          Runtime: runtime,
          MemorySize: memory,
          Timeout: timeout,
          Role: { 'Fn::GetAtt': [role, 'Arn'] },
        }
        + (if env != {} then { Environment: { Variables: env } } else {})
        + (if tags != [] then { Tags: tags } else {})
        + (if vpcConfig != null then { VpcConfig: vpcConfig } else {})
        + (if reservedConcurrency != null then { ReservedConcurrentExecutions: reservedConcurrency } else {}),
        DependsOn: [lg],
      },
      [ver]: {
        Type: 'AWS::Lambda::Version',
        DeletionPolicy: 'Retain',
        Properties: {
          FunctionName: { Ref: fn },
          CodeSha256: codeSha256,
        },
      },
    }
    + (if logDestination != null then {
      [sub]: {
        Type: 'AWS::Logs::SubscriptionFilter',
        DependsOn: [lg],
        Properties: {
          LogGroupName: '/aws/lambda/' + functionName,
          FilterPattern: '',
          DestinationArn: logDestination,
        },
      },
    } else {}),


  // ── Schedule Event ─────────────────────────────────────────────────────────
  // CloudWatch Events rule + Lambda permission.
  // In SLS: events: - schedule: ...
  // In SAM: Events: MySchedule: { Type: Schedule, ... }
  scheduleEvent(logicalName, schedule, enabled=true, ruleName=null)::
    local fn   = logicalName + 'LambdaFunction';
    local rule = logicalName + 'EventsRuleSchedule1';
    local perm = logicalName + 'LambdaPermissionEventsRuleSchedule1';
    {
      [rule]: {
        Type: 'AWS::Events::Rule',
        Properties: {
          ScheduleExpression: schedule,
          State: if enabled then 'ENABLED' else 'DISABLED',
          Targets: [{
            Arn: { 'Fn::GetAtt': [fn, 'Arn'] },
            Id: logicalName + 'Schedule',
          }],
        } + (if ruleName != null then { Name: ruleName } else {}),
      },
      [perm]: {
        Type: 'AWS::Lambda::Permission',
        Properties: {
          FunctionName: { 'Fn::GetAtt': [fn, 'Arn'] },
          Action: 'lambda:InvokeFunction',
          Principal: 'events.amazonaws.com',
          SourceArn: { 'Fn::GetAtt': [rule, 'Arn'] },
        },
      },
    },


  // ── SQS Queue ──────────────────────────────────────────────────────────────
  sqsQueue(logicalName, visibilityTimeout=30, dlqArn=null, maxReceiveCount=3, tags=[]):: {
    [logicalName]: {
      Type: 'AWS::SQS::Queue',
      Properties: {
        VisibilityTimeout: visibilityTimeout,
      }
      + (if dlqArn != null then {
        RedrivePolicy: { deadLetterTargetArn: dlqArn, maxReceiveCount: maxReceiveCount },
      } else {})
      + (if tags != [] then { Tags: tags } else {}),
    },
  },


  // ── SQS Event Source ───────────────────────────────────────────────────────
  // In SLS: events: - sqs: ...
  // In SAM: Events: MySqs: { Type: SQS, ... }
  sqsEventSource(logicalName, functionLogical, queueLogical, batchSize=10):: {
    [logicalName]: {
      Type: 'AWS::Lambda::EventSourceMapping',
      DependsOn: 'IamRoleLambdaExecution',
      Properties: {
        BatchSize: batchSize,
        EventSourceArn: { 'Fn::GetAtt': [queueLogical, 'Arn'] },
        FunctionName: { 'Fn::GetAtt': [functionLogical, 'Arn'] },
        Enabled: 'True',
      },
    },
  },


  // ── REST API (API Gateway v1) ──────────────────────────────────────────────

  restApi(name, endpointType='EDGE'):: {
    ApiGatewayRestApi: {
      Type: 'AWS::ApiGateway::RestApi',
      Properties: {
        Name: name,
        EndpointConfiguration: { Types: [endpointType] },
      },
    },
  },

  apiResource(logicalName, parentId, pathPart):: {
    [logicalName]: {
      Type: 'AWS::ApiGateway::Resource',
      Properties: {
        ParentId: parentId,
        PathPart: pathPart,
        RestApiId: { Ref: 'ApiGatewayRestApi' },
      },
    },
  },

  apiMethod(logicalName, resourceLogical, httpMethod, functionLogical, apiKeyRequired=false, authorizationType='NONE'):: {
    [logicalName]: {
      Type: 'AWS::ApiGateway::Method',
      Properties: {
        HttpMethod: httpMethod,
        ResourceId: { Ref: resourceLogical },
        RestApiId: { Ref: 'ApiGatewayRestApi' },
        ApiKeyRequired: apiKeyRequired,
        AuthorizationType: authorizationType,
        RequestParameters: {},
        MethodResponses: [],
        Integration: {
          IntegrationHttpMethod: 'POST',
          Type: 'AWS_PROXY',
          Uri: {
            'Fn::Join': ['', [
              'arn:', { Ref: 'AWS::Partition' },
              ':apigateway:', { Ref: 'AWS::Region' },
              ':lambda:path/2015-03-31/functions/',
              { 'Fn::GetAtt': [functionLogical, 'Arn'] },
              '/invocations',
            ]],
          },
        },
      },
    },
  },

  corsOptions(logicalName, resourceLogical, allowedMethods)::
    local methodsHeader = "'" + std.join(',', ['OPTIONS'] + allowedMethods) + "'";
    {
      [logicalName]: {
        Type: 'AWS::ApiGateway::Method',
        Properties: {
          AuthorizationType: 'NONE',
          HttpMethod: 'OPTIONS',
          RequestParameters: {},
          ResourceId: { Ref: resourceLogical },
          RestApiId: { Ref: 'ApiGatewayRestApi' },
          Integration: {
            Type: 'MOCK',
            RequestTemplates: { 'application/json': '{statusCode:200}' },
            ContentHandling: 'CONVERT_TO_TEXT',
            IntegrationResponses: [{
              StatusCode: '200',
              ResponseParameters: {
                'method.response.header.Access-Control-Allow-Origin': "'*'",
                'method.response.header.Access-Control-Allow-Headers': "'Content-Type,X-Amz-Date,Authorization,X-Api-Key,X-Amz-Security-Token,X-Amz-User-Agent'",
                'method.response.header.Access-Control-Allow-Methods': methodsHeader,
              },
              ResponseTemplates: { 'application/json': '' },
            }],
          },
          MethodResponses: [{
            StatusCode: '200',
            ResponseParameters: {
              'method.response.header.Access-Control-Allow-Origin': true,
              'method.response.header.Access-Control-Allow-Headers': true,
              'method.response.header.Access-Control-Allow-Methods': true,
            },
            ResponseModels: {},
          }],
        },
      },
    },

  apiLambdaPermission(logicalName, functionLogical):: {
    [logicalName]: {
      Type: 'AWS::Lambda::Permission',
      Properties: {
        FunctionName: { 'Fn::GetAtt': [functionLogical, 'Arn'] },
        Action: 'lambda:InvokeFunction',
        Principal: 'apigateway.amazonaws.com',
        SourceArn: {
          'Fn::Join': ['', [
            'arn:', { Ref: 'AWS::Partition' },
            ':execute-api:', { Ref: 'AWS::Region' }, ':',
            { Ref: 'AWS::AccountId' }, ':',
            { Ref: 'ApiGatewayRestApi' }, '/*/*',
          ]],
        },
      },
    },
  },

  apiDeployment(logicalName, stageName, dependsOn=[]):: {
    [logicalName]: {
      Type: 'AWS::ApiGateway::Deployment',
      Properties: {
        RestApiId: { Ref: 'ApiGatewayRestApi' },
        StageName: stageName,
      },
      DependsOn: dependsOn,
    },
  },


  // ── HTTP API (API Gateway v2) ──────────────────────────────────────────────

  httpApi(name):: {
    HttpApi: {
      Type: 'AWS::ApiGatewayV2::Api',
      Properties: { Name: name, ProtocolType: 'HTTP' },
    },
    HttpApiStage: {
      Type: 'AWS::ApiGatewayV2::Stage',
      Properties: {
        ApiId: { Ref: 'HttpApi' },
        StageName: '$default',
        AutoDeploy: true,
        DefaultRouteSettings: { DetailedMetricsEnabled: false },
      },
    },
  },

  httpApiJwtAuthorizer(logicalName, name, issuer, audience):: {
    [logicalName]: {
      Type: 'AWS::ApiGatewayV2::Authorizer',
      Properties: {
        ApiId: { Ref: 'HttpApi' },
        Name: name,
        IdentitySource: ['$request.header.Authorization'],
        AuthorizerType: 'JWT',
        JwtConfiguration: { Audience: audience, Issuer: issuer },
      },
    },
  },

  httpApiFn(logicalName, functionLogical, routes)::
    local integrationLogical = 'HttpApiIntegration' + logicalName;
    local permissionLogical  = functionLogical + 'PermissionHttpApi';
    {
      [integrationLogical]: {
        Type: 'AWS::ApiGatewayV2::Integration',
        Properties: {
          ApiId: { Ref: 'HttpApi' },
          IntegrationType: 'AWS_PROXY',
          IntegrationUri: { 'Fn::GetAtt': [functionLogical, 'Arn'] },
          PayloadFormatVersion: '2.0',
          TimeoutInMillis: 30000,
        },
      },
    }
    + std.foldl(
      function(acc, r) acc + {
        [r.logical]: {
          Type: 'AWS::ApiGatewayV2::Route',
          Properties: {
            ApiId: { Ref: 'HttpApi' },
            RouteKey: r.routeKey,
            Target: { 'Fn::Join': ['/', ['integrations', { Ref: integrationLogical }]] },
          }
          + (if std.objectHas(r, 'authorizerId') && r.authorizerId != null then {
            AuthorizationType: 'JWT',
            AuthorizerId: r.authorizerId,
          } else {}),
          DependsOn: integrationLogical,
        },
      },
      routes,
      {}
    )
    + {
      [permissionLogical]: {
        Type: 'AWS::Lambda::Permission',
        Properties: {
          FunctionName: { 'Fn::GetAtt': [functionLogical, 'Arn'] },
          Action: 'lambda:InvokeFunction',
          Principal: 'apigateway.amazonaws.com',
          SourceArn: {
            'Fn::Join': ['', [
              'arn:', { Ref: 'AWS::Partition' },
              ':execute-api:', { Ref: 'AWS::Region' }, ':',
              { Ref: 'AWS::AccountId' }, ':',
              { Ref: 'HttpApi' }, '/*',
            ]],
          },
        },
      },
    },
}
