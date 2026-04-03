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
local sls = import '../lib/sls.libsonnet';
local actions = import '../lib/cfn-actions.libsonnet';

local service = 'user-api';
local stage   = std.extVar('stage');
local tags = cfn.tags({ Service: service, Stage: stage });

local authorizerLogical = 'HttpApiAuthorizerAuth0';
local authRef = cfn.ref(authorizerLogical);

{
  AWSTemplateFormatVersion: '2010-09-09',

  Resources:
    sls.deploymentBucketG
    + sls.iamRoleG(service + '-' + stage, [
      cfn.allow(actions.ddbAll, cfn.arn('dynamodb', 'table/users-' + stage)),
    ])

    // Lambda function
    + sls.lambdaFnG('Api', {
      FunctionName: service + '-' + stage + '-api',
      Handler: 'app.handler',
      Code: { S3Key: 'serverless/' + service + '/' + stage + '/package.zip' },
      Environment: { Variables: { STAGE: stage, TABLE_NAME: 'users-' + stage } },
      Tags: tags,
    })

    // HTTP API + auto-deploy stage
    + sls.httpApiG(stage + '-' + service)

    // JWT authorizer
    + { [authorizerLogical]: sls.httpApiJwtAuthorizer(
      'auth0',
      'https://example.auth0.com/',
      ['https://api.example.com'],
    ) }

    // Integration + routes + permission (all in one call)
    + sls.httpApiFnG('Api', 'ApiLambdaFunction', [
      { logical: 'HttpApiRouteGetUsersIdVar',    routeKey: 'GET /users/{id}',    authorizerId: authRef },
      { logical: 'HttpApiRoutePutUsersIdVar',    routeKey: 'PUT /users/{id}',    authorizerId: authRef },
      { logical: 'HttpApiRouteDeleteUsersIdVar', routeKey: 'DELETE /users/{id}', authorizerId: authRef },
      { logical: 'HttpApiRouteGetUsers',         routeKey: 'GET /users',         authorizerId: authRef },
      { logical: 'HttpApiRoutePostUsers',        routeKey: 'POST /users',        authorizerId: authRef },
    ]),

  Outputs: {
    ApiEndpoint: cfn.output(cfn.sub('https://${HttpApi}.execute-api.${AWS::Region}.${AWS::URLSuffix}')),
  },
}
