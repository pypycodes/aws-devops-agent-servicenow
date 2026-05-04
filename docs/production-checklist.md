# Production Security Checklist

> Derived from accepted demo risks, threat model findings, and CSR scan results.
> Every item below was intentionally deferred in the demo and must be addressed before production.

---

## Pre-Deployment

### Encryption — Customer-Managed KMS Keys

- [ ] Evaluate separate CMKs per service for blast-radius isolation in production
- [ ] Document key management strategy: rotation policy, access controls, lifecycle

### IAM — Least Privilege

- [ ] Create a dedicated least-privilege IAM role for `agent_monitor.py` with only: `devops-agent:{ListAgentSpaces,ListBacklogTasks,GetBacklogTask,ListJournalRecords,SendMessage}`
- [ ] Require short-lived credentials (STS/SSO) for operator access — no long-lived access keys
- [ ] Deny broad account-wide `secretsmanager:GetSecretValue` via SCP or IAM boundary
- [ ] Document access review schedule (quarterly) and permission audit procedures

### Network — VPC Isolation

- [ ] Create VPC with private subnets for Lambda functions
- [ ] Add VPC endpoints for: DynamoDB, Secrets Manager, SNS, SQS, CloudWatch Logs
- [ ] Configure security groups restricting outbound to VPC endpoints + DevOps Agent webhook endpoint only
- [ ] Add NAT gateway for the webhook Lambda's outbound HTTPS to `event-ai.*.api.aws`

### S3 — Hardening

- [ ] Create a dedicated access logging bucket with lifecycle policy
- [ ] Enable `LoggingConfiguration` on ConfigBucket pointing to logging bucket
- [ ] Evaluate Object Lock if compliance/WORM requirements apply
- [ ] Enable MFA Delete on ConfigBucket via CLI (requires root account): `aws s3api put-bucket-versioning --mfa "arn:..." --versioning-configuration Status=Enabled,MFADelete=Enabled`

### Secrets — Rotation

- [ ] Implement manual rotation runbook for webhook HMAC secret (DevOps Agent API does not support automated re-registration)
- [ ] Define rotation schedule (e.g., 90 days) and document in runbook

### Data Classification

- [ ] Define data classification scheme (Public, Internal, Confidential, Restricted)
- [ ] Label resources with `DataClassification` tags in CloudFormation
- [ ] Document handling procedures per classification (storage, transmission, retention, deletion)

---

## Deployment

### Lambda — Resilience

- [ ] Add Dead Letter Queue (SQS) to SimpleLambda for failed invocations
- [ ] Tune reserved concurrency based on expected alarm volume (demo uses 5)
- [ ] Validate Lambda event payload structure at handler entry
- [ ] Implement circuit breaker pattern in SimpleLambda (stop on high error rate)

### SNS — Topic Security

- [ ] Confirm no unauthorized subscriptions exist on the topic

### Webhook — Input Validation

No outstanding items — sanitization, dedup, and secret refresh already implemented.

### CloudFormation — Integrity

- [ ] Enable CloudFormation stack termination protection
- [ ] Enable drift detection on the stack
- [ ] Restrict `cloudformation:UpdateStack` and `cloudformation:DeleteStack` to deployment pipeline role only

---

## Post-Deployment

### Logging and Audit

- [ ] Enable CloudTrail in the account (management events at minimum)
- [ ] Enable CloudTrail data events for: S3 (ConfigBucket), DynamoDB (StressTable), Lambda invocations
- [ ] Enable `devops-agent` event logging so `SendMessage` calls are attributable
- [ ] Push CloudTrail logs to a separate audit account or organization trail
- [ ] Set up CloudWatch metric filter for `"Write error"` log lines in SimpleLambda logs
- [ ] Set up CloudWatch alarm on WebhookDLQ `ApproximateNumberOfMessagesVisible > 0`

### Monitoring and Alerting

- [ ] Monitor webhook delivery failure rate (DLQ depth)
- [ ] Monitor Lambda error rates and throttling beyond expected thresholds
- [ ] Alert on unexpected SNS subscriptions (`sns:Subscribe` events in CloudTrail)
- [ ] Alert on S3 object uploads to ConfigBucket outside deployment pipeline
- [ ] Monitor DevOps Agent agent-second spend and set billing alarm

### Human-in-the-Loop Controls

- [ ] Establish change management process for executing AI-generated mitigation plans
- [ ] Require independent validation of plan-suggested commands before execution
- [ ] Never copy-paste remediation commands directly — run through reviewed change management
- [ ] Document operator review checklist for mitigation plans (check for destructive actions, privilege escalation, cost impact)

### Ongoing Operations

- [ ] Schedule quarterly IAM permission review against CloudTrail actual usage
- [ ] Rotate webhook HMAC secret per defined schedule
- [ ] Review and prune CloudWatch log retention policies
- [ ] Run security scans (Checkov, cfn-guard) in CI/CD pipeline on every template change
