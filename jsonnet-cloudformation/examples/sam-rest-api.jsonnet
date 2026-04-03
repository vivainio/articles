// Example 5: SAM-style REST API — same output as rest-api.jsonnet, SAM input
//
// This demonstrates writing SAM-shaped declarations and expanding them to
// raw CloudFormation at build time.
//
// The equivalent SAM template would be:
//
//   Transform: AWS::Serverless-2016-10-31
//   Globals:
//     Function:
//       Runtime: python3.12
//       Timeout: 300
//       MemorySize: 128
//       Environment:
//         Variables:
//           STAGE: dev
//   Resources:
//     Api:
//       Type: AWS::Serverless::Function
//       Properties:
//         Handler: wsgi_handler.handler
//         CodeUri: s3://my-bucket/todo-api/dev/package.zip
//         Policies:
//           - Statement:
//               - Effect: Allow
//                 Action: [dynamodb:GetItem, dynamodb:PutItem, ...]
//                 Resource: !Sub "arn:aws:dynamodb:..."
//         Events:
//           GetTodos:    { Type: Api, Properties: { Path: /todos,      Method: get,    Auth: { ApiKeyRequired: true } } }
//           PostTodos:   { Type: Api, Properties: { Path: /todos,      Method: post,   Auth: { ApiKeyRequired: true } } }
//           GetTodo:     { Type: Api, Properties: { Path: /todos/{id}, Method: get,    Auth: { ApiKeyRequired: true } } }
//           PutTodo:     { Type: Api, Properties: { Path: /todos/{id}, Method: put,    Auth: { ApiKeyRequired: true } } }
//           DeleteTodo:  { Type: Api, Properties: { Path: /todos/{id}, Method: delete, Auth: { ApiKeyRequired: true } } }
//     TodoApi:
//       Type: AWS::Serverless::Api
//       Properties:
//         StageName: dev
//         Auth:
//           UsagePlan: { CreateUsagePlan: PER_API }

local sam = import '../lib/sam.libsonnet';
local cfn = import '../lib/cfn.libsonnet';
local sls = import '../lib/sls.libsonnet';
local actions = import '../lib/cfn-actions.libsonnet';

local service = 'todo-api';
local stage   = std.extVar('stage');

// ── Globals ──────────────────────────────────────────────────────────────────
local globals = {
  Function: {
    Runtime: 'python3.12',
    Timeout: 300,
    MemorySize: 128,
    Environment: { Variables: { STAGE: stage } },
  },
};

// ── AWS::Serverless::Function ────────────────────────────────────────────────
local apiHandler = sam.Function('Api', {
  Handler: 'wsgi_handler.handler',
  CodeUri: 's3://my-deploy-bucket/' + service + '/' + stage + '/package.zip',
  Policies: cfn.policies([
    cfn.allow(actions.ddbRead + actions.ddbWrite, cfn.arn('dynamodb', 'table/todos-' + stage)),
  ]),
  Events: {
    GetTodos:    { Type: 'Api', Properties: { Path: '/todos',      Method: 'get',    Auth: { ApiKeyRequired: true } } },
    PostTodos:   { Type: 'Api', Properties: { Path: '/todos',      Method: 'post',   Auth: { ApiKeyRequired: true } } },
    GetTodo:     { Type: 'Api', Properties: { Path: '/todos/{id}', Method: 'get',    Auth: { ApiKeyRequired: true } } },
    PutTodo:     { Type: 'Api', Properties: { Path: '/todos/{id}', Method: 'put',    Auth: { ApiKeyRequired: true } } },
    DeleteTodo:  { Type: 'Api', Properties: { Path: '/todos/{id}', Method: 'delete', Auth: { ApiKeyRequired: true } } },
  },
}, globals=globals.Function, service=service, stage=stage);

// ── AWS::Serverless::Api ─────────────────────────────────────────────────────
local api = sam.Api('TodoApi', {
  StageName: stage,
  Auth: { UsagePlan: { CreateUsagePlan: 'PER_API' } },
}, functions=[apiHandler], service=service);

// ── Assemble ─────────────────────────────────────────────────────────────────
{
  AWSTemplateFormatVersion: '2010-09-09',
  Resources:
    sls.deploymentBucketG
    + sls.iamRoleG(service + '-' + stage, apiHandler.extraStatements)
    + apiHandler.resources
    + api.resources,
  Outputs: {
    Endpoint: cfn.output(cfn.sub('https://${ApiGatewayRestApi}.execute-api.${AWS::Region}.${AWS::URLSuffix}/' + stage)),
  },
}
