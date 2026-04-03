// Example: S3 bucket locked with a deny-all-except bucket policy
//
// A common production pattern: create a KMS-encrypted S3 bucket that
// denies all access *except* to a whitelist of IAM roles. Each role
// needs two ARN forms (iam::role/ and sts::assumed-role/) and the
// same region/stage suffix, so the YAML original repeats the same
// !Sub block ~10 times. Jsonnet computes both forms from a single list.
//
// Patterns demonstrated:
//
// 1. Deny-all-except bucket policy built from a role whitelist
// 2. Dual-ARN expansion (iam role + sts assumed-role) via array comprehension
// 3. KMS key + alias + SSM parameter triplet as a reusable local
// 4. cfn.ssmOutput() for cross-stack sharing via SSM Parameter Store
// 5. DeletionPolicy/UpdateReplacePolicy on stateful resources

local cfn = import '../lib/cfn.libsonnet';

local service = 'data-lake';
local stage = std.extVar('stage');
local prefix = service + '-' + stage;

// ── Role whitelist ─────────────────────────────────────────────────────────
// In the YAML original each role appears twice (iam::role/ for the
// principal, sts::assumed-role/ for the session) with the same Sub
// block copy-pasted. Here we list each role once and expand both forms.

local roleSuffix = stage;

// Roles that need bucket access — just the name portion.
local allowedRoles = [
  'DataLake-ReadOnlyRole-' + roleSuffix,
  'DataLake-ReadWriteRole-' + roleSuffix,
  'DataLake-ECSTaskRole-' + roleSuffix,
];

// Static roles that don't carry the region/stage suffix.
local staticRoles = [
  'cicd-deploy-role',
];

// Expand each role name into both ARN forms that the bucket policy needs.
local roleArn(name) = cfn.sub('arn:${AWS::Partition}:iam::${AWS::AccountId}:role/' + name);
local sessionArn(name) = cfn.sub('arn:${AWS::Partition}:sts::${AWS::AccountId}:assumed-role/' + name + '/*');

local allRoleArns =
  [roleArn(r) for r in allowedRoles + staticRoles]
  + [sessionArn(r) for r in allowedRoles + staticRoles];

// Also allow SSO admin roles (wildcard).
local ssoAdminPatterns = [
  cfn.sub('arn:${AWS::Partition}:iam::${AWS::AccountId}:role/aws-reserved/sso.amazonaws.com/*/AWSReservedSSO_Admin_*'),
  cfn.sub('arn:${AWS::Partition}:sts::${AWS::AccountId}:assumed-role/aws-reserved/sso.amazonaws.com/*/AWSReservedSSO_Admin_*'),
];

local allPrincipalArns = allRoleArns + ssoAdminPatterns;

// ── Tags ───────────────────────────────────────────────────────────────────

local tags(role) = cfn.tags({ Service: service, Stage: stage, Role: role });

// ── KMS key + alias + SSM parameter ────────────────────────────────────────
// A common triplet: create a key, give it a human-readable alias,
// then publish the ARN to Parameter Store for other stacks to import.

local kmsResources = {
  BucketKey: {
    Type: 'AWS::KMS::Key',
    DeletionPolicy: 'Retain',
    UpdateReplacePolicy: 'Retain',
    Properties: {
      Description: prefix + ' bucket encryption key',
      KeyPolicy: {
        Version: '2012-10-17',
        Statement: [{
          Sid: 'AllowKeyAdministration',
          Effect: 'Allow',
          Principal: { AWS: cfn.sub('arn:${AWS::Partition}:iam::${AWS::AccountId}:root') },
          Action: ['kms:*'],
          Resource: '*',
        }],
      },
      Tags: tags('Encryption'),
    },
  },
  BucketKeyAlias: {
    Type: 'AWS::KMS::Alias',
    DeletionPolicy: 'Retain',
    UpdateReplacePolicy: 'Retain',
    Properties: {
      AliasName: 'alias/' + prefix + '/bucket-key',
      TargetKeyId: cfn.ref('BucketKey'),
    },
  },
  BucketKeyArnParam: cfn.ssmOutput(
    '/' + service + '/' + stage + '/BucketKmsKeyArn',
    cfn.getAtt('BucketKey', 'Arn'),
    description=prefix + ' bucket KMS key ARN',
  ),
};

// ── Bucket + policy ────────────────────────────────────────────────────────

local bucketName = prefix + '-store';

local bucketResources = {
  Bucket: {
    Type: 'AWS::S3::Bucket',
    DeletionPolicy: 'Retain',
    UpdateReplacePolicy: 'Retain',
    Properties: {
      BucketName: bucketName,
      PublicAccessBlockConfiguration: {
        BlockPublicAcls: true,
        BlockPublicPolicy: true,
        IgnorePublicAcls: true,
        RestrictPublicBuckets: true,
      },
      BucketEncryption: {
        ServerSideEncryptionConfiguration: [{
          ServerSideEncryptionByDefault: {
            SSEAlgorithm: 'aws:kms',
            KMSMasterKeyID: cfn.ref('BucketKeyAlias'),
          },
          BucketKeyEnabled: true,
        }],
      },
      Tags: tags('DataStore'),
    },
  },

  BucketNameParam: cfn.ssmOutput(
    '/' + service + '/' + stage + '/BucketName',
    cfn.ref('Bucket'),
  ),

  BucketPolicy: {
    Type: 'AWS::S3::BucketPolicy',
    DeletionPolicy: 'Retain',
    UpdateReplacePolicy: 'Retain',
    Properties: {
      Bucket: cfn.ref('Bucket'),
      PolicyDocument: {
        Statement: [
          // Deny everything except the whitelisted roles.
          // This is the pattern that explodes to ~30 lines of ARNs
          // in raw YAML — here it's computed from the role list above.
          {
            Sid: 'DenyAllExceptWhitelisted',
            Effect: 'Deny',
            Action: 's3:*',
            Principal: '*',
            Resource: [
              cfn.sub('arn:${AWS::Partition}:s3:::' + bucketName),
              cfn.sub('arn:${AWS::Partition}:s3:::' + bucketName + '/*'),
            ],
            Condition: {
              StringNotLike: {
                'aws:PrincipalArn': allPrincipalArns,
              },
            },
          },
          // Deny non-TLS access
          {
            Sid: 'DenyNonTLS',
            Effect: 'Deny',
            Principal: '*',
            Action: 's3:*',
            Resource: cfn.sub('arn:${AWS::Partition}:s3:::' + bucketName + '/*'),
            Condition: { Bool: { 'aws:SecureTransport': 'false' } },
          },
        ],
      },
    },
  },
};

// ── Template ───────────────────────────────────────────────────────────────

{
  AWSTemplateFormatVersion: '2010-09-09',
  Description: prefix + ' — KMS-encrypted bucket with deny-all-except policy',

  Resources: kmsResources + bucketResources,

  Outputs: {
    BucketName: cfn.exportOutput(cfn.ref('Bucket'), prefix + '-BucketName'),
    BucketKeyAlias: cfn.exportOutput(cfn.ref('BucketKeyAlias'), prefix + '-BucketKeyAlias'),
    BucketKeyArn: cfn.exportOutput(cfn.ref('BucketKey'), prefix + '-BucketKeyArn'),
  },
}
