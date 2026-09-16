# CloudFormation Factory Model

This folder separates the one-time/shared incident plumbing from individual incident use cases.

## Layout

```text
cloud-formation/
├── devops-agent-stack.yaml
├── shared/
│   └── incident-routing.yaml
└── usecases/
    ├── dynamodb-simple-lambda.yaml
    ├── ec2-cpu-stress.yaml
    └── eks-node-health.yaml
```

## Stack Contract

`devops-agent-stack.yaml` creates the shared AWS DevOps Agent space. The `doa.sh` wrapper deploys it as `{env}-agent-space`, for example `dev-agent-space`.

`shared/incident-routing.yaml` creates the reusable incident routing layer:

- SNS alarm topic: `{env}-devops-agent-alarms`
- ServiceNow incident Lambda when `ENABLE_SERVICENOW=true`
- Webhook Lambda when `ENABLE_SERVICENOW=false`
- SNS subscriptions and Lambda invoke permissions

Each use case stack creates only its workload, alarms, and use-case-specific permissions. Use case alarms receive `IncidentTopicArn` from the shared stack and publish alarm/OK transitions to that topic.

## Adding a Use Case

1. Add a template under `cloud-formation/usecases/`.
2. Accept `Env` and `IncidentTopicArn` parameters.
3. Create workload-specific alarms with `AlarmActions` and `OKActions` set to `!Ref IncidentTopicArn`.
4. Add the use case name to `deploy_usecase()` in `doa.sh`.

## Use Cases

Deploy a single use case with:

```bash
./doa.sh deploy-usecase dynamodb
./doa.sh deploy-usecase ec2
./doa.sh deploy-usecase eks
```

Delete a single use case while preserving shared incident routing and the agent space with:

```bash
./doa.sh cleanup-usecase dynamodb
./doa.sh cleanup-usecase ec2
./doa.sh cleanup-usecase eks
```

`deploy-usecase` creates the shared incident routing stack first when it is missing. If `ENABLE_SERVICENOW=true`, that shared stack deploys the ServiceNow incident Lambda and subscribes it to the shared SNS topic. If `ENABLE_SERVICENOW=false`, it deploys the webhook Lambda and subscribes that Lambda instead.

The EC2 use case creates a `t3.nano` instance that runs CPU stress on first boot and alarms on `CPUUtilization`.

The EKS use case creates an EKS cluster, managed node group, CloudWatch Observability add-on, and alarms for high node memory, pod restarts, and NodeNotReady signals from Container Insights metrics.
