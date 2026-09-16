# EKS Node Health Alarm Testing

This guide explains how to test the EKS node health use case created by `eks-node-health.yaml`.

The stack creates these CloudWatch alarms from Container Insights metrics:

- `${Env}-EKS-Node-Memory-High`
- `${Env}-EKS-Pod-Restarts`
- `${Env}-EKS-Node-NotReady`

The default environment is `demo`, so the examples below use `demo-eks-node-health` and alarm names starting with `demo-`.

## Prerequisites

Deploy the EKS use case from the repository root:

```bash
./doa.sh deploy-usecase eks
```

Configure `kubectl` for the cluster:

```bash
aws eks update-kubeconfig \
  --name demo-eks-node-health \
  --region <your-region>
```

Verify access:

```bash
kubectl get nodes
kubectl get pods -A
```

Create a namespace for temporary test workloads:

```bash
kubectl create namespace incident-sim
```

Container Insights can take a few minutes to publish metrics after the cluster and CloudWatch Observability add-on are ready.

## Test Pod OOM and Restart Alarm

This test creates a pod that exceeds its memory limit. Kubernetes should restart the container with an `OOMKilled` reason, which can trigger the `${Env}-EKS-Pod-Restarts` alarm.

```bash
kubectl apply -n incident-sim -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: oom-restart
spec:
  replicas: 1
  selector:
    matchLabels:
      app: oom-restart
  template:
    metadata:
      labels:
        app: oom-restart
    spec:
      containers:
        - name: oom
          image: public.ecr.aws/docker/library/python:3.12-slim
          command:
            - python
            - -c
            - |
              data=[]
              while True:
                  data.append("x" * 10_000_000)
          resources:
            requests:
              memory: 32Mi
            limits:
              memory: 64Mi
EOF
```

Watch the pod restart:

```bash
kubectl get pods -n incident-sim -w
```

Inspect the OOM event:

```bash
kubectl describe pod -n incident-sim -l app=oom-restart
```

Check the CloudWatch alarm:

```bash
aws cloudwatch describe-alarms \
  --alarm-names demo-EKS-Pod-Restarts \
  --region <your-region>
```

Clean up:

```bash
kubectl delete deployment oom-restart -n incident-sim
```

## Test High Node Memory Alarm

This test creates one memory-pressure pod per node. It can trigger the `${Env}-EKS-Node-Memory-High` alarm when average node memory utilization crosses the configured threshold. The template default threshold is `85`.

```bash
kubectl apply -n incident-sim -f - <<'EOF'
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: node-memory-pressure
spec:
  selector:
    matchLabels:
      app: node-memory-pressure
  template:
    metadata:
      labels:
        app: node-memory-pressure
    spec:
      containers:
        - name: memory
          image: public.ecr.aws/docker/library/python:3.12-slim
          command:
            - python
            - -c
            - |
              import time
              chunks=[]
              for _ in range(120):
                  chunks.append(bytearray(10 * 1024 * 1024))
                  time.sleep(1)
              time.sleep(3600)
          resources:
            requests:
              memory: 256Mi
            limits:
              memory: 1400Mi
EOF
```

Watch the test pods:

```bash
kubectl get pods -n incident-sim -o wide
```

Check the CloudWatch alarm:

```bash
aws cloudwatch describe-alarms \
  --alarm-names demo-EKS-Node-Memory-High \
  --region <your-region>
```

The alarm uses 60-second periods and requires two datapoints to alarm, so allow several minutes. If the alarm does not fire, lower `NodeMemoryAlarmThreshold` during stack deployment or increase memory pressure carefully.

Clean up:

```bash
kubectl delete daemonset node-memory-pressure -n incident-sim
```

## Test Node NotReady Alarm

Cordon and drain do not make a node `NotReady`; they only prevent scheduling or evict pods. To test the `${Env}-EKS-Node-NotReady` alarm, stop `kubelet` on one worker node and start it again after the alarm fires.

Get one node and its EC2 instance ID:

```bash
NODE_NAME=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')

INSTANCE_ID=$(kubectl get node "$NODE_NAME" \
  -o jsonpath='{.spec.providerID}' \
  | sed 's|.*/||')

echo "$NODE_NAME"
echo "$INSTANCE_ID"
```

Stop `kubelet` through AWS Systems Manager:

```bash
aws ssm send-command \
  --instance-ids "$INSTANCE_ID" \
  --document-name AWS-RunShellScript \
  --parameters 'commands=["sudo systemctl stop kubelet"]' \
  --region <your-region>
```

Watch the node become `NotReady`:

```bash
kubectl get nodes -w
```

Check the CloudWatch alarm:

```bash
aws cloudwatch describe-alarms \
  --alarm-names demo-EKS-Node-NotReady \
  --region <your-region>
```

Restore the node:

```bash
aws ssm send-command \
  --instance-ids "$INSTANCE_ID" \
  --document-name AWS-RunShellScript \
  --parameters 'commands=["sudo systemctl start kubelet"]' \
  --region <your-region>
```

Confirm recovery:

```bash
kubectl get nodes
```

## Cleanup

Remove the temporary namespace after testing:

```bash
kubectl delete namespace incident-sim
```

Delete the EKS use case stack when you no longer need the cluster:

```bash
./doa.sh cleanup-usecase eks
```

## Public Subnet and Internet Gateway Notes

The simulations do not require public subnets or an internet gateway by themselves. They require the nodes and cluster add-ons to reach the services needed for normal EKS operation and monitoring.

This template uses public subnets and an internet gateway for demo simplicity:

- Worker nodes receive public IP addresses through `MapPublicIpOnLaunch: true`.
- The internet gateway provides outbound access for image pulls, CloudWatch metrics and logs, SSM, STS, and EKS APIs.
- The EKS API endpoint is public through `EndpointPublicAccess: true`.

A private-subnet design also works, but it needs equivalent outbound connectivity through a NAT gateway or VPC endpoints for the required AWS services. For production-style clusters, prefer private worker subnets and restrict or disable public API endpoint access.
