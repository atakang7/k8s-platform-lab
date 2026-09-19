# Observability

`platform/observability/` owns metrics, alerting, dashboards, cluster log collection, Elasticsearch, and their shared ingress.

## Metrics and alerts

```text
node-exporter / kube-state-metrics / targets
                  │ scrape
                  ▼
             Prometheus
              │      │
          query│      │firing alerts
              ▼      ▼
           Grafana  AlertManager

PrometheusRule ── configures alert rule ──► Prometheus
```

## Logs

```text
/var/log/containers/*.log ──► platform Fluent Bit ──┐
                                                      ├──► Elasticsearch ──► Grafana
app.log ────────────► app Pod sidecar ───────┘
```

The platform DaemonSet and application sidecar are intentionally separate. The sidecar handles the explicit application file log; the platform collector covers normal Kubernetes container logs.
Grafana provisions separate Elasticsearch datasources for `kubernetes-*` and `app-logs`, plus Git-managed metric and log panels.

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

Prometheus and Elasticsearch use local-path PVCs. Their data survives Pod recreation on the owning node; local-path does not provide cross-node storage HA.

Dashboards and alerts are Git-managed. Change JSON/PrometheusRule/value files here, run reconciliation, then run the smoke check. Do not preserve dashboard edits made only in the Grafana UI as source of truth.

