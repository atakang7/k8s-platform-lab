# Platform

`platform/` owns the Kubernetes-resident shared services around the application.

```text
                         Kubernetes

        ┌───────────────────┬───────────────────┐
        │                   │                   │
        ▼                   ▼                   ▼
      Edge               Jenkins          Observability
 ingress / DNS         CI/CD control       metrics / logs
        │                   │                   ▲
        │                   ▼                   │
        │              Environment              │
        │          namespace + deploy ID        │
        │                   │                   │
        └──────────────► application ───────────┘
```

Host-side Vault, BIND9 and CA configuration live under [`infra/`](../infra/README.md).

## Platform pieces

| Area | Role | Main configuration |
|---|---|---|
| [`edge/`](edge/README.md) | exposes platform and application services through DNS + HTTPS | `platform/edge/` |
| [`jenkins/`](jenkins/README.md) | runs CI/CD and provisions Kubernetes build/deploy agents | `platform/jenkins/values.yaml`, `platform/jenkins/jcasc/` |
| `environment/` | prepares the application namespace, deploy identity and registry pull secret for this cluster | `platform/environment/namespace.yaml`, `environments.yaml` |
| [`observability/`](observability/README.md) | collects metrics and logs and exposes Grafana/Prometheus | `platform/observability/` |

The application itself is configured under [`app/`](../app/README.md). Delivery behavior is documented in [`DELIVERY.md`](../DELIVERY.md).

## Environment boundary

Each cluster runs one environment selected by:

```yaml
clusterEnvironment: dev
```

in `environments.yaml`.

`make environment-up` prepares only that environment:

```text
clusterEnvironment
       │
       ▼
apps-<environment>
       │
       ├── jenkins-deploy-<environment>
       └── runtime registry secret
```

Jenkins then deploys application state from `state/<environment>.yaml`.

## Reconcile

```bash
make edge-up
make jenkins-up
make environment-up
make observability-up
```

Use the component README when changing that subsystem; this page is only the platform-level map.
