// Example 2: REST API with CORS and API key
//
// A WSGI/Express-style Lambda behind API Gateway v1 (REST).
// All routes point to a single function — the framework (Flask, Express)
// handles routing internally. CORS OPTIONS mocks are generated for each path.
//
// The equivalent serverless.yml would be:
//
//   service: todo-api
//   provider:
//     name: aws
//     runtime: python3.12
//     stage: dev
//     endpointType: EDGE
//     apiKeys:
//       - name: todo-api-dev-key
//     iamRoleStatements:
//       - Effect: Allow
//         Action: [dynamodb:GetItem, dynamodb:PutItem, dynamodb:DeleteItem, dynamodb:Query]
//         Resource: !Sub "arn:aws:dynamodb:${AWS::Region}:${AWS::AccountId}:table/todos-*"
//   functions:
//     api:
//       handler: wsgi_handler.handler
//       events:
//         - http: { method: get,    path: /todos,      cors: true, private: true }
//         - http: { method: post,   path: /todos,      cors: true, private: true }
//         - http: { method: get,    path: /todos/{id}, cors: true, private: true }
//         - http: { method: put,    path: /todos/{id}, cors: true, private: true }
//         - http: { method: delete, path: /todos/{id}, cors: true, private: true }

local cfn = import '../lib/cfn.libsonnet';
local sls = import '../lib/sls.libsonnet';
local actions = import '../lib/cfn-actions.libsonnet';

local service = 'todo-api';
local stage   = std.extVar('stage');
local fn      = 'ApiLambdaFunction';
local tags = cfn.tags({ Service: service, Stage: stage });

// Logical IDs for API Gateway resources
local r = {
  todos:   'ApiGatewayResourceTodos',
  todoId:  'ApiGatewayResourceTodosIdVar',
};

// All method logical IDs (needed for Deployment DependsOn)
local methods = [
  'ApiGatewayMethodTodosGet',
  'ApiGatewayMethodTodosPost',
  'ApiGatewayMethodTodosOptions',
  'ApiGatewayMethodTodosIdVarGet',
  'ApiGatewayMethodTodosIdVarPut',
  'ApiGatewayMethodTodosIdVarDelete',
  'ApiGatewayMethodTodosIdVarOptions',
];

{
  AWSTemplateFormatVersion: '2010-09-09',

  Resources:
    sls.deploymentBucketG
    + sls.iamRoleG(service + '-' + stage, [
      cfn.allow(actions.ddbRead + actions.ddbWrite, cfn.sub('arn:aws:dynamodb:${AWS::Region}:${AWS::AccountId}:table/todos-*')),
    ])

    // Single Lambda function serving all routes
    + sls.lambdaFnG(
      logicalName='Api',
      functionName=service + '-' + stage + '-api',
      handler='wsgi_handler.handler',
      s3Key='serverless/' + service + '/' + stage + '/package.zip',
      env={ STAGE: stage },
      tags=tags,
    )

    // REST API
    + sls.restApiG(stage + '-' + service)

    + {
      // Resource tree: /todos and /todos/{id}
      [r.todos]:  sls.apiResource(cfn.getAtt('ApiGatewayRestApi', 'RootResourceId'), 'todos'),
      [r.todoId]: sls.apiResource(cfn.ref(r.todos), '{id}'),

      // Methods on /todos
      ApiGatewayMethodTodosGet:  sls.apiMethod(r.todos, 'GET',  fn, apiKeyRequired=true),
      ApiGatewayMethodTodosPost: sls.apiMethod(r.todos, 'POST', fn, apiKeyRequired=true),
      ApiGatewayMethodTodosOptions: sls.corsOptions(r.todos, ['GET', 'POST']),

      // Methods on /todos/{id}
      ApiGatewayMethodTodosIdVarGet:    sls.apiMethod(r.todoId, 'GET',    fn, apiKeyRequired=true),
      ApiGatewayMethodTodosIdVarPut:    sls.apiMethod(r.todoId, 'PUT',    fn, apiKeyRequired=true),
      ApiGatewayMethodTodosIdVarDelete: sls.apiMethod(r.todoId, 'DELETE', fn, apiKeyRequired=true),
      ApiGatewayMethodTodosIdVarOptions: sls.corsOptions(r.todoId, ['GET', 'PUT', 'DELETE']),

      // Deployment + permission
      ApiGatewayDeployment: sls.apiDeployment(stage, dependsOn=methods),
      ApiLambdaPermissionApiGateway: sls.apiLambdaPermission(fn),
    },

  Outputs: {
    ServiceEndpoint: cfn.output(cfn.sub('https://${ApiGatewayRestApi}.execute-api.${AWS::Region}.${AWS::URLSuffix}/' + stage)),
  },
}
