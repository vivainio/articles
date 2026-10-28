"""SQS consumer with a dead-letter queue — the Python twin of sqs-worker.jsonnet."""

import json
import sys

import cfn
from cfn import Resources, Template

service = "order-processor"
stage = sys.argv[1] if len(sys.argv) > 1 else "dev"

t = cfn.tags(Service=service, Stage=stage)

resources: Resources = {
    "ExecutionRole": cfn.lambda_role(f"{service}-{stage}", [
        cfn.allow(cfn.SQS_CONSUME, [cfn.get_att("OrderQueue", "Arn")]),
        cfn.allow(cfn.DDB_WRITE, cfn.arn("dynamodb", f"table/orders-{stage}")),
    ]),
    "Processor": cfn.function({
        "FunctionName": f"{service}-{stage}-processor",
        "Handler": "src/processor.handler",
        "Runtime": "nodejs20.x",
        "Role": cfn.get_att("ExecutionRole", "Arn"),
        "Code": {"S3Bucket": "deploy-artifacts", "S3Key": f"{service}/{stage}/package.zip"},
        "MemorySize": 256,
        "Timeout": 30,
        "Environment": {"Variables": {"STAGE": stage, "TABLE_NAME": f"orders-{stage}"}},
        "ReservedConcurrentExecutions": 5,
        "Tags": t,
    }),
    "ProcessorEventSourceMapping": cfn.sqs_event_source("Processor", cfn.get_att("OrderQueue", "Arn")),
    "OrderDLQ": cfn.queue(tags=t),
    "OrderQueue": cfn.queue(
        visibility_timeout=180,
        dlq_arn=cfn.get_att("OrderDLQ", "Arn"),
        tags=t,
    ),
}

template: Template = {
    "AWSTemplateFormatVersion": "2010-09-09",
    "Resources": resources,
    "Outputs": {
        "QueueUrl": {"Value": cfn.ref("OrderQueue")},
        "DLQUrl": {"Value": cfn.ref("OrderDLQ")},
    },
}

print(json.dumps(template, indent=2))
