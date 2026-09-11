---
icon: lucide/cloud-cog
---

# Infrastructure experiments

Cloud infrastructure tends to accumulate layers. These experiments ask which
ones can be removed without giving up the useful parts.

## Notes

- [Ejecting Serverless with Jsonnet](jsonnet-cloudformation/index.md) —
  replacing framework-generated CloudFormation with a small Jsonnet library
  and templates you can inspect directly.
- [Document Processing Pipeline with Lambda Durable Functions](document-pipeline-durable-functions.md) —
  checkpointed steps, bounded fan-out, and a human-approval wait, written as
  one plain function instead of a Step Functions state machine.
