Part of [k8s-platform-lab](../README.md)

# Admission policies

The resource request webhook rejects in-scope Deployments without CPU or memory requests.

## Run

```sh
make policies-up
make policies-smoke
```

## Config

| Source | Default | Use |
| --- | --- | --- |
| [../environments.yaml](../environments.yaml) | `dev` | Active cluster environment |
| [resource-requests-webhook/helm/resource-requests-webhook/values.yaml](resource-requests-webhook/helm/resource-requests-webhook/values.yaml) | `delivery.lab.test/environment` | Namespace selector |
| [../state/](../state/) | Digest per environment | Webhook image |

## Interfaces

| Path | Purpose |
| --- | --- |
| [resource-requests-webhook/](resource-requests-webhook/README.md) | Go admission server |
| `bin/up` | Install recorded webhook digest |
| `bin/smoke` | Real API server dry-run checks |
| [resource-requests-webhook/smoke/](resource-requests-webhook/smoke/) | Accepted and rejected manifests |

The webhook runs in `policy-system` and uses `failurePolicy: Fail`.
