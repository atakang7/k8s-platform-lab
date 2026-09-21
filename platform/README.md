# Platform

`platform/` owns the Kubernetes-resident shared services.

```text
platform/
├── edge/            ingress, ExternalDNS, MetalLB, VSO
├── jenkins/         CI/CD control plane
├── environment/     environment namespace + deploy identity
└── observability/   metrics, dashboards and logs
```

Host-side Vault, BIND9 and CA configuration live under [`infra/`](../infra/README.md).

## Components

| Area | What it owns |
|---|---|
| [`edge/`](edge/README.md) | Kubernetes edge: ingress, DNS integration, load balancer and secret delivery |
| [`jenkins/`](jenkins/README.md) | Jenkins controller, jobs, agents and credentials wiring |
| `environment/` | the namespace, deploy ServiceAccount and runtime registry secret for this cluster's environment |
| [`observability/`](observability/README.md) | Prometheus, Grafana, Alertmanager, Elasticsearch and log collection |

The application itself stays under [`app/`](../app/README.md).

## Reconcile

```bash
make edge-up
make jenkins-up
make environment-up
make observability-up
```

Use the owning component README for configuration details and validation commands.

## Access

```bash
make endpoints
make credentials
```

Persistent platform changes belong in Git and are applied through the owning reconciliation command.
