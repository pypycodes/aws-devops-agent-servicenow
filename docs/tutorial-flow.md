# Tutorial Flow

Step-by-step guide for running the AWS DevOps Agent incident lifecycle tutorial.

## Pre-Tutorial Checklist

- [ ] Prerequisites checked: `./doa.sh pre`
- [ ] Environment variables set: `export ENV=dev AWS_REGION=us-east-1`
- [ ] Stack deployed: `./doa.sh deploy`
- [ ] Amazon EventBridge rule enabled (Lambda running every minute)
- [ ] AWS DevOps Agent space configured with webhook association
- [ ] `agent_monitor.py` tested: `python3 scripts/agent_monitor.py`

## Tutorial Script

### Setup (2 terminals)

```
┌──────────────────────────────────┬──────────────────────────────────┐
│  Terminal 1 — Monitor            │  Terminal 2 — Operator           │
│                                  │                                  │
│  export ENV=dev                  │  export ENV=dev                  │
│  python3 scripts/agent_monitor.py│  ./doa.sh trigger                │
│                                  │  ./doa.sh restore                │
│  ⏳ Watches for investigations   │  🔥 Injects faults & restores    │
│  📋 Displays RCA + mitigation    │  📊 Checks logs & alarm state    │
└──────────────────────────────────┴──────────────────────────────────┘
```

### Step 1: Observe Normal State (~1 min)

> **What's happening:** The SimpleLambda runs every minute via Amazon EventBridge. It
> does 60 seconds of continuous writes to Amazon DynamoDB. With on-demand capacity,
> everything succeeds without throttling.

**Terminal 2:**
```bash
# Show the Lambda running normally — expect ~1800 writes per invocation, 0 errors
aws logs filter-log-events \
  --log-group-name /aws/lambda/${ENV}-simple-lambda \
  --region us-east-1 --start-time $(($(date +%s) - 120))000 \
  --query "events[].message" --output text | grep "writes="

# Show both alarms are in OK state
aws cloudwatch describe-alarms \
  --alarm-names ${ENV}-DynamoDB-WriteThrottle ${ENV}-Lambda-Errors \
  --query "MetricAlarms[].[AlarmName,StateValue]" --output table
```

### Step 2: Inject the Fault (~1 min)

> **What's happening:** This switches the DynamoDB table from on-demand (~400 WCU)
> to provisioned with only 2 WCU. The Lambda still fires every minute doing 60s of
> writes — but now those writes hit a 2 WCU limit, causing `WriteThrottleEvents`.
> Amazon CloudWatch detects the throttling and fires the alarm within ~60 seconds.

**Terminal 2:**
```bash
./doa.sh trigger
```

### Step 3: Watch the Investigation (~3-5 min)

> **What's happening:** The alarm fires → Amazon Simple Notification Service (Amazon SNS) delivers to the webhook Lambda →
> webhook signs the payload with HMAC and POSTs to the AWS DevOps Agent endpoint →
> AWS DevOps Agent automatically starts an investigation. It analyzes CloudWatch metrics,
> CloudTrail logs, and DynamoDB configuration to find the root cause. Once complete,
> the agent monitor script triggers mitigation via the `SendMessage` API.

**Terminal 1** (agent_monitor.py) shows:

1. **New task detected** — investigation created by the webhook
2. **IN_PROGRESS** — agent is analyzing metrics, logs, and CloudTrail
3. **COMPLETED** — agent found the root cause
4. **Root cause displayed** — e.g., "billing mode changed from on-demand to provisioned with 2 WCU"
5. **Mitigation triggered** — script sends `generate_mitigation_plan` via API
6. **Mitigation plan** — step-by-step remediation with CLI commands

> **Note:** AWS DevOps Agent is read-only — it provides the fix commands but does not execute them.

### Step 4: Restore Normal Operation (~30 sec)

> **What's happening:** This switches DynamoDB back to on-demand. The Lambda's
> writes succeed again, throttle metrics drop to zero, and the alarm returns
> to OK within ~2 minutes.

**Terminal 2:**
```bash
./doa.sh restore
```

## Fallback: Manual Investigation

> **When to use:** If the webhook doesn't trigger an investigation automatically
> (e.g., webhook misconfigured, SNS delivery issue), you can start one manually.

```bash
aws devops-agent create-backlog-task \
  --agent-space-id <space-id> \
  --task-type INVESTIGATION \
  --title "DynamoDB throttling on ${ENV}-stress-test-table" \
  --description "WriteThrottleEvents alarm firing, table switched to provisioned billing" \
  --priority HIGH \
  --region us-east-1 --output json
```

> The agent monitor picks up manually created investigations the same
> way — it watches all tasks regardless of how they were triggered.

## Cleanup

```bash
# Restore table to on-demand (if not already done)
./doa.sh restore

# Or tear down everything
./doa.sh cleanup
```

> **Note:** If you only restore the table, the stack stays deployed and the Lambda
> keeps running every minute. To stop costs, either disable the EventBridge rule
> or run cleanup.
>
> ```bash
> aws events disable-rule --name ${ENV}-simple-lambda-schedule --region us-east-1
> ```
