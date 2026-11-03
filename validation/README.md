Part of [k8s-platform-lab](../README.md)

# Validation

Checks run against the cluster, its edge, released application, metrics and admission webhook.

## Run

From the repository root:

```sh
make cluster-validate
make edge-smoke
make observability-smoke
make policies-smoke
make e2e-validate
```

The deeper edge check is `make edge-validate`. `make container-validate` builds and runs the Java image locally.

## Config

| Source | Default | Use |
| --- | --- | --- |
| [../infra/edge/config.env](../infra/edge/config.env) | `lab.test` | HTTPS hosts |
| [../environments.yaml](../environments.yaml) | `dev` | Namespace selection |
| [../state/](../state/) | Recorded image digests | Release comparison |

## Interfaces

| Path | Checks |
| --- | --- |
| [cluster/validate.sh](cluster/validate.sh) | Nodes, CNI and storage |
| [edge/validate.sh](edge/validate.sh) | Host trust and edge boundary |
| [container/validate.sh](container/validate.sh) | Local image contract |
| [e2e/validate.sh](e2e/validate.sh) | HTTPS, Elasticsearch and Prometheus |
| [../policies/bin/smoke](../policies/bin/smoke) | Webhook decisions |

Validators exit nonzero when an expected outcome is absent.
