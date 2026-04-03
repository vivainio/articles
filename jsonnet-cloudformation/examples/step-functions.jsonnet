// Example: Step Functions state machine with reusable patterns
//
// A real-world operations supervisor state machine typically has 15+
// action types and 60+ states where the same retry/catch block is
// copy-pasted 40+ times. Jsonnet eliminates that repetition.
//
// Patterns demonstrated:
//
// 1. sfn.task()       — Task state with standard retry + catch-all
// 2. sfn.pollLoop()   — Wait → Check → Verify (finished? loop : done)
// 3. sfn.timedStart() — Optional delayed start via $.start_time
// 4. sfn.stepLoop()   — Multi-step: Action → Wait → Check → (continue/done)
// 5. sfn.mapState()   — Parallel iteration with bounded concurrency
// 6. sfn.dispatcher() — Choice state routing to sub-workflows
//
// The YAML equivalent has each retry block listing 7 error types × 4 fields
// on every Task state. Here, sfn.task() applies them once.

local aws = import '../lib/aws.libsonnet';
local cfn = import '../lib/cfn.libsonnet';
local sfn = import '../lib/sfn.libsonnet';

local service = 'fleet-ops';
local stage = std.extVar('stage');
local prefix = service + '-' + stage;

// The supervisor Lambda handles all state machine callbacks.
// Inside the definition, use a plain placeholder — CFN resolves it
// at deploy time via DefinitionSubstitutions.
local supervisorArn = '${SupervisorArn}';

// ── Sub-workflows ──────────────────────────────────────────────────────────
// Each returns a { StateName: StateDefinition, ... } object for merging.

// Simple poll: wait, check, loop until $.finished == true.
// Handles: upgrade status, health checks, deployment rollouts.
local upgradeStatus = sfn.pollLoop('UpgradeStatus', supervisorArn, {
  waitSeconds: 60,
});

local healthCheck = sfn.pollLoop('HealthCheck', supervisorArn, {
  waitSeconds: 10,
});

// Two-phase pipeline: poll phase 1, then poll phase 2 with longer interval.
local dataPipeline =
  sfn.pollLoop('DataExport', supervisorArn, {
    waitSeconds: 90,
    finishedVar: '$.export_finished',
    doneNext: 'Wait_DataLoad',
  })
  + sfn.pollLoop('DataLoad', supervisorArn, {
    waitSeconds: 300,
    finishedVar: '$.load_finished',
  });

// Poll with finalize step: check $.success and $.finished, route to
// a finalize Lambda call before succeeding or failing.
local resourceCleanup = sfn.pollLoopWithFinalize(
  'Cleanup', supervisorArn, 'Finalize_Cleanup', { waitSeconds: 15 }
) + {
  Finalize_Cleanup: sfn.task(supervisorArn, 'Common_OperationSucceeded', 'Common_OperationFailed'),
};

// Timed start + step loop: optionally wait until start_time, then
// run a multi-step sequence where the Lambda controls progression.
local provisionNode =
  sfn.timedStart('Provision', 'Start_Provision')
  + {
    Start_Provision: {
      Type: 'Choice',
      Choices: [
        { Variable: '$.step', StringEquals: 'precheck', Next: 'Wait_ProvisionStart' },
      ],
      Default: 'Common_OperationFailed',
    },
    Wait_ProvisionStart: {
      Type: 'Wait',
      SecondsPath: '$.wait_time',
      Next: 'ProvisionStepAction',
    },
  }
  + sfn.stepLoop('Provision', supervisorArn, {
    failHandler: 'Perform_ProvisionFailed',
    failState: 'Common_OperationFailed',
  });

// Snapshot: timed start + presteps poll + create + finalize
local snapshot =
  sfn.timedStart('Snapshot', 'Start_Snapshot')
  + {
    Start_Snapshot: {
      Type: 'Choice',
      Choices: [
        { Variable: '$.step', StringEquals: 'presteps', Next: 'Presteps_Snapshot' },
      ],
      Default: 'Common_OperationFailed',
    },
    Presteps_Snapshot: sfn.task(supervisorArn, 'Wait_SnapshotPresteps', 'Perform_SnapshotFailed'),
  }
  + sfn.pollLoop('SnapshotPresteps', supervisorArn, {
    waitSecondsPath: '$.wait_time',
    finishedVar: '$.continue',
    doneNext: 'Create_Snapshot',
    failState: 'Perform_SnapshotFailed',
  })
  + {
    Create_Snapshot: sfn.task(supervisorArn, 'Wait_SnapshotStatus', 'Perform_SnapshotFailed'),
  }
  + sfn.pollLoop('SnapshotStatus', supervisorArn, {
    waitSecondsPath: '$.wait_time',
    finishedVar: '$.continue',
    doneNext: 'Finalize_Snapshot',
    failState: 'Perform_SnapshotFailed',
  })
  + {
    Finalize_Snapshot: sfn.task(supervisorArn, 'Poststeps_Snapshot', 'Perform_SnapshotFailed'),
    Poststeps_Snapshot: sfn.task(supervisorArn, 'Verify_SnapshotFinal', 'Perform_SnapshotFailed'),
    Verify_SnapshotFinal: {
      Type: 'Choice',
      Choices: [
        { Variable: '$.success', BooleanEquals: true, Next: 'Common_OperationSucceeded' },
        { Variable: '$.success', BooleanEquals: false, Next: 'Common_OperationFailed' },
      ],
      Default: 'Common_OperationFailed',
    },
    Perform_SnapshotFailed: sfn.task(supervisorArn, 'Common_OperationFailed'),
  };

