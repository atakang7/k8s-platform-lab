Part of [k8s-platform-lab](../../README.md)

# Sample app chart

The application chart consumes the [service library chart](../../charts/service/README.md).

## Run

From the repository root, with Helm registry access:

```sh
helm dependency build app/chart
helm lint app/chart
```

## Config

| Value | Default | Use |
| --- | --- | --- |
| `replicas` | `4` | Stable Pods |
| `containerPort` | `9001` | Application port |
| `ingress.host` | `app.lab.test` | HTTPS host |
| `metrics.path` | `/actuator/prometheus` | Scrape path |
| `smokeTest.path` | `/api/foos?val=smoke` | Helm test |

## Interfaces

| Path | Purpose |
| --- | --- |
| [Chart.yaml](Chart.yaml) | Chart version and dependency |
| [values.yaml](values.yaml) | Common workload settings |
| [values-dev.yaml](values-dev.yaml) | Dev overrides |
| [values-stage.yaml](values-stage.yaml) | Stage overrides |

The deployment job sets `image.digest` from the environment state file.
