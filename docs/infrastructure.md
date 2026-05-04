# Infrastructure

## Architecture Diagram

### Application Layer

```mermaid
graph TD
    EB["Amazon EventBridge (1-min schedule)"] -->|trigger| Lambda["SimpleLambda (128MB, 90s)"]
    Lambda -->|write config| S3["S3 Bucket"]
    Lambda -->|read and verify| S3
    Lambda -->|60s continuous writes| DDB["Amazon DynamoDB (On-demand)"]
    Lambda -->|logs| CWL["Amazon CloudWatch Logs"]

    style EB fill:#e8d44d,color:#000
    style Lambda fill:#f90,color:#fff
    style S3 fill:#3f8624,color:#fff
    style DDB fill:#2d72b8,color:#fff
    style CWL fill:#cc2264,color:#fff
```

### Monitoring and Alerting

```mermaid
graph TD
    DDB["DynamoDB"] -->|throttle metrics| CWA1["DDB Throttle Alarm"]
    CWL["CloudWatch Logs"] -->|error metrics| CWA2["Lambda Error Alarm"]
    CWA1 -->|alarm| SNS["Amazon SNS"]
    CWA2 -->|alarm| SNS
    SNS -->|invoke| WH["Webhook Lambda"]
    WH -->|HMAC POST| DA["AWS DevOps Agent"]

    style DDB fill:#2d72b8,color:#fff
    style CWL fill:#cc2264,color:#fff
    style CWA1 fill:#cc2264,color:#fff
    style CWA2 fill:#cc2264,color:#fff
    style SNS fill:#cc2264,color:#fff
    style WH fill:#f90,color:#fff
    style DA fill:#232f3e,color:#fff
```

### Investigation and Mitigation

```mermaid
graph TD
    DA["AWS DevOps Agent"] -->|auto-investigation| RCA["Root Cause Analysis"]
    RCA -->|findings| MIT["Mitigation Plan"]
    MIT -->|remediation steps| OP["Operator"]

    style DA fill:#232f3e,color:#fff
    style RCA fill:#232f3e,color:#fff
    style MIT fill:#232f3e,color:#fff
    style OP fill:#e8d44d,color:#000
```

## Resources Created

| Resource | Name | Purpose |
|----------|------|---------|
| EventBridge Rule | `{env}-simple-lambda-schedule` | Triggers Lambda every 1 minute |
| Lambda Function | `{env}-simple-lambda` | Writes config to S3, stress-tests DynamoDB |
| IAM Role | `{env}-simple-lambda-role` | Least-privilege: S3 put/get, DDB put/get |
| S3 Bucket | `{env}-simple-lambda-config-{account}` | Config storage |
| DynamoDB Table | `{env}-stress-test-table` | On-demand, target for stress writes |
| CloudWatch Alarm | `{env}-DynamoDB-WriteThrottle` | Fires on WriteThrottleEvents > 0 |
| CloudWatch Alarm | `{env}-Lambda-Errors` | Fires on Lambda Errors ≥ 3 |
| SNS Topic | `{env}-devops-agent-alarms` | Routes alarms to webhook |
| Lambda Function | `{env}-devops-agent-webhook` | Forwards alarms to AWS DevOps Agent |
| IAM Role | `{env}-webhook-lambda-role` | AWS Secrets Manager read access |
| Secrets Manager | `{env}-devops-agent-webhook` | Stores webhook URL + HMAC secret |
| Log Groups | `/aws/lambda/{env}-simple-lambda`, `/aws/lambda/{env}-devops-agent-webhook` | 14-day retention |

## Fault Injection

The `simulate_incident.py` script switches DynamoDB from on-demand to provisioned with 2 WCU:

```mermaid
sequenceDiagram
    participant Op as Operator
    participant DDB as DynamoDB
    participant Lambda as SimpleLambda
    participant CW as CloudWatch
    participant DA as AWS DevOps Agent

    rect rgb(240, 248, 255)
    Note over DDB: On-demand (~400 WRU)
    Op->>DDB: update_table(WCU=2)
    Note over DDB: Provisioned (2 WCU)
    end

    rect rgb(255, 240, 240)
    loop Every 1 minute
        Lambda->>DDB: 60s continuous writes
        DDB-->>CW: WriteThrottleEvents spike
    end

    CW->>CW: Alarm state ALARM
    CW->>DA: SNS Webhook Investigation
    end

    rect rgb(240, 255, 240)
    DA->>DA: RCA billing mode changed
    DA->>DA: Mitigation restore on-demand
    end

    rect rgb(240, 248, 255)
    Op->>DDB: restore on-demand
    Note over DDB: On-demand (restored)
    end
```
