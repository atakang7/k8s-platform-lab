Part of [k8s-platform-lab](../README.md)

# Platform

The platform scripts reconcile ingress, Jenkins, namespaces and observability after Kubernetes exists.

## Run

```sh
make edge-up
make jenkins-up
make environment-up
make observability-up
```

## Config

| Source | Value | Use |
| --- | --- | --- |
| [environments.yaml](../environments.yaml) | `clusterEnvironment: dev` | Active cluster environment |
| [edge/](edge/README.md) | `192.168.56.200` | Ingress VIP |
| [jenkins/](jenkins/README.md) | `jenkins` | Controller namespace |
| [observability/](observability/README.md) | `observability` | Metrics and logs namespace |

## Interfaces

| Path | Purpose |
| --- | --- |
| [edge/](edge/README.md) | Kubernetes edge controllers |
| [jenkins/](jenkins/README.md) | CI controller and agents |
| [environment/](environment/README.md) | Namespace and registry credentials |
| [observability/](observability/README.md) | Metrics, alerts and logs |
| `bin/endpoints` | Prints HTTPS endpoints |
| `bin/credentials` | Prints operator access details |
