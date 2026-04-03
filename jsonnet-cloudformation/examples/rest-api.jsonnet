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

local service = 'todo-api';
local stage   = std.extVar('stage');
local fn      = 'ApiLambdaFunction';

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
    cfn.deploymentBucket
    + cfn.iamRole(service, stage, [
      {
        Effect: 'Allow',
        Action: ['dynamodb:GetItem', 'dynamodb:PutItem', 'dynamodb:DeleteItem', 'dynamodb:Query'],
        Resource: { 'Fn::Sub': 'arn:aws:dynamodb:${AWS::Region}:${AWS::AccountId}:table/todos-*' },
      },
    ])

    // Single Lambda function serving all routes
    + cfn.lambdaFn(
      logicalName='Api',
      functionName=service + '-' + stage + '-api',
      handler='wsgi_handler.handler',
      s3Key='serverless/' + service + '/' + stage + '/package.zip',
      env={ STAGE: stage },
    )

    // REST API
    + cfn.restApi(stage + '-' + service)

    // Resource tree: /todos and /todos/{id}
    + cfn.apiResource(r.todos,  { 'Fn::GetAtt': ['ApiGatewayRestApi', 'RootResourceId'] }, 'todos')
    + cfn.apiResource(r.todoId, { Ref: r.todos }, '{id}')

    // Methods on /todos
    + cfn.apiMethod('ApiGatewayMethodTodosGet',  r.todos, 'GET',  fn, apiKeyRequired=true)
    + cfn.apiMethod('ApiGatewayMethodTodosPost', r.todos, 'POST', fn, apiKeyRequired=true)
    + cfn.corsOptions('ApiGatewayMethodTodosOptions', r.todos, ['GET', 'POST'])

    // Methods on /todos/{id}
    + cfn.apiMethod('ApiGatewayMethodTodosIdVarGet',    r.todoId, 'GET',    fn, apiKeyRequired=true)
    + cfn.apiMethod('ApiGatewayMethodTodosIdVarPut',    r.todoId, 'PUT',    fn, apiKeyRequired=true)
    + cfn.apiMethod('ApiGatewayMethodTodosIdVarDelete', r.todoId, 'DELETE', fn, apiKeyRequired=true)
    + cfn.corsOptions('ApiGatewayMethodTodosIdVarOptions', r.todoId, ['GET', 'PUT', 'DELETE'])

    // Deployment + permission
    + cfn.apiDeployment('ApiGatewayDeployment', stage, dependsOn=methods)
    + cfn.apiLambdaPermission('ApiLambdaPermissionApiGateway', fn),

  Outputs: {
    ServiceEndpoint: {
      Value: { 'Fn::Sub': 'https://${ApiGatewayRestApi}.execute-api.${AWS::Region}.${AWS::URLSuffix}/' + stage },
    },
  },
}