// Batch operation: fetch items → Map over them in parallel → verify.
local batchMaintenance = {
                           Start_BatchMaintenance: sfn.task(supervisorArn, 'FetchItems_BatchMaintenance', 'Common_OperationFailed'),
                           FetchItems_BatchMaintenance: sfn.task(supervisorArn, 'ProcessItems_BatchMaintenance', 'Common_OperationFailed'),
                         }
                         + sfn.mapState('ProcessItems_BatchMaintenance', {
                           itemsPath: '$.input.item_list',
                           lambdaArn: supervisorArn,
                           maxConcurrency: 10,
                           parameters: {
                             'Item.$': '$$.Map.Item.Value',
                             'Event.$': '$',
                           },
                           next: 'StatusCheck_BatchMaintenance',
                           failState: 'Common_OperationFailed',
                         })
                         + {
                           StatusCheck_BatchMaintenance: sfn.task(supervisorArn, 'ScaleDown_BatchMaintenance', 'Common_OperationFailed'),
                           ScaleDown_BatchMaintenance: sfn.task(supervisorArn, 'Wait_ScaleDownCheck', 'Common_OperationFailed'),
                         }
                         + sfn.pollLoop('ScaleDownCheck', supervisorArn, {
                           waitSeconds: 120,
                           finishedVar: '$.ready_to_proceed',
                         });

// Scale down: start → detach → monitor loop
local scaleDown = {
                    Start_ScaleDown: sfn.task(supervisorArn, 'Detach_ScaleDown', 'Common_OperationFailed'),
                    Detach_ScaleDown: sfn.task(supervisorArn, 'Wait_ScaleDown', 'Common_OperationFailed'),
                  }
                  + sfn.pollLoop('ScaleDown', supervisorArn, {
                    waitSeconds: 300,
                    finishedVar: '$.finished',
                  });

// ── Assemble the state machine ─────────────────────────────────────────────

local definition = {
  Comment: 'Fleet operations supervisor — dispatches to sub-workflows',
  StartAt: 'Dispatcher',
  States:
    // Route by $.action to the right sub-workflow
    sfn.dispatcher('Dispatcher', '$.action', [
      { value: 'UpgradeStatus', next: 'Wait_UpgradeStatus' },
      { value: 'HealthCheck', next: 'Wait_HealthCheck' },
      { value: 'DataPipeline', next: 'Wait_DataExport' },
      { value: 'Snapshot', next: 'Check_SnapshotTimings' },
      { value: 'Cleanup', next: 'Wait_Cleanup' },
      { value: 'Provision', next: 'Check_ProvisionTimings' },
      { value: 'BatchMaintenance', next: 'Start_BatchMaintenance' },
      { value: 'ScaleDown', next: 'Start_ScaleDown' },
    ])

    // Merge all sub-workflow states
    + upgradeStatus
    + healthCheck
    + dataPipeline
    + resourceCleanup
    + provisionNode
    + snapshot
    + batchMaintenance
    + scaleDown

    // Terminal states
    + sfn.succeeded()
    + sfn.failed(),
};

// ── CloudFormation template ────────────────────────────────────────────────

local tags = cfn.tags({ Service: service, Stage: stage });

local supervisor = aws.lambda('Supervisor', {
  FunctionName: prefix + '-supervisor',
  Handler: 'supervisor.handler',
  Code: { S3Bucket: 'deploy-artifacts', S3Key: service + '/' + stage + '/package.zip' },
  Role: cfn.getArn('SupervisorRole'),
  MemorySize: 1536,
  Timeout: 900,
});

{
  AWSTemplateFormatVersion: '2010-09-09',
  Description: service + ' (' + stage + ') — Step Functions operations supervisor',

  Resources:
    supervisor.resources
    {
      SupervisorRole: aws.lambdaRole(prefix, [
        cfn.allow(['states:StartExecution'], cfn.arn('states', 'stateMachine:' + prefix + '-statemachine')),
        cfn.allow(['states:StopExecution'], cfn.arn('states', 'execution:' + prefix + '-statemachine:*')),
        cfn.allow(['lambda:InvokeFunction'], cfn.arn('lambda', 'function:' + prefix + '-*')),
      ]),

      StateMachineRole: aws.serviceRole('states.amazonaws.com', [
        cfn.allow(['lambda:InvokeFunction'], cfn.getArn('SupervisorFunction')),
      ]),

      SupervisorStateMachine: sfn.stateMachine(
        prefix + '-statemachine',
        cfn.getArn('StateMachineRole'),
        definition,
        substitutions={ SupervisorArn: cfn.getArn('SupervisorFunction') },
        tags=tags,
      ),

      // Log subscription forwarding to a central log aggregator
      SupervisorLogForward: supervisor.logSubscription(
        cfn.arn('logs', 'destination:central-logs')
      ),
    },

  Outputs: {
    StateMachineArn: cfn.output(cfn.ref('SupervisorStateMachine')),
  },
}
