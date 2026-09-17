# 03 — Platform services

This layer runs the shared services used to build, deploy, observe, and operate workloads after the cluster edge is available.

```text
┌──────────────────────────── Kubernetes ─────────────────────────────┐
│                                                                    │
│  node-2                              node-3                        │
│  ┌──────────────────────┐            ┌──────────────────────────┐  │
│  │ Prometheus           │            │ Jenkins controller       │  │
│  │ local-path PVC       │            │ 0 executors · 8 GiB PVC  │  │
│  └──────────────────────┘            ├──────────────────────────┤  │
│                                      │ CI/CD agent Pods          │  │
│                                      ├──────────────────────────┤  │
│                                      │ Grafana                   │  │
│                                      │ AlertManager              │  │
│                                      │ kube-state-metrics        │  │
│                                      │ Prometheus Operator       │  │
│                                      └──────────────────────────┘  │
│                                                                    │
│  every node: node-exporter + platform Fluent Bit                  │
│  observability namespace: Elasticsearch with local-path storage    │
│                                                                    │
└────────────────────────────────────────────────────────────────────┘
```

These services share the same DNS, TLS, storage, secret, and ingress foundations; they do not rebuild those concerns locally.

## Components

| Service | Purpose | Documentation |
|---|---|---|
| Jenkins | declarative CI/CD controller and Kubernetes agents | [`jenkins.md`](jenkins.md) |
| Observability | metrics, alerts, dashboards, and centralized logs | [`observability.md`](observability.md) |

## Placement strategy

The cluster is intentionally small. Platform placement is explicit instead of left to chance:

- Jenkins controller and Jenkins agents run on `node-3`.
- Prometheus runs on `node-2`.
- Grafana, AlertManager, kube-state-metrics, and Prometheus Operator run on `node-3`.
- node-exporter runs on each node.

This keeps Prometheus memory pressure away from Jenkins while still using both workers.

## Change rule

Chart versions, Helm values, JCasC, dashboards, alerts, and resource settings are changed in Git first. The normal operation is reconciliation from those files, not long-lived `kubectl edit` or Helm CLI state.

Implementation: [`platform/`](../../platform/).
