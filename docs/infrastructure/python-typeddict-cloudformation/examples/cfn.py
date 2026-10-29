"""cfn.py — CloudFormation as typed Python dicts.

Every helper returns plain dicts. TypedDicts describe their shape for the
type checker only; at runtime they are ordinary dicts, so json.dumps works
directly.
"""

from typing import Any, NotRequired, TypedDict, Unpack

# ── Intrinsic functions ──────────────────────────────────────────────────────
# "Fn::GetAtt" is not a valid identifier, so these use the functional syntax.
Ref = TypedDict("Ref", {"Ref": str})
GetAtt = TypedDict("GetAtt", {"Fn::GetAtt": list[str]})
Sub = TypedDict("Sub", {"Fn::Sub": str})

Value = str | int | Ref | GetAtt | Sub  # anything allowed where a scalar goes


def ref(logical: str) -> Ref:
    return {"Ref": logical}


def get_att(logical: str, attr: str) -> GetAtt:
    return {"Fn::GetAtt": [logical, attr]}


def arn(service: str, resource: str) -> Sub:
    return {"Fn::Sub": f"arn:${{AWS::Partition}}:{service}:${{AWS::Region}}:${{AWS::AccountId}}:{resource}"}


# ── IAM ──────────────────────────────────────────────────────────────────────
class Statement(TypedDict):
    Effect: str
    Action: list[str]
    Resource: Value | list[Value]


def allow(actions: list[str], resource: Value | list[Value]) -> Statement:
    return {"Effect": "Allow", "Action": actions, "Resource": resource}


SQS_CONSUME = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes"]
DDB_WRITE = ["dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:DeleteItem"]


# ── Resources ────────────────────────────────────────────────────────────────
class Tag(TypedDict):
    Key: str
    Value: str


def tags(**kv: str) -> list[Tag]:
    return [{"Key": k, "Value": v} for k, v in kv.items()]


class RedrivePolicy(TypedDict):
    deadLetterTargetArn: Value
    maxReceiveCount: int


class QueueProps(TypedDict):
    VisibilityTimeout: int
    RedrivePolicy: NotRequired[RedrivePolicy]
    Tags: NotRequired[list[Tag]]


class Queue(TypedDict):
    Type: str  # "AWS::SQS::Queue"
    Properties: QueueProps


class RoleProps(TypedDict):
    AssumeRolePolicyDocument: dict[str, Any]
    Policies: list[dict[str, Any]]


class Role(TypedDict):
    Type: str
    Properties: RoleProps


class Code(TypedDict):
    S3Bucket: str
    S3Key: str


class Environment(TypedDict):
    Variables: dict[str, str]


class FunctionProps(TypedDict):
    FunctionName: str
    Handler: str
    Runtime: str
    Role: Value
    Code: Code
    MemorySize: NotRequired[int]
    Timeout: NotRequired[int]
    Environment: NotRequired[Environment]
    ReservedConcurrentExecutions: NotRequired[int]
    Tags: NotRequired[list[Tag]]


class Function(TypedDict):
    Type: str
    Properties: FunctionProps


class MappingProps(TypedDict):
    BatchSize: int
    EventSourceArn: Value
    FunctionName: Value


class EventSourceMapping(TypedDict):
    Type: str
    Properties: MappingProps


Resource = Queue | Role | Function | EventSourceMapping
Resources = dict[str, Resource]


class Template(TypedDict):
    AWSTemplateFormatVersion: str
    Resources: Resources
    Outputs: NotRequired[dict[str, dict[str, Value]]]


def queue(
    visibility_timeout: int = 30,
    dlq_arn: Value | None = None,
    max_receive_count: int = 3,
    tags: list[Tag] | None = None,
) -> Queue:
    props: QueueProps = {"VisibilityTimeout": visibility_timeout}
    if dlq_arn is not None:
        props["RedrivePolicy"] = {"deadLetterTargetArn": dlq_arn, "maxReceiveCount": max_receive_count}
    if tags:
        props["Tags"] = tags
    return {"Type": "AWS::SQS::Queue", "Properties": props}


def lambda_role(name_prefix: str, extra: list[Statement]) -> Role:
    log_arn = arn("logs", f"log-group:/aws/lambda/{name_prefix}*:*")
    return {
        "Type": "AWS::IAM::Role",
        "Properties": {
            "AssumeRolePolicyDocument": {
                "Version": "2012-10-17",
                "Statement": [{
                    "Effect": "Allow",
                    "Principal": {"Service": ["lambda.amazonaws.com"]},
                    "Action": ["sts:AssumeRole"],
                }],
            },
            "Policies": [{
                "PolicyName": f"{name_prefix}-lambda",
                "PolicyDocument": {
                    "Version": "2012-10-17",
                    "Statement": [
                        allow(["logs:CreateLogStream", "logs:CreateLogGroup", "logs:PutLogEvents"], [log_arn]),
                        *extra,
                    ],
                },
            }],
        },
    }


def function(**props: Unpack[FunctionProps]) -> Function:
    return {"Type": "AWS::Lambda::Function", "Properties": props}


def sqs_event_source(function_logical: str, queue_arn: Value, batch_size: int = 10) -> EventSourceMapping:
    return {
        "Type": "AWS::Lambda::EventSourceMapping",
        "Properties": {
            "BatchSize": batch_size,
            "EventSourceArn": queue_arn,
            "FunctionName": get_att(function_logical, "Arn"),
        },
    }
