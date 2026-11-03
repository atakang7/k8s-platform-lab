Part of [k8s-platform-lab](../../README.md)

# Service chart

A Helm library chart with shared templates for stateless HTTP workloads.

## Run

```sh
helm lint charts/service
```

Applications use it as a chart dependency; see [app/chart](../../app/chart/README.md).

## Config

| Value | Source | Use |
| --- | --- | --- |
| `image.digest` | Application values or deploy job | Image identity |
| `replicas` | Application values | Desired Pods |
| `containerPort` | Application values | Container listener |
| `ingress` | Application values | HTTP ingress |
| `smokeTest.path` | Application values | Helm test URL |

## Interfaces

| Path | Purpose |
| --- | --- |
| [Chart.yaml](Chart.yaml) | Library chart version |
| [templates/_defaults.tpl](templates/_defaults.tpl) | Chart defaults |
| [templates/_manifests.tpl](templates/_manifests.tpl) | Workload and service templates |

The chart renders resources when the consuming chart includes `service.manifests`.
