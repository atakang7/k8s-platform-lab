Part of [k8s-platform-lab](../../../../README.md)

# Webhook chart

Helm deploys the admission server and its Kubernetes registration.

## Run

From the repository root:

```sh
helm lint policies/resource-requests-webhook/helm/resource-requests-webhook
make policies-up
make policies-smoke
```

## Config

| Value | Default | Use |
| --- | --- | --- |
| `replicaCount` | `2` | Webhook Pods |
| `service.port` | `443` | ClusterIP HTTPS port |
| `admission.environmentLabel` | `delivery.lab.test/environment` | Namespace selection |
| `podDisruptionBudget.minAvailable` | `1` | Available replicas |
| `image.digest` | Empty | Set from state on install |

## Interfaces

| Path | Purpose |
| --- | --- |
| [Chart.yaml](Chart.yaml) | Chart version |
| [templates/deployment.yaml](templates/deployment.yaml) | Server workload |
| [templates/service.yaml](templates/service.yaml) | HTTPS service |
| [templates/validating-webhook.yaml](templates/validating-webhook.yaml) | Admission registration |
