// sfn.libsonnet — Step Functions state machine helpers.
//
// Builders for common state machine patterns: retry/catch blocks,
// poll loops, timed starts, Map states, and Choice dispatchers.
// Eliminates the copy-paste of identical retry/catch blocks across
// dozens of Task states.
//
// Usage:
//   local sfn = import 'lib/sfn.libsonnet';
//   local cfn = import 'lib/cfn.libsonnet';
//
//   sfn.pollLoop('CheckUpgrade', lambdaArn, {
//     waitSeconds: 60,
//     finishedVar: '$.finished',
//   })

local cfn = import 'cfn.libsonnet';

{
  // ── Standard retry/catch ──────────────────────────────────────────────────
  // The same 7 transient errors appear on nearly every Task in a real state
  // machine. These helpers attach them so you don't repeat the list.

  // Common transient Lambda errors worth retrying.
  transientErrors:: [
    'Lambda.ServiceException',
    'Lambda.AWSLambdaException',
    'Lambda.SdkClientException',
    'Lambda.TooManyRequestsException',
    'States.TaskFailed',
  ],

  // Default retry config: exponential backoff, 3 attempts.
  retry(errors=self.transientErrors, interval=5, maxAttempts=3, backoff=2.0):: [{
    ErrorEquals: errors,
    IntervalSeconds: interval,
    MaxAttempts: maxAttempts,
    BackoffRate: backoff,
  }],

  // Default catch-all: route to a failure state, preserve error in $.error.
  catch(failState):: [{
    ErrorEquals: ['States.ALL'],
    Next: failState,
    ResultPath: '$.error',
  }],

  // ── Task with retry/catch ─────────────────────────────────────────────────
  // A Task state with standard retry and catch-all. This is the most common
  // state type in any non-trivial state machine.
  task(lambdaArn, next, failState=null, retry=null, end=false)::
    {
      Type: 'Task',
      Resource: lambdaArn,
    }
    + (if end then { End: true } else { Next: next })
    + { Retry: if retry != null then retry else $.retry() }
    + (if failState != null then { Catch: $.catch(failState) } else {}),

  // ── Poll loop ─────────────────────────────────────────────────────────────
  // Wait → Task → Choice (finished? → next, else → Wait again).
  // This pattern appears for every "check status until done" workflow.
  //
  // Returns a states object: { Wait_X, Check_X, Verify_X }.
  //
  //   sfn.pollLoop('UpgradeStatus', arn, {
  //     waitSeconds: 60,
  //     finishedVar: '$.finished',
  //     doneNext: 'Succeeded',
  //     failState: 'Failed',
  //   })
  pollLoop(name, lambdaArn, opts={})::
    local waitSec = if std.objectHas(opts, 'waitSeconds') then opts.waitSeconds else 30;
    local waitPath = if std.objectHas(opts, 'waitSecondsPath') then opts.waitSecondsPath else null;
    local finVar = if std.objectHas(opts, 'finishedVar') then opts.finishedVar else '$.finished';
    local doneNext = if std.objectHas(opts, 'doneNext') then opts.doneNext else 'Common_OperationSucceeded';
    local failState = if std.objectHas(opts, 'failState') then opts.failState else 'Common_OperationFailed';
    {
      ['Wait_' + name]: {
        Type: 'Wait',
      } + (
        if waitPath != null
        then { SecondsPath: waitPath }
        else { Seconds: waitSec }
      ) + { Next: 'Check_' + name },

      ['Check_' + name]: $.task(lambdaArn, 'Verify_' + name, failState),

      ['Verify_' + name]: {
        Type: 'Choice',
        Choices: [
          { Variable: finVar, BooleanEquals: true, Next: doneNext },
          { Variable: finVar, BooleanEquals: false, Next: 'Wait_' + name },
        ],
        Default: failState,
      },
    },

  // ── Poll loop with success check ──────────────────────────────────────────
  // Like pollLoop but also checks $.success == false → fail immediately.
  // Matches the pattern: if failed → finalize, if finished → finalize,
  // if not finished → keep waiting.
  pollLoopWithFinalize(name, lambdaArn, finalizeState, opts={})::
    local waitSec = if std.objectHas(opts, 'waitSeconds') then opts.waitSeconds else 30;
    local waitPath = if std.objectHas(opts, 'waitSecondsPath') then opts.waitSecondsPath else null;
    local failState = if std.objectHas(opts, 'failState') then opts.failState else 'Common_OperationFailed';
    {
      ['Wait_' + name]: {
        Type: 'Wait',
      } + (
        if waitPath != null
        then { SecondsPath: waitPath }
        else { Seconds: waitSec }
      ) + { Next: 'Check_' + name },

      ['Check_' + name]: $.task(lambdaArn, 'Verify_' + name, failState),

      ['Verify_' + name]: {
        Type: 'Choice',
        Choices: [
          { Variable: '$.success', BooleanEquals: false, Next: finalizeState },
          { Variable: '$.finished', BooleanEquals: true, Next: finalizeState },
          { Variable: '$.finished', BooleanEquals: false, Next: 'Wait_' + name },
        ],
        Default: failState,
      },
    },

  // ── Timed start ───────────────────────────────────────────────────────────
  // Optional delayed start: if $.start_time is a timestamp, wait until then.
  // Otherwise proceed immediately. Seen in tenant create, snapshot, migrate.
  //
  //   sfn.timedStart('TenantCreate', 'Start_TenantCreate')
  timedStart(name, nextState):: {
    ['Check_' + name + 'Timings']: {
      Type: 'Choice',
      Choices: [
        { Variable: '$.start_time', IsTimestamp: true, Next: 'Wait_Start' + name },
      ],
      Default: nextState,
    },
    ['Wait_Start' + name]: {
      Type: 'Wait',
      TimestampPath: '$.start_time',
      Next: nextState,
    },
  },

  // ── Step loop ─────────────────────────────────────────────────────────────
  // Action → Wait → Check → Choice (finished/continue/wait).
  // For multi-step operations where the Lambda returns which step comes next.
  //
  //   sfn.stepLoop('TenantCreate', arn, {
  //     failState: 'Perform_TenantCreateFailed',
  //   })
  stepLoop(name, lambdaArn, opts={})::
    local waitPath = if std.objectHas(opts, 'waitSecondsPath') then opts.waitSecondsPath else '$.wait_time';
    local doneNext = if std.objectHas(opts, 'doneNext') then opts.doneNext else 'Common_OperationSucceeded';
    local failState = if std.objectHas(opts, 'failState') then opts.failState else 'Common_OperationFailed';
    local failHandler = if std.objectHas(opts, 'failHandler') then opts.failHandler else null;
    {
      [name + 'StepAction']: $.task(lambdaArn, 'Wait_' + name + 'StepStatus', failState=if failHandler != null then failHandler else failState),

      ['Wait_' + name + 'StepStatus']: {
        Type: 'Wait',
        SecondsPath: waitPath,
        Next: 'Check_' + name + 'StepStatus',
      },

      ['Check_' + name + 'StepStatus']: $.task(lambdaArn, 'Verify_' + name + 'StepStatus', failState=if failHandler != null then failHandler else failState),

      ['Verify_' + name + 'StepStatus']: {
        Type: 'Choice',
        Choices: [
          { Variable: '$.finished', BooleanEquals: true, Next: doneNext },
          { Variable: '$.continue', BooleanEquals: true, Next: name + 'StepAction' },
          { Variable: '$.continue', BooleanEquals: false, Next: 'Wait_' + name + 'StepStatus' },
        ],
        Default: if failHandler != null then failHandler else failState,
      },
    }
    + (if failHandler != null then {
         [failHandler]: $.task(lambdaArn, failState),
       } else {}),

  // ── Map state ─────────────────────────────────────────────────────────────
  // Parallel iteration over a list with bounded concurrency.
  //
  //   sfn.mapState('ProcessTenants', {
  //     itemsPath: '$.input.tenant_list',
  //     lambdaArn: arn,
  //     maxConcurrency: 10,
  //     parameters: {
  //       'Tenant.$': '$$.Map.Item.Value',
  //       'Event.$': '$',
  //     },
  //     next: 'StatusCheck',
  //     failState: 'Failed',
  //   })
  mapState(name, opts)::
    local failState = if std.objectHas(opts, 'failState') then opts.failState else 'Common_OperationFailed';
    {
      [name]: {
        Type: 'Map',
        ItemsPath: opts.itemsPath,
        InputPath: '$',
        ResultPath: '$.lambdaResult',
        MaxConcurrency: if std.objectHas(opts, 'maxConcurrency') then opts.maxConcurrency else 10,
        Next: opts.next,
        Parameters: opts.parameters,
        Iterator: {
          StartAt: name + 'Action',
          States: {
            [name + 'Action']: $.task(opts.lambdaArn, '', end=true),
          },
        },
        Retry: $.retry(),
        Catch: $.catch(failState),
      },
    },

  // ── Choice dispatcher ─────────────────────────────────────────────────────
  // Routes to different sub-workflows based on an input variable.
  // Each entry is { value: 'ActionName', next: 'FirstState' }.
  //
  //   sfn.dispatcher('Common_Start', '$.action', [
  //     { value: 'CreateTenant', next: 'Check_TenantCreateTimings' },
  //     { value: 'DeleteTenant', next: 'Start_DeleteTenant' },
  //   ])
  dispatcher(name, variable, routes, failState='Common_OperationFailed'):: {
    [name]: {
      Type: 'Choice',
      Choices: [
        { Variable: variable, StringEquals: r.value, Next: r.next }
        for r in routes
      ],
      Default: failState,
    },
  },

  // ── Terminal states ───────────────────────────────────────────────────────
  succeeded(name='Common_OperationSucceeded'):: { [name]: { Type: 'Succeed' } },
  failed(name='Common_OperationFailed'):: { [name]: { Type: 'Fail' } },

  // ── State machine resource ────────────────────────────────────────────────
  // Wraps the definition into an AWS::StepFunctions::StateMachine resource.
  //
  // substitutions maps placeholder names to CFN intrinsics. The definition
  // uses plain string placeholders like '${SupervisorArn}' and CFN resolves
  // them at deploy time via DefinitionSubstitutions.
  //
  //   sfn.stateMachine('my-sm', roleArn, definition, substitutions={
  //     SupervisorArn: cfn.getArn('SupervisorFunction'),
  //   })
  stateMachine(name, roleArn, definition, substitutions={}, tags=[]):: {
    Type: 'AWS::StepFunctions::StateMachine',
    Properties: {
      StateMachineName: name,
      RoleArn: roleArn,
      DefinitionString: std.manifestJsonEx(definition, '  '),
    }
    + (if substitutions != {} then { DefinitionSubstitutions: substitutions } else {})
    + (if tags != [] then { Tags: tags } else {}),
  },
}
