# k8s-platform-lab

A three-node Kubernetes lab for engineers testing cluster bootstrap, Git-based delivery and platform operations.

```text
+---------+   VMs   +------------+  Pods   +-----+
| Vagrant | ------> | Kubernetes | ------> | app |
+---------+         +------------+         +-----+
                          ^                    |
                          | Helm               | logs
                          |                    v
                    +---------+          +---------------+
                    | Jenkins |          | Elasticsearch |
                    +---------+          +---------------+
```

## Quick start

On an Ubuntu x86_64 host with virtualization enabled:

```sh
make prerequisites
make cluster-up
make cluster-validate
make edge-up
make edge-smoke
```

Continue with the [bootstrap guide](docs/how-to/bootstrap.md) to add credentials and install Jenkins and observability.

## Layout

| Path | What it is |
| --- | --- |
| [infra/](infra/README.md) | Vagrant VMs, Ansible, host DNS and Vault |
| [platform/](platform/README.md) | Ingress, Jenkins, environments and monitoring |
| [delivery/](delivery/README.md) | Jenkins library and release scripts |
| [app/](app/README.md) | Spring Boot HTTP service |
| [charts/service/](charts/service/README.md) | Shared Helm library chart |
| [policies/](policies/README.md) | Kubernetes admission webhook |
| [validation/](validation/README.md) | Cluster and application checks |
| [test/](test/README.md) | Nested test VM |

## Docs

[Documentation index](docs/README.md) | [Deployment](docs/how-to/deploy.md) | [Release state](docs/reference/release-state.md) | [Architecture](docs/explanation/architecture.md)

## Limits

- Vault and BIND9 have no Prometheus alerts.
- Elasticsearch is unauthenticated on the lab edge network.
- Local-path storage cannot fail over across nodes.
- [Known failures](docs/reference/known-issues.md) include Jenkins recovery after VM snapshots.
