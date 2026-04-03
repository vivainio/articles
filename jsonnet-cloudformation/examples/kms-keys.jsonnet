// Example: Customer-managed KMS keys for S3, RDS, and DynamoDB
//
// Creates three encryption keys with service-specific policies,
// conditional cross-account access for a partner, and SSM parameter exports.
//
// The equivalent CDK would use kms.Key with custom PolicyDocuments
// and helper methods for each key policy — about 300 lines of
// TypeScript with class methods. Here the policy fragments are
// plain local functions that return JSON objects.

local cfn = import '../lib/cfn.libsonnet';

local stage = std.extVar('stage');
local service = 'my-app';

local hasPartner = cfn.condition('HasPartner', cfn.notEquals(cfn.ref('PartnerAccountId'), ''));

// ── Reusable policy fragments ──────────────────────────────────────────

local rootAccess = {
  Sid: 'EnableIAMUserPermissions',
  Effect: 'Allow',
  Principal: { AWS: cfn.sub('arn:aws:iam::${AWS::AccountId}:root') },
  Action: 'kms:*',
  Resource: '*',
};

local serviceAccess(svc, withGrants=false) = {
  Sid: 'Allow' + svc + 'Service',
  Effect: 'Allow',
  Principal: { Service: svc + '.amazonaws.com' },
  Action: ['kms:Decrypt', 'kms:GenerateDataKey', 'kms:ReEncrypt*', 'kms:DescribeKey']
          + (if withGrants then ['kms:CreateGrant', 'kms:RetireGrant'] else []),
  Resource: '*',
};

local lambdaViaService(svc, actions) = {
  Sid: 'AllowLambdaVia' + svc,
  Effect: 'Allow',
  Principal: { Service: 'lambda.amazonaws.com' },
  Action: actions,
  Resource: '*',
  Condition: {
    StringEquals: {
      'kms:ViaService': [cfn.sub(svc + '.${AWS::Region}.amazonaws.com')],
    },
  },
};

// ── Resource builders ──────────────────────────────────────────────────

local kmsKey(alias, description, policy) = {
  Type: 'AWS::KMS::Key',
  DeletionPolicy: 'Retain',
  UpdateReplacePolicy: 'Retain',
  Properties: {
    Description: description,
    EnableKeyRotation: true,
    KeyPolicy: { Version: '2012-10-17', Statement: policy },
  },
};

local kmsAlias(alias, keyLogical) = {
  Type: 'AWS::KMS::Alias',
  Properties: {
    AliasName: 'alias/' + alias,
    TargetKeyId: cfn.ref(keyLogical),
  },
};

local exportKey(keyType, keyLogical) = {
  [keyType + 'KeyArnParam']: cfn.ssmOutput(
    '/' + service + '/' + stage + '/kms/' + keyType + '-key-arn',
    cfn.getArn(keyLogical),
  ),
  [keyType + 'KeyIdParam']: cfn.ssmOutput(
    '/' + service + '/' + stage + '/kms/' + keyType + '-key-id',
    cfn.getAtt(keyLogical, 'KeyId'),
  ),
};

// S3 key gets two possible policies: with or without partner access.
// Fn::If selects the right one at deploy time.
local s3BasePolicy = [
  rootAccess,
  serviceAccess('s3'),
  {
    Sid: 'AllowCloudFrontDecrypt',
    Effect: 'Allow',
    Principal: { Service: 'cloudfront.amazonaws.com' },
    Action: ['kms:Decrypt', 'kms:DescribeKey'],
    Resource: '*',
  },
  lambdaViaService('s3', ['kms:Decrypt', 'kms:GenerateDataKey', 'kms:ReEncrypt*', 'kms:DescribeKey']),
];

local partnerStatement = cfn.allow(
  ['kms:Decrypt', 'kms:DescribeKey'],
  '*',
  condition={ StringEquals: { 'kms:ViaService': [cfn.sub('s3.${AWS::Region}.amazonaws.com')] } },
) + { Sid: 'AllowPartnerDecrypt', Principal: { AWS: cfn.ref('PartnerAccountId') } };

// ── Template ───────────────────────────────────────────────────────────

{
  AWSTemplateFormatVersion: '2010-09-09',
  Description: 'Customer-managed KMS keys for ' + service + ' (' + stage + ')',

  Parameters: {
    PartnerAccountId: cfn.param(
      default='',
      description='Partner account ID for cross-account S3 decryption',
    ),
  },

  Conditions: hasPartner.def,

  Resources: {
               // S3 key — Fn::If swaps the policy to include partner access when provided
               S3Key: kmsKey(
                 service + '-s3-' + stage,
                 'S3 encryption key',
                 hasPartner.pick(s3BasePolicy + [partnerStatement], s3BasePolicy),
               ),
               S3KeyAlias: kmsAlias(service + '-s3-' + stage, 'S3Key'),

               // Database key — RDS needs grant actions for envelope encryption
               DatabaseKey: kmsKey(service + '-db-' + stage, 'Database encryption key', [
                 rootAccess,
                 serviceAccess('rds', withGrants=true),
                 lambdaViaService('rds', ['kms:Decrypt', 'kms:DescribeKey']),
               ]),
               DatabaseKeyAlias: kmsAlias(service + '-db-' + stage, 'DatabaseKey'),

               // DynamoDB key — also needs grant actions
               DynamoDbKey: kmsKey(service + '-ddb-' + stage, 'DynamoDB encryption key', [
                 rootAccess,
                 serviceAccess('dynamodb', withGrants=true),
                 lambdaViaService('dynamodb', ['kms:Decrypt', 'kms:GenerateDataKey', 'kms:DescribeKey']),
               ]),
               DynamoDbKeyAlias: kmsAlias(service + '-ddb-' + stage, 'DynamoDbKey'),
             }
             + exportKey('s3', 'S3Key')
             + exportKey('database', 'DatabaseKey')
             + exportKey('dynamodb', 'DynamoDbKey'),

  Outputs: {
    S3KeyArn: cfn.output(cfn.getArn('S3Key')),
    DatabaseKeyArn: cfn.output(cfn.getArn('DatabaseKey')),
    DynamoDbKeyArn: cfn.output(cfn.getArn('DynamoDbKey')),
  },
}
