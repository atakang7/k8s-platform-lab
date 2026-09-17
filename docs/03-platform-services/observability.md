# Observability

The observability stack owns metrics, alerts, dashboards, and centralized logs. It is intentionally small and explicit because the cluster itself is resource-constrained.

## Data flow

```text
                                METRICS

Kubernetes / nodes / workloads
             │
             ▼
      Prometheus · node-2
             │
      ┌──────┴──────────┐
      │                 │
      ▼                 ▼
 Grafana · node-3   AlertManager · node-3
      │                 ▲
      │                 │
      └──── dashboards  └── PrometheusRule · pod restarts

                                 LOGS

container stdout/stderr ── platform Fluent Bit ──┐
                                                │
Java application.log ── Pod sidecar Fluent Bit ─┼──► Elasticsearch
                                                │          │
                                                └──────────┘
                                                           │
                                                           ▼
                                                     Grafana logs
```

The application-specific file log path is explained in [04 — Application runtime](../04-application-runtime/README.md). Platform Fluent Bit handles cluster container logs; the application sidecar handles the explicitly rotated file log.

## Metrics

`kube-prometheus-stack` provides Prometheus, AlertManager, Grafana, kube-state-metrics, node-exporter, and the Prometheus Operator.

The default chart rule set is disabled. Only signals we intentionally operate are enabled in this reference stack. This keeps the lab from spending memory on a large default alert/rule surface that is not being consumed.

Prometheus is pinned to `node-2` with:

- one replica;
- 1-day retention;
- `1500MB` retention-size limit;
- 2 GiB local-path PVC;
- explicit CPU and memory requests/limits.

The Prometheus Operator, Grafana, AlertManager, and kube-state-metrics are pinned to `node-3` with bounded resources.

## Alerting

The required pod-restart signal is a repository-owned `PrometheusRule`.

```text
pod restart counter increases
          │
          ▼
Prometheus evaluates rule
          │
          ▼
AlertManager receives alert
```

AlertManager routing exists even though the reference environment does not configure an external notification provider. The alert generation path is still complete and testable.

## Dashboards

Custom dashboards are versioned as JSON under `platform/observability/dashboards/` and loaded into Grafana through labeled ConfigMaps.

This keeps dashboards in Git instead of making the Grafana database the only copy of operational knowledge.

The stack exposes:

- `https://observability.lab.test/grafana/`
- `https://observability.lab.test/prometheus/`
- `https://observability.lab.test/elasticsearch/`

All three reuse the platform ingress and wildcard TLS path.

## Logging

Elasticsearch is the log store. Fluent Bit is the transport layer.

The design deliberately separates log production from transport:

```text
application thread
      │
      ▼
async Logback queue
      │
      ▼
rotating file
      │
      ▼
sidecar Fluent Bit
      │
      ▼
Elasticsearch
```

A temporary Elasticsearch slowdown therefore does not turn every application request into a synchronous network write to the log backend.

## Storage tradeoff

Prometheus and Elasticsearch use local-path storage. This is enough to preserve state across Pod recreation and keep the deployment self-contained. It is not node-failure HA. A production cluster with external persistent storage would keep the same service boundaries but replace the storage class and replication assumptions.

## Resource guard before install

The observability bootstrap checks worker allocatable memory before chart installation. A deployment that cannot fit is rejected before Helm creates a half-running stack.

That check exists because this cluster has a fixed node budget; chart success is not useful if it leaves the worker permanently under memory pressure.

## Reconciliation

```bash
make observability-up
make observability-smoke
```

The bootstrap installs pinned chart versions, applies Elasticsearch, alerts, dashboards, Fluent Bit, and ingress, then waits for required stateful components.

Implementation: [`platform/observability/`](../../platform/observability/).
