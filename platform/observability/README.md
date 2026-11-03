Part of [k8s-platform-lab](../../README.md)

# Observability

Prometheus collects metrics, Grafana reads dashboards, and Fluent Bit sends logs to Elasticsearch.

## Run

```sh
make observability-up
make observability-smoke
```

## Config

| File | Default | Use |
| --- | --- | --- |
| [versions.env](versions.env) | Pinned chart versions | Install versions |
| [kube-prometheus-stack/values.yaml](kube-prometheus-stack/values.yaml) | `observability` | Prometheus stack |
| [fluent-bit/values.yaml](fluent-bit/values.yaml) | Elasticsearch output | Node log collection |
| [elasticsearch/resources.yaml](elasticsearch/resources.yaml) | Local storage | Log index storage |

## Interfaces

| Path | Purpose |
| --- | --- |
| [bin/up](bin/up) | Install metrics and logging |
| [bin/smoke](bin/smoke) | Health checks |
| [alerts/pod-restarts.yaml](alerts/pod-restarts.yaml) | Pod restart alert |
| [dashboards/cluster.json](dashboards/cluster.json) | Cluster dashboard |
| [dashboards/logs.json](dashboards/logs.json) | Log dashboard |

Grafana is at `https://observability.lab.test`.
