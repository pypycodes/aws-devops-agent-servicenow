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

## CloudFormation Factory Model

The infrastructure is split into shared incident routing and individual use case stacks:

```text
cloud-formation/
├── devops-agent-stack.yaml
├── shared/incident-routing.yaml
└── usecases/
    ├── dynamodb-simple-lambda.yaml
    ├── ec2-cpu-stress.yaml
    └── eks-node-health.yaml
```

The shared incident routing stack owns the central SNS topic and the incident Lambda integration. Each use case stack owns only its workload and alarms, then publishes alarm actions to the shared `IncidentTopicArn` output.

This keeps the AWS DevOps Agent space and ServiceNow integration stable while allowing new use cases such as EKS or EC2 to add their own alarms independently.

The EC2 use case creates a `t3.nano` instance that runs CPU stress on first boot and publishes the CPU spike alarm to the shared incident topic.

The EKS use case creates an EKS cluster, managed node group, CloudWatch Observability add-on, and Container Insights alarms for high node memory, pod restarts, and NodeNotReady signals.

## Resources Created

| Resource | Name | Purpose |
| -------- | ---- | ------- |
| EventBridge Rule | `{env}-simple-lambda-schedule` | Triggers Lambda every 1 minute |
| Lambda Function | `{env}-simple-lambda` | Writes config to S3, stress-tests DynamoDB |
| IAM Role | `{env}-simple-lambda-role` | Least-privilege: S3 put/get, DDB put/get |
| S3 Bucket | `{env}-simple-lambda-config-{account}` | Config storage |
| DynamoDB Table | `{env}-stress-test-table` | On-demand, target for stress writes |
| CloudWatch Alarm | `{env}-DynamoDB-WriteThrottle` | Fires on WriteThrottleEvents > 0 |
| CloudWatch Alarm | `{env}-Lambda-Errors` | Fires on Lambda Errors ≥ 3 |
| SNS Topic | `{env}-devops-agent-alarms` | Shared incident routing topic |
| Lambda Function | `{env}-servicenow-incident` | Creates ServiceNow incidents when ServiceNow mode is enabled |
| Lambda Function | `{env}-devops-agent-webhook` | Forwards alarms to AWS DevOps Agent when webhook mode is enabled |
| IAM Role | `{env}-webhook-lambda-role` | AWS Secrets Manager read access |
| Secrets Manager | `{env}-devops-agent-webhook` | Stores webhook URL + HMAC secret |
| Log Groups | `/aws/lambda/{env}-simple-lambda`, `/aws/lambda/{env}-servicenow-incident`, `/aws/lambda/{env}-devops-agent-webhook` | 14-day retention |

## Fault Injection

The incident trigger keeps DynamoDB on-demand billing and caps the table at 2 write request units:

```mermaid
sequenceDiagram
    participant Op as Operator
    participant DDB as DynamoDB
    participant Lambda as SimpleLambda
    participant CW as CloudWatch
    participant DA as AWS DevOps Agent

    rect rgb(240, 248, 255)
    Note over DDB: On-demand (~400 WRU)
    Op->>DDB: update_table(MaxWriteRequestUnits=2)
    Note over DDB: On-demand (2 max WRU)
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
    DA->>DA: RCA on-demand write limit applied
    DA->>DA: Mitigation remove write limit
    end

    rect rgb(240, 248, 255)
    Op->>DDB: remove write limit
    Note over DDB: On-demand (restored)
    end
```
