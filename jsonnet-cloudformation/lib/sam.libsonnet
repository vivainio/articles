// sam.libsonnet — Expand SAM-style declarations into raw CloudFormation.
//
// AWS SAM templates use resource types like AWS::Serverless::Function that
// get expanded by the SAM transform at deploy time. This library performs
// the same expansion at build time via Jsonnet, producing plain CFN JSON.
//
// The developer writes SAM-shaped declarations (Function with inline Events,
// Api with Auth), and this library calls sls.libsonnet to generate the
// underlying resources.
//
// Usage:
//   local sam = import 'lib/sam.libsonnet';
//   local fn = sam.Function('Api', { Handler: 'app.handler', Events: {...} }, globals.Function);
//   local api = sam.Api('MyApi', { StageName: 'dev' }, [fn], service='my-svc');
//   { Resources: sls.iamRoleG(..., fn.extraStatements) + fn.resources + api.resources }

local cfn = import 'cfn.libsonnet';
local sls = import 'sls.libsonnet';

{
  // ── Internal helpers ───────────────────────────────────────────────────────

  local titleCase(s) = std.asciiUpper(s[0]) + std.asciiLower(s[1:]),

  // "/{version}/{domain}/items" → "VersionVarDomainVarItems"
  local pathToLogical(path) =
    local segments = [s for s in std.split(path, '/') if s != ''];
    local segmentToId(seg) =
      if std.startsWith(seg, '{') then
        titleCase(std.stripChars(seg, '{}+')) + 'Var'
      else
        titleCase(seg);
    std.join('', [segmentToId(s) for s in segments]),

  // Parse "s3://bucket/path/to/key" into {bucket, key}
  local parseS3Uri(uri) =
    if std.isString(uri) && std.startsWith(uri, 's3://') then
      local stripped = uri[5:];
      local chars = std.stringChars(stripped);
      local idx = std.find('/', chars)[0];
      { bucket: stripped[:idx], key: stripped[idx + 1:] }
    else if std.isObject(uri) then
      { bucket: uri.Bucket, key: uri.Key }
    else
      { bucket: null, key: uri },

  // Safe object field access with default
  local get(obj, field, default=null) =
    if std.objectHas(obj, field) then obj[field] else default,


  // ── Default Globals ────────────────────────────────────────────────────────
  // Override with `sam.defaultGlobals + { Function+: { Runtime: '...' } }`

  defaultGlobals:: {
    Function: {
      Runtime: 'python3.12',
      Timeout: 300,
      MemorySize: 128,
      Environment: { Variables: {} },
      Tags: {},
    },
  },


  // ── AWS::Serverless::Function ──────────────────────────────────────────────
  //
  // The core SAM resource type. Expands to:
  //   - LogGroup + Lambda::Function + Lambda::Version  (always)
  //   - Logs::SubscriptionFilter                       (if logDestination set)
  //   - Events::Rule + Lambda::Permission              (per Schedule event)
  //   - Lambda::EventSourceMapping                     (per SQS event)
  //   - (Api/HttpApi events are collected, not expanded — the Api/HttpApi
  //     expander consumes them)
  //
  // Parameters:
  //   logicalName — PascalCase name, e.g. "ApiHandler". Becomes the CFN ID prefix.
  //   props       — the SAM Properties block: Handler, CodeUri, Events, Policies, etc.
  //   globals     — the Globals.Function object (defaults merged under props)
  //   service     — service name (for function naming: service-stage-logicalName)
  //   stage       — stage name
  //
  // Returns an object with:
  //   .resources       — CFN resource map (merge into Resources with +)
  //   .extraStatements — IAM statements extracted from Policies (pass to sls.iamRoleG)
  //   .apiEvents       — Api events for the Api expander to consume
  //   .httpApiEvents   — HttpApi events for the HttpApi expander to consume
  //   .functionLogical — logical ID of the Lambda::Function resource
  //
  Function(logicalName, props, globals={}, service='', stage='')::
    local g = $.defaultGlobals.Function + globals;

    // Merge globals under props (props wins)
    local functionName = get(props, 'FunctionName', service + '-' + stage + '-' + logicalName);
    local runtime = get(props, 'Runtime', g.Runtime);
    local timeout = get(props, 'Timeout', g.Timeout);
    local memory = get(props, 'MemorySize', g.MemorySize);
    local handler = props.Handler;

    local gEnv = get(get(g, 'Environment', {}), 'Variables', {});
    local fEnv = get(get(props, 'Environment', {}), 'Variables', {});
    local env = gEnv + fEnv;  // function-level wins on conflicts

    local gTags = get(g, 'Tags', {});
    local fTags = get(props, 'Tags', {});
    local tags = cfn.tags(gTags + fTags);

    local vpcConfig = get(props, 'VpcConfig', get(g, 'VpcConfig'));
    local reservedConc = get(props, 'ReservedConcurrentExecutions');
    local logDest = get(props, 'LogDestination', get(g, 'LogDestination'));

    // Parse CodeUri (SAM accepts "s3://bucket/key" string or {Bucket, Key} object)
    local code = parseS3Uri(get(props, 'CodeUri', ''));

    // Extract IAM statements from Policies array
    local policies = get(props, 'Policies', []);
    local extraStatements = std.flatMap(
      function(p)
        if std.isObject(p) && std.objectHas(p, 'Statement') then p.Statement
        else [],
      policies
    );

    // Process Events
    local events = get(props, 'Events', {});
    local eventNames = std.objectFields(events);

    // Expand event types that produce standalone resources
    local eventResources = std.foldl(
      function(acc, eName)
        local e = events[eName];
        local ep = get(e, 'Properties', {});
        acc + (
          if e.Type == 'Schedule' then
            sls.scheduleEventG(
              logicalName,
              get(ep, 'Schedule', get(ep, 'ScheduleExpression', '')),
              get(ep, 'Enabled', true),
              get(ep, 'Name'),
            )
          else if e.Type == 'SQS' then
            local arn = get(ep, 'Queue', get(ep, 'Arn'));
            {
              [logicalName + eName + 'EventSourceMapping']:
                sls.sqsEventSource(
                  logicalName + 'LambdaFunction',
                  // If arn is a GetAtt reference, pass through; otherwise wrap
                  if std.isString(arn) then arn else arn,
                  get(ep, 'BatchSize', 10),
                ),
            }
          // Api and HttpApi events are NOT expanded here — they're collected
          // and passed to the Api/HttpApi expander which handles the full
          // resource tree, CORS, deployment, and permissions.
          else {}
        ),
      eventNames,
      {}
    );

    // Partition events by type for downstream expanders
    local apiEvents = {
      [n]: events[n]
      for n in eventNames
      if events[n].Type == 'Api'
    };
    local httpApiEvents = {
      [n]: events[n]
      for n in eventNames
      if events[n].Type == 'HttpApi'
    };

    {
      resources:
        sls.lambdaFnG(logicalName,
                      {
                        FunctionName: functionName,
                        Handler: handler,
                        Runtime: runtime,
                        MemorySize: memory,
                        Timeout: timeout,
                        Code: { S3Key: code.key }
                              + (if code.bucket != null then { S3Bucket: code.bucket } else {}),
                      }
                      + (if env != {} then { Environment: { Variables: env } } else {})
                      + (if tags != [] then { Tags: tags } else {})
                      + (if vpcConfig != null then { VpcConfig: vpcConfig } else {})
                      + (if reservedConc != null then { ReservedConcurrentExecutions: reservedConc } else {}),
                      logDestination=logDest)
        + eventResources,

      extraStatements: extraStatements,
      apiEvents: apiEvents,
      httpApiEvents: httpApiEvents,
      functionLogical: logicalName + 'LambdaFunction',
    },


  // ── AWS::Serverless::Api (REST API v1) ─────────────────────────────────────
  //
  // Collects Api events from all Functions, then generates:
  //   - ApiGateway::RestApi
  //   - ApiGateway::Resource tree (deduplicated shared path segments)
  //   - ApiGateway::Method per route (AWS_PROXY)
  //   - CORS OPTIONS mock per unique path
  //   - ApiGateway::Deployment
  //   - Lambda::Permission per function
  //   - ApiKey + UsagePlan (if Auth.UsagePlan is configured)
  //
  // In SAM, all of this is generated from a single AWS::Serverless::Api
  // resource plus the Events declarations on functions.
  //
  // Parameters:
  //   logicalName — e.g. "MyApi" (not used in resource IDs, only for clarity)
  //   props       — SAM Properties: StageName, Auth, etc.
  //   functions   — array of Function() results that have Api events
  //   service     — service name (for API key naming)
  //
  Api(logicalName, props, functions, service='')::
    local stage = get(props, 'StageName', 'prod');
    local apiName = stage + '-' + service;

    // Collect all Api events across all functions into a flat route list
    local allRoutes = std.flatMap(
      function(fn) [
        local ep = fn.apiEvents[n].Properties;
        {
          path: ep.Path,
          method: std.asciiUpper(ep.Method),
          functionLogical: fn.functionLogical,
          apiKeyRequired:
            local auth = get(ep, 'Auth', {});
            get(auth, 'ApiKeyRequired', false),
        }
        for n in std.objectFields(fn.apiEvents)
      ],
      functions
    );

    // Unique paths across all routes
    local allPaths = std.set([r.path for r in allRoutes]);

    // All unique path segments (prefixes) that need ApiGateway::Resource entries.
    // For /a/b/c we need resources for /a, /a/b, and /a/b/c.
    local allSegments = std.set(std.flatMap(
      function(path)
        local parts = [s for s in std.split(path, '/') if s != ''];
        [std.join('/', [''] + parts[:i + 1]) for i in std.range(0, std.length(parts) - 1)],
      allPaths
    ));

    local segLogical(p) = 'ApiGatewayResource' + pathToLogical(p);
    local lastPart(p) =
      local parts = [s for s in std.split(p, '/') if s != ''];
      parts[std.length(parts) - 1];
    local parentOf(p) =
      local parts = [s for s in std.split(p, '/') if s != ''];
      if std.length(parts) <= 1 then null
      else std.join('/', [''] + parts[:std.length(parts) - 1]);
    local parentId(p) =
      local par = parentOf(p);
      if par == null then { 'Fn::GetAtt': ['ApiGatewayRestApi', 'RootResourceId'] }
      else { Ref: segLogical(par) };

    // Resource tree
    local resourceResources = std.foldl(
      function(acc, seg) acc { [segLogical(seg)]: sls.apiResource(parentId(seg), lastPart(seg)) },
      allSegments,
      {}
    );

    // Methods
    local methodLogical(path, method) = 'ApiGatewayMethod' + pathToLogical(path) + titleCase(method);
    local methodResources = std.foldl(
      function(acc, r) acc {
        [methodLogical(r.path, r.method)]:
          sls.apiMethod(
            segLogical(r.path),
            r.method,
            r.functionLogical,
            apiKeyRequired=r.apiKeyRequired,
          ),
      },
      allRoutes,
      {}
    );

    // CORS OPTIONS (one per unique path, listing all verbs on that path)
    local corsLogical(path) = 'ApiGatewayMethod' + pathToLogical(path) + 'Options';
    local methodsForPath(path) = [r.method for r in allRoutes if r.path == path];
    local corsResources = std.foldl(
      function(acc, path) acc {
        [corsLogical(path)]:
          sls.corsOptions(segLogical(path), methodsForPath(path)),
      },
      allPaths,
      {}
    );

    // All method IDs for Deployment DependsOn
    local allMethodIds =
      [methodLogical(r.path, r.method) for r in allRoutes]
      + [corsLogical(p) for p in allPaths];

    // Lambda permissions (one per unique function)
    local uniqueFns = std.set([r.functionLogical for r in allRoutes]);
    local permResources = std.foldl(
      function(acc, fl) acc { [fl + 'PermissionApiGateway']: sls.apiLambdaPermission(fl) },
      uniqueFns,
      {}
    );

    // Usage plan / API key
    local hasUsagePlan = std.objectHas(get(props, 'Auth', {}), 'UsagePlan');

    {
      resources:
        sls.restApiG(apiName)
        + resourceResources
        + methodResources
        + corsResources
        + { ApiGatewayDeployment: sls.apiDeployment(stage, dependsOn=allMethodIds) }
        + permResources
        + (if hasUsagePlan then {
             ApiGatewayApiKey1: {
               Type: 'AWS::ApiGateway::ApiKey',
               Properties: {
                 Enabled: true,
                 Name: service + '-' + stage + '-apikey',
                 StageKeys: [{ RestApiId: { Ref: 'ApiGatewayRestApi' }, StageName: stage }],
               },
               DependsOn: 'ApiGatewayDeployment',
             },
             ApiGatewayUsagePlan: {
               Type: 'AWS::ApiGateway::UsagePlan',
               DependsOn: 'ApiGatewayDeployment',
               Properties: {
                 ApiStages: [{ ApiId: { Ref: 'ApiGatewayRestApi' }, Stage: stage }],
                 Description: 'Usage plan for ' + service + ' ' + stage + ' stage',
                 UsagePlanName: service + '-' + stage,
               },
             },
             ApiGatewayUsagePlanKey1: {
               Type: 'AWS::ApiGateway::UsagePlanKey',
               Properties: {
                 KeyId: { Ref: 'ApiGatewayApiKey1' },
                 KeyType: 'API_KEY',
                 UsagePlanId: { Ref: 'ApiGatewayUsagePlan' },
               },
             },
           } else {}),
    },


  // ── AWS::Serverless::HttpApi (API Gateway v2) ─────────────────────────────
  //
  // Collects HttpApi events from all Functions, then generates:
  //   - ApiGatewayV2::Api + Stage (auto-deploy)
  //   - ApiGatewayV2::Authorizer (per authorizer)
  //   - ApiGatewayV2::Integration (one per function)
  //   - ApiGatewayV2::Route (one per event)
  //   - Lambda::Permission (one per function)
  //
  HttpApi(logicalName, props, functions)::
    local name = get(props, 'Name', logicalName);

    // Authorizers
    local authCfg = get(get(props, 'Auth', {}), 'Authorizers', {});
    local authResources = std.foldl(
      function(acc, aName)
        local a = authCfg[aName];
        acc {
          ['HttpApiAuthorizer' + titleCase(aName)]:
            sls.httpApiJwtAuthorizer(
              aName,
              a.Issuer,
              a.Audience,
            ),
        },
      std.objectFields(authCfg),
      {}
    );

    // Per-function: Integration + Routes + Permission
    local fnResources = std.foldl(
      function(acc, fn)
        local routes = [
          local ep = fn.httpApiEvents[n].Properties;
          local authName = get(get(ep, 'Auth', {}), 'Authorizer');
          {
            logical: 'HttpApiRoute' + titleCase(ep.Method) + pathToLogical(ep.Path),
            routeKey: std.asciiUpper(ep.Method) + ' ' + ep.Path,
            authorizerId:
              if authName != null then { Ref: 'HttpApiAuthorizer' + titleCase(authName) }
              else null,
          }
          for n in std.objectFields(fn.httpApiEvents)
        ];
        local fnName = std.strReplace(fn.functionLogical, 'LambdaFunction', '');
        acc + sls.httpApiFnG(fnName, fn.functionLogical, routes),
      functions,
      {}
    );

    {
      resources:
        sls.httpApiG(name)
        + authResources
        + fnResources,
    },
}
