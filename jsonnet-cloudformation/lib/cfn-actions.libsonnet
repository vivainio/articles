// cfn-actions.libsonnet — Common IAM action groups for composing policies.
//
// Usage:
//   local actions = import 'lib/cfn-actions.libsonnet';
//   cfn.allow(actions.ddbRead + actions.ddbWrite, resource)

{
  // ── DynamoDB ──────────────────────────────────────────────────────────────
  ddbRead: ['dynamodb:GetItem', 'dynamodb:Query', 'dynamodb:Scan', 'dynamodb:BatchGetItem'],
  ddbWrite: ['dynamodb:PutItem', 'dynamodb:UpdateItem', 'dynamodb:DeleteItem', 'dynamodb:BatchWriteItem'],
  ddbAll: self.ddbRead + self.ddbWrite,

  // ── SQS ───────────────────────────────────────────────────────────────────
  sqsConsume: ['sqs:ReceiveMessage', 'sqs:DeleteMessage', 'sqs:GetQueueAttributes'],
  sqsSend: ['sqs:SendMessage', 'sqs:GetQueueUrl'],

  // ── S3 ────────────────────────────────────────────────────────────────────
  s3Read: ['s3:GetObject', 's3:HeadObject'],
  s3Write: ['s3:PutObject', 's3:DeleteObject'],
  s3List: ['s3:ListBucket'],

  // ── SNS ───────────────────────────────────────────────────────────────────
  snsPublish: ['sns:Publish'],

  // ── Lambda ────────────────────────────────────────────────────────────────
  lambdaInvoke: ['lambda:InvokeFunction'],

  // ── SSM Parameter Store ───────────────────────────────────────────────────
  ssmRead: ['ssm:GetParameter', 'ssm:GetParameters', 'ssm:GetParametersByPath'],

  // ── Secrets Manager ───────────────────────────────────────────────────────
  secretsRead: ['secretsmanager:GetSecretValue'],

  // ── KMS ───────────────────────────────────────────────────────────────────
  kmsDecrypt: ['kms:Decrypt', 'kms:GenerateDataKey'],

  // ── EC2 / VPC (for Lambda in VPC) ─────────────────────────────────────────
  ec2Eni: ['ec2:CreateNetworkInterface', 'ec2:DescribeNetworkInterfaces', 'ec2:DeleteNetworkInterface'],
}
