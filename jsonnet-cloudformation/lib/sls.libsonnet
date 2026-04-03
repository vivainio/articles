// sls.libsonnet — Serverless resource builders that generate raw CloudFormation.
//
// These helpers recreate what the Serverless Framework (and SAM transform)
// auto-generate from high-level declarations.
//
// Naming convention:
//   - Functions ending in G return { LogicalId: Resource, ... } objects.
//     Merge them with `+`.
//   - All other functions return a single resource value. Use as a value in
//     a { LogicalId: sls.helper(...) } object — the logical ID is visible
//     in your source, matching the CFN output.
//
//   Fixed-key G helpers (deploymentBucketG, iamRoleG, restApiG, httpApiG)
//   assume one per template, matching the SLS one-service-per-stack convention.
//
// Usage:
//   local sls = import 'lib/sls.libsonnet';
//   {
//     AWSTemplateFormatVersion: '2010-09-09',
//     Resources:
//       sls.deploymentBucketG
//       + sls.iamRoleG('my-service-dev', [...])
//       + sls.lambdaFnG('Handler', { FunctionName: '...', Handler: '...', ... })
//       + sls.scheduleEventG('Handler', 'rate(1 hour)')
//       + {
//         MyQueue: sls.sqsQueue(tags=tags),
//       },
//   }

{
  // ── Deployment Bucket ──────────────────────────────────────────────────────
  // S3 bucket + HTTPS-only policy. Present in every SLS-generated template.
  deploymentBucketG:: {
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
  iamRoleG(namePrefix, extraStatements=[], managedPolicies=[]):: {
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


  // ── Lambda Function (G = group) ──────────────────────────────────────────
  // Expands to: LogGroup + Lambda::Function + Lambda::Version.
  // Optionally: Logs::SubscriptionFilter (when logDestination is set).
  //
  // props is the AWS::Lambda::Function Properties object. Defaults applied:
  //   Runtime: python3.12, MemorySize: 128, Timeout: 300,
  //   Role: IamRoleLambdaExecution, Code.S3Bucket: ServerlessDeploymentBucket.
  lambdaFnG(logicalName, props, logDestination=null)::
    local lg  = logicalName + 'LogGroup';
    local fn  = logicalName + 'LambdaFunction';
    local ver = logicalName + 'LambdaVersion';
    local sub = logicalName + 'LogSubscriptionFilter';
    local functionName = props.FunctionName;

    // Default Code.S3Bucket if Code has S3Key but no S3Bucket
    local code =
      if std.objectHas(props, 'Code') then
        { S3Bucket: { Ref: 'ServerlessDeploymentBucket' } } + props.Code
      else {};

    local defaults = {
      Runtime: 'python3.12',
      MemorySize: 128,
      Timeout: 300,
      Role: { 'Fn::GetAtt': ['IamRoleLambdaExecution', 'Arn'] },
    };

    local merged = defaults + props + (if code != {} then { Code: code } else {});

    {
      [lg]: {
        Type: 'AWS::Logs::LogGroup',
        Properties: { LogGroupName: '/aws/lambda/' + functionName },
      },
      [fn]: {
        Type: 'AWS::Lambda::Function',
        Properties: merged,
        DependsOn: [lg],
      },
      [ver]: {
        Type: 'AWS::Lambda::Version',
        DeletionPolicy: 'Retain',
        Properties: {
          FunctionName: { Ref: fn },
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


  // ── Schedule Event (G = group) ───────────────────────────────────────────
  // CloudWatch Events rule + Lambda permission.
  scheduleEventG(logicalName, schedule, enabled=true, ruleName=null)::
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
  // Returns a single resource value. Use as: { MyQueue: sls.sqsQueue(...) }
  sqsQueue(visibilityTimeout=30, dlqArn=null, maxReceiveCount=3, tags=[]):: {
    Type: 'AWS::SQS::Queue',
    Properties: {
      VisibilityTimeout: visibilityTimeout,
    }
    + (if dlqArn != null then {
      RedrivePolicy: { deadLetterTargetArn: dlqArn, maxReceiveCount: maxReceiveCount },
    } else {})
    + (if tags != [] then { Tags: tags } else {}),
  },


  // ── SQS Event Source ───────────────────────────────────────────────────────
  // Returns a single resource value.
  sqsEventSource(functionLogical, queueLogical, batchSize=10):: {
    Type: 'AWS::Lambda::EventSourceMapping',
    DependsOn: 'IamRoleLambdaExecution',
    Properties: {
      BatchSize: batchSize,
      EventSourceArn: { 'Fn::GetAtt': [queueLogical, 'Arn'] },
      FunctionName: { 'Fn::GetAtt': [functionLogical, 'Arn'] },
      Enabled: 'True',
    },
  },


  // ── REST API (API Gateway v1) ──────────────────────────────────────────────

  restApiG(name, endpointType='EDGE'):: {
    ApiGatewayRestApi: {
      Type: 'AWS::ApiGateway::RestApi',
      Properties: {
        Name: name,
        EndpointConfiguration: { Types: [endpointType] },
      },
    },
  },

  // Returns a single resource value.
  apiResource(parentId, pathPart):: {
    Type: 'AWS::ApiGateway::Resource',
    Properties: {
      ParentId: parentId,
      PathPart: pathPart,
      RestApiId: { Ref: 'ApiGatewayRestApi' },
    },
  },

  // Returns a single resource value.
  apiMethod(resourceLogical, httpMethod, functionLogical, apiKeyRequired=false, authorizationType='NONE'):: {
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

  // Returns a single resource value.
  corsOptions(resourceLogical, allowedMethods)::
    local methodsHeader = "'" + std.join(',', ['OPTIONS'] + allowedMethods) + "'";
    {
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

  // Returns a single resource value.
  apiLambdaPermission(functionLogical):: {
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

  // Returns a single resource value.
  apiDeployment(stageName, dependsOn=[]):: {
    Type: 'AWS::ApiGateway::Deployment',
    Properties: {
      RestApiId: { Ref: 'ApiGatewayRestApi' },
      StageName: stageName,
    },
    DependsOn: dependsOn,
  },


  // ── HTTP API (API Gateway v2) ──────────────────────────────────────────────

  httpApiG(name):: {
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

  // Returns a single resource value.
  httpApiJwtAuthorizer(name, issuer, audience):: {
    Type: 'AWS::ApiGatewayV2::Authorizer',
    Properties: {
      ApiId: { Ref: 'HttpApi' },
      Name: name,
      IdentitySource: ['$request.header.Authorization'],
      AuthorizerType: 'JWT',
      JwtConfiguration: { Audience: audience, Issuer: issuer },
    },
  },

  // HTTP API integration + routes + permission (G = group).
  httpApiFnG(logicalName, functionLogical, routes)::
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
