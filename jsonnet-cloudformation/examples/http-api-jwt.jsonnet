// Example 4: HTTP API (v2) with JWT authorization
//
// API Gateway v2 with a JWT authorizer — the modern, simpler alternative to
// REST API v1. No resource tree, no CORS mocks, auto-deploy stage.
//
// The equivalent serverless.yml would be:
//
//   service: user-api
//   provider:
//     name: aws
//     runtime: python3.12
//     stage: dev
//     httpApi:
//       authorizers:
//         auth0:
//           type: jwt
//           issuerUrl: https://example.auth0.com/
//           audience: [https://api.example.com]
//   functions:
//     api:
//       handler: app.handler
//       events:
//         - httpApi: { method: GET,    path: /users/{id},  authorizer: auth0 }
//         - httpApi: { method: PUT,    path: /users/{id},  authorizer: auth0 }
//         - httpApi: { method: DELETE, path: /users/{id},  authorizer: auth0 }
//         - httpApi: { method: GET,    path: /users,       authorizer: auth0 }
//         - httpApi: { method: POST,   path: /users,       authorizer: auth0 }

local cfn = import '../lib/cfn.libsonnet';

local service = 'user-api';
local stage   = std.extVar('stage');

local authorizerLogical = 'HttpApiAuthorizerAuth0';
local authRef = { Ref: authorizerLogical };

{
  AWSTemplateFormatVersion: '2010-09-09',

  Resources:
    cfn.deploymentBucket
    + cfn.iamRole(service, stage, [
      {
        Effect: 'Allow',
        Action: ['dynamodb:GetItem', 'dynamodb:PutItem', 'dynamodb:DeleteItem', 'dynamodb:Query', 'dynamodb:Scan'],
        Resource: { 'Fn::Sub': 'arn:aws:dynamodb:${AWS::Region}:${AWS::AccountId}:table/users-' + stage },
      },
    ])

    // Lambda function
    + cfn.lambdaFn(
      logicalName='Api',
      functionName=service + '-' + stage + '-api',
      handler='app.handler',
      s3Key='serverless/' + service + '/' + stage + '/package.zip',
      env={ STAGE: stage, TABLE_NAME: 'users-' + stage },
    )

    // HTTP API + auto-deploy stage
    + cfn.httpApi(stage + '-' + service)

    // JWT authorizer
    + cfn.httpApiJwtAuthorizer(
      authorizerLogical,
      'auth0',
      'https://example.auth0.com/',
      ['https://api.example.com'],
    )

    // Integration + routes + permission (all in one call)
    + cfn.httpApiFn('Api', 'ApiLambdaFunction', [
      { logical: 'HttpApiRouteGetUsersIdVar',    routeKey: 'GET /users/{id}',    authorizerId: authRef },
      { logical: 'HttpApiRoutePutUsersIdVar',    routeKey: 'PUT /users/{id}',    authorizerId: authRef },
      { logical: 'HttpApiRouteDeleteUsersIdVar', routeKey: 'DELETE /users/{id}', authorizerId: authRef },
      { logical: 'HttpApiRouteGetUsers',         routeKey: 'GET /users',         authorizerId: authRef },
      { logical: 'HttpApiRoutePostUsers',        routeKey: 'POST /users',        authorizerId: authRef },
    ]),

  Outputs: {
    ApiEndpoint: {
      Value: { 'Fn::Sub': 'https://${HttpApi}.execute-api.${AWS::Region}.${AWS::URLSuffix}' },
    },
  },
}
