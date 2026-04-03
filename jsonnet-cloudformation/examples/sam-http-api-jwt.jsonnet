// Example 6: SAM-style HTTP API with JWT — same output as http-api-jwt.jsonnet
//
// The equivalent SAM template would be:
//
//   Transform: AWS::Serverless-2016-10-31
//   Resources:
//     Api:
//       Type: AWS::Serverless::Function
//       Properties:
//         Handler: app.handler
//         Events:
//           GetUser:    { Type: HttpApi, Properties: { Path: /users/{id}, Method: GET,    Auth: { Authorizer: auth0 } } }
//           ...
//     UserHttpApi:
//       Type: AWS::Serverless::HttpApi
//       Properties:
//         Auth:
//           Authorizers:
//             auth0:
//               AuthorizationScopes: []
//               IdentitySource: $request.header.Authorization
//               JwtConfiguration:
//                 issuer: https://example.auth0.com/
//                 audience: [https://api.example.com]

local sam = import '../lib/sam.libsonnet';
local cfn = import '../lib/cfn.libsonnet';

local service = 'user-api';
local stage   = std.extVar('stage');

// ── AWS::Serverless::Function ────────────────────────────────────────────────
local apiHandler = sam.Function('Api', {
  Handler: 'app.handler',
  CodeUri: 's3://my-deploy-bucket/' + service + '/' + stage + '/package.zip',
  Environment: { Variables: { STAGE: stage, TABLE_NAME: 'users-' + stage } },
  Policies: [{
    Version: '2012-10-17',
    Statement: [{
      Effect: 'Allow',
      Action: ['dynamodb:GetItem', 'dynamodb:PutItem', 'dynamodb:DeleteItem', 'dynamodb:Query', 'dynamodb:Scan'],
      Resource: cfn.sub('arn:aws:dynamodb:${AWS::Region}:${AWS::AccountId}:table/users-' + stage),
    }],
  }],
  Events: {
    GetUser:    { Type: 'HttpApi', Properties: { Path: '/users/{id}', Method: 'GET',    Auth: { Authorizer: 'auth0' } } },
    PutUser:    { Type: 'HttpApi', Properties: { Path: '/users/{id}', Method: 'PUT',    Auth: { Authorizer: 'auth0' } } },
    DeleteUser: { Type: 'HttpApi', Properties: { Path: '/users/{id}', Method: 'DELETE', Auth: { Authorizer: 'auth0' } } },
    ListUsers:  { Type: 'HttpApi', Properties: { Path: '/users',      Method: 'GET',    Auth: { Authorizer: 'auth0' } } },
    CreateUser: { Type: 'HttpApi', Properties: { Path: '/users',      Method: 'POST',   Auth: { Authorizer: 'auth0' } } },
  },
}, service=service, stage=stage);

// ── AWS::Serverless::HttpApi ─────────────────────────────────────────────────
local httpApi = sam.HttpApi('UserHttpApi', {
  Name: stage + '-' + service,
  Auth: {
    Authorizers: {
      auth0: {
        Issuer: 'https://example.auth0.com/',
        Audience: ['https://api.example.com'],
      },
    },
  },
}, functions=[apiHandler]);

// ── Assemble ─────────────────────────────────────────────────────────────────
{
  AWSTemplateFormatVersion: '2010-09-09',
  Resources:
    cfn.deploymentBucket
    + cfn.iamRole(service, stage, apiHandler.extraStatements)
    + apiHandler.resources
    + httpApi.resources,
  Outputs: {
    Endpoint: cfn.output(cfn.sub('https://${HttpApi}.execute-api.${AWS::Region}.${AWS::URLSuffix}')),
  },
}
