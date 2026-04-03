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
  lambdaG(prefix, props):: $.lambda(prefix, props).resources,

  // ── Lambda builder ─────────────────────────────────────────────────────
  // Returns { resources, fn, logGroup, version, routes(apiLogical, routes) }.
  // Use .resources to merge with +, .fn to reference the function logical ID.
  //
  //   local myApp = aws.lambda('MyApp', { FunctionName: '...', ... });
  //   myApp.resources
  //   + myApp.routes('MyApi', { Default: { routeKey: '$default' } })
  lambda(prefix, props)::
    local functionName = props.FunctionName;
    local fnLogical = prefix + 'Function';
    local defaults = {
      Runtime: 'python3.12',
      MemorySize: 128,
      Timeout: 300,
    };
    {
      fn: fnLogical,
      logGroup: prefix + 'LogGroup',
      version: prefix + 'Version',

      resources: {
        [prefix + 'LogGroup']: {
          Type: 'AWS::Logs::LogGroup',
          Properties: { LogGroupName: '/aws/lambda/' + functionName },
        },
        [fnLogical]: {
          Type: 'AWS::Lambda::Function',
          Properties: defaults + props,
          DependsOn: [prefix + 'LogGroup'],
        },
        [prefix + 'Version']: {
          Type: 'AWS::Lambda::Version',
          DeletionPolicy: 'Retain',
          Properties: { FunctionName: { Ref: fnLogical } },
        },
      },

      // Generate HTTP API routes wired to this function.
      // routeMap is { RouteName: { routeKey: '...', authorizerId?: ... } }
      routes(apiLogical, routeMap)::
        local routeNames = std.objectFields(routeMap);
        // One integration shared by all routes on this API
        local integLogical = prefix + apiLogical + 'Integration';
        { [integLogical]: {
          Type: 'AWS::ApiGatewayV2::Integration',
          Properties: {
            ApiId: cfn.ref(apiLogical),
            IntegrationType: 'AWS_PROXY',
            IntegrationUri: cfn.getArn(fnLogical),
            PayloadFormatVersion: '2.0',
          },
        } }
        + std.foldl(
          function(acc, name)
            local r = routeMap[name];
            acc + {
              [prefix + name + 'Route']: {
                Type: 'AWS::ApiGatewayV2::Route',
                Properties: {
                  ApiId: cfn.ref(apiLogical),
                  RouteKey: r.routeKey,
                  Target: cfn.sub('integrations/${' + integLogical + '}'),
                }
                + (if std.objectHas(r, 'authorizerId') && r.authorizerId != null then {
                  AuthorizationType: 'JWT',
                  AuthorizerId: r.authorizerId,
                } else {}),
              },
            },
          routeNames, {}
        )
        + {
          [prefix + apiLogical + 'Permission']: {
            Type: 'AWS::Lambda::Permission',
            Properties: {
              FunctionName: cfn.getArn(fnLogical),
              Action: 'lambda:InvokeFunction',
              Principal: 'apigateway.amazonaws.com',
              SourceArn: cfn.sub('arn:${AWS::Partition}:execute-api:${AWS::Region}:${AWS::AccountId}:${' + apiLogical + '}/*'),
            },
          },
        },
    },


  // ── Service role ──────────────────────────────────────────────────────────
  // Returns a single IAM::Role trusted by an AWS service.
  //   AppRole: aws.serviceRole('ecs-tasks.amazonaws.com', [...])
  serviceRole(service, statements=[], managedPolicies=[]):: {
    Type: 'AWS::IAM::Role',
    Properties: {
      AssumeRolePolicyDocument: {
        Version: '2012-10-17',
        Statement: [{
          Effect: 'Allow',
          Principal: { Service: service },
          Action: 'sts:AssumeRole',
        }],
      },
    }
    + (if statements != [] then {
      Policies: [{
        PolicyName: 'policy',
        PolicyDocument: { Version: '2012-10-17', Statement: statements },
      }],
    } else {})
    + (if managedPolicies != [] then { ManagedPolicyArns: managedPolicies } else {}),
  },

  // ── Assumable role ─────────────────────────────────────────────────────────
  // Returns a single IAM::Role trusted by AWS principals (account IDs, role ARNs).
  //   ReadOnly: aws.assumableRole([accountId], [...], condition={...})
  assumableRole(principals, statements=[], condition=null, managedPolicies=[]):: {
    Type: 'AWS::IAM::Role',
    Properties: {
      AssumeRolePolicyDocument: {
        Version: '2012-10-17',
        Statement: [{
          Effect: 'Allow',
          Principal: { AWS: principals },
          Action: 'sts:AssumeRole',
        } + (if condition != null then { Condition: condition } else {})],
      },
    }
    + (if statements != [] then {
      Policies: [{
        PolicyName: 'policy',
        PolicyDocument: { Version: '2012-10-17', Statement: statements },
      }],
    } else {})
    + (if managedPolicies != [] then { ManagedPolicyArns: managedPolicies } else {}),
  },

  // ── Lambda execution role ────────────────────────────────────────────────
  // serviceRole specialized for Lambda — adds CloudWatch Logs permissions
  // scoped to the given function name prefix.
  lambdaRole(logPrefix, statements=[], managedPolicies=[])::
    $.serviceRole('lambda.amazonaws.com', [
      cfn.allow(
        ['logs:CreateLogStream', 'logs:CreateLogGroup', 'logs:TagResource'],
        cfn.arn('logs', 'log-group:/aws/lambda/' + logPrefix + '*:*'),
      ),
      cfn.allow(
        ['logs:PutLogEvents'],
        cfn.arn('logs', 'log-group:/aws/lambda/' + logPrefix + '*:*:*'),
      ),
    ] + statements, managedPolicies),


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


  // ── Log subscription filter ───────────────────────────────────────────
  // Returns a single resource value. Forwards a log group to a destination
  // (Splunk, Kinesis Firehose, another account's log group, etc.).
  logSubscription(logGroupName, destinationArn):: {
    Type: 'AWS::Logs::SubscriptionFilter',
    Properties: {
      LogGroupName: logGroupName,
      DestinationArn: destinationArn,
      FilterPattern: '',
    },
  },


  // ── HTTP API (API Gateway v2) ──────────────────────────────────────────

  // Expands to: {prefix} (Api) + {prefix}Stage.
  //   aws.httpApiG('MyApi', 'my-service-dev')
  httpApiG(prefix, name):: {
    [prefix]: {
      Type: 'AWS::ApiGatewayV2::Api',
      Properties: { Name: name, ProtocolType: 'HTTP' },
    },
    [prefix + 'Stage']: {
      Type: 'AWS::ApiGatewayV2::Stage',
      Properties: {
        ApiId: cfn.ref(prefix),
        StageName: '$default',
        AutoDeploy: true,
      },
    },
  },

  // Returns a single JWT authorizer value.
  //   MyApiAuth: aws.jwtAuthorizer('MyApi', 'jwt', issuer, audience)
  jwtAuthorizer(apiLogical, name, issuer, audience):: {
    Type: 'AWS::ApiGatewayV2::Authorizer',
    Properties: {
      ApiId: cfn.ref(apiLogical),
      Name: name,
      AuthorizerType: 'JWT',
      IdentitySource: ['$request.header.Authorization'],
      JwtConfiguration: { Issuer: issuer, Audience: audience },
    },
  },

  // Expands to: {prefix}Integration + {prefix}Route + {prefix}Permission.
  // Routes a path to a Lambda function through the given HTTP API.
  //   aws.httpApiRouteG('Foo', 'MyApi', 'FooFunction', 'GET /foo')
  //   aws.httpApiRouteG('Bar', 'MyApi', 'BarFunction', '$default', authorizerId=cfn.ref('MyApiAuth'))
  httpApiRouteG(prefix, apiLogical, functionLogical, routeKey, authorizerId=null):: {
    [prefix + 'Integration']: {
      Type: 'AWS::ApiGatewayV2::Integration',
      Properties: {
        ApiId: cfn.ref(apiLogical),
        IntegrationType: 'AWS_PROXY',
        IntegrationUri: cfn.getArn(functionLogical),
        PayloadFormatVersion: '2.0',
      },
    },
    [prefix + 'Route']: {
      Type: 'AWS::ApiGatewayV2::Route',
      Properties: {
        ApiId: cfn.ref(apiLogical),
        RouteKey: routeKey,
        Target: cfn.sub('integrations/${' + prefix + 'Integration}'),
      }
      + (if authorizerId != null then {
        AuthorizationType: 'JWT',
        AuthorizerId: authorizerId,
      } else {}),
    },
    [prefix + 'Permission']: {
      Type: 'AWS::Lambda::Permission',
      Properties: {
        FunctionName: cfn.getArn(functionLogical),
        Action: 'lambda:InvokeFunction',
        Principal: 'apigateway.amazonaws.com',
        SourceArn: cfn.sub('arn:${AWS::Partition}:execute-api:${AWS::Region}:${AWS::AccountId}:${' + apiLogical + '}/*'),
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
