# Observability

`platform/observability/` owns metrics, alerting, dashboards, cluster log collection, Elasticsearch, and their shared ingress.

## Metrics

```text
Kubernetes / workloads
        │ scrape
        ▼
Prometheus
   │
   ├──► Grafana
   │
   └──► PrometheusRule ──► AlertManager
```

## Logs

```text
container stdout/stderr ──► node Fluent Bit ──┐
                                               ├──► Elasticsearch ──► Grafana
application.log ──► app Pod sidecar ──────────┘
```

The node-level collector and application sidecar are intentionally separate. The sidecar handles the explicit application file log; the node collector covers normal Kubernetes container logs.

## Reconcile

```bash
make observability-up
make observability-smoke
```

Endpoints:

| URL | Service |
|---|---|
| `https://observability.lab.test/grafana/` | Grafana |
| `https://observability.lab.test/prometheus/` | Prometheus |
| `https://observability.lab.test/elasticsearch/` | Elasticsearch |

## State

Prometheus and Elasticsearch use local-path PVCs. The configuration survives Pod recreation; data is still tied to the worker that owns the local volume.

Dashboards and alerts are Git-managed. Change JSON/PrometheusRule/value files here, run reconciliation, then run the smoke check. Do not preserve dashboard edits made only in the Grafana UI as source of truth.