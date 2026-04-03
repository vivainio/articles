// cfn.libsonnet — General-purpose CloudFormation helpers.
//
// Intrinsic function shorthands, IAM policy builders, parameter/output
// helpers, and tag conversion. These are not serverless-specific — see
// sls.libsonnet for Lambda, API Gateway, and deployment bucket resources.
//
// Usage:
//   local cfn = import 'lib/cfn.libsonnet';
//   cfn.allow(actions.ddbRead, cfn.arn('dynamodb', 'table/my-table-dev'))

{
  // ── Intrinsic function shorthands ─────────────────────────────────────────
  getAtt(logical, attr):: { 'Fn::GetAtt': [logical, attr] },
  getArn(logical):: { 'Fn::GetAtt': [logical, 'Arn'] },
  sub(str):: { 'Fn::Sub': str },
  ref(logical):: { Ref: logical },

  // ── ARN builder ────────────────────────────────────────────────────────────
  // Same-account, same-region ARN. Expands partition, region, and account ID.
  arn(service, resource):: { 'Fn::Sub': 'arn:${AWS::Partition}:' + service + ':${AWS::Region}:${AWS::AccountId}:' + resource },

  // ── IAM policy shorthands ──────────────────────────────────────────────────
  allow(actions, resource, condition=null)::
    { Effect: 'Allow', Action: actions, Resource: resource }
    + (if condition != null then { Condition: condition } else {}),

  deny(actions, resource, condition=null)::
    { Effect: 'Deny', Action: actions, Resource: resource }
    + (if condition != null then { Condition: condition } else {}),

  policies(statements):: [{ Version: '2012-10-17', Statement: statements }],

  // ── Parameter shorthands ───────────────────────────────────────────────────
  param(type='String', default=null, description=null, allowed=null)::
    { Type: type }
    + (if default != null then { Default: default } else {})
    + (if description != null then { Description: description } else {})
    + (if allowed != null then { AllowedValues: allowed } else {}),

  ssmParam(path, description=null)::
    { Type: 'AWS::SSM::Parameter::Value<String>', Default: path }
    + (if description != null then { Description: description } else {}),

  // ── Output shorthands ──────────────────────────────────────────────────────
  output(value):: { Value: value },
  exportOutput(value, name):: { Value: value, Export: { Name: name } },

  // ── SSM Parameter output ────────────────────────────────────────────────
  // Creates an SSM Parameter resource to export a value for other stacks.
  ssmOutput(name, value, description=null):: {
    Type: 'AWS::SSM::Parameter',
    Properties: {
      Name: name,
      Type: 'String',
      Value: value,
    } + (if description != null then { Description: description } else {}),
  },

  // ── Tags ───────────────────────────────────────────────────────────────────
  // Convert { Key: Value } object to CFN Tags array format.
  tags(obj):: [{ Key: k, Value: obj[k] } for k in std.objectFields(obj)],
}
