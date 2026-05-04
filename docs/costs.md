# Running Costs

Estimated costs for the demo environment running in us-east-1.

## Idle State (deployed, no fault injected)

| Resource | Pricing | Monthly Cost |
|----------|---------|-------------|
| Lambda (SimpleLambda) | 1 invocation/min × 60s × 128MB | ~$0.10 |
| Lambda (Webhook) | Only on alarm state change | ~$0.00 |
| Amazon DynamoDB (on-demand) | ~1,800 writes/min = ~78M writes/mo | ~$98* |
| S3 (config files) | ~43K objects/mo, minimal size | ~$0.01 |
| Amazon CloudWatch Alarms | 2 alarms × $0.10 | $0.20 |
| CloudWatch Logs | ~2 GB/mo | ~$1.00 |
| Amazon SNS | Minimal notifications | ~$0.00 |
| AWS Secrets Manager | 1 secret | $0.40 |
| Amazon EventBridge | 1 rule, 43K invocations/mo | ~$0.04 |
| **Total (idle)** | | **~$100/mo** |

*DynamoDB is the main cost driver because the Lambda writes continuously every minute.

## During Demo (fault injected, ~30 min)

| Resource | Additional Cost |
|----------|----------------|
| DynamoDB (2 WCU provisioned) | ~$0.00 (lower than on-demand) |
| Lambda errors/retries | Negligible |
| AWS DevOps Agent investigation | ~$3.98 per investigation (8 min avg) |
| **Additional demo cost** | **~$0.00** |

## Cost Optimization Tips

- **Disable the EventBridge rule** when not demoing to stop Lambda invocations:
  ```bash
  aws events disable-rule --name demo-simple-lambda-schedule --region us-east-1
  ```
- **Re-enable** before demo:
  ```bash
  aws events enable-rule --name demo-simple-lambda-schedule --region us-east-1
  ```
- **Delete the stack** after demo to stop all costs:
  ```bash
  ./deploy.sh demo cleanup
  ```

## AWS DevOps Agent Costs

> [AWS DevOps Agent Pricing](https://aws.amazon.com/devops-agent/pricing/)

AWS DevOps Agent is billed per agent-second at $0.0083/sec across all task types:

| Task Type | Rate |
|-----------|------|
| Investigations (incident response) | $0.0083/agent-second |
| Evaluations (incident prevention) | $0.0083/agent-second |
| On-demand SRE tasks (chat) | $0.0083/agent-second |

A typical 8-minute investigation costs ~$3.98.

**Free trial:** New customers get 2 months free (20 hrs investigations, 15 hrs evaluations, 20 hrs chat per month).

**AWS Support credits:** Customers on paid support plans receive monthly credits toward AWS DevOps Agent usage — 100% (Unified Operations), 75% (Enterprise), or 30% (Business Support+) of the prior month's support charge.
