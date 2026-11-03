# Observability

`platform/observability/` owns metrics, alerts, dashboards, cluster
logs, application logs, Elasticsearch, and observability ingress.

## 1. Observability map

~~~text
                    METRICS

application
    │
nodes
    │
ingress-nginx
    │
    ▼
┌──────────────────────┐
│ Prometheus           │
│ node-2               │
└──────────┬───────────┘
           │
     ┌─────┴─────────────┐
     │                   │
     ▼                   ▼
┌──────────────┐   ┌──────────────┐
│ Grafana      │   │ alert rules  │
│ node-3       │   └──────┬───────┘
└──────────────┘          ▼
                   ┌──────────────┐
                   │ Alertmanager │
                   │ node-3       │
                   └──────────────┘


                     LOGS

container logs
      │
      ▼
Fluent Bit DaemonSet
      │
      ▼
┌──────────────────────┐
│ Elasticsearch        │
│ node-2               │
└──────────┬───────────┘
           ▼
        Grafana
~~~

Metrics and logs converge in Grafana, but they use separate collection
paths and separate storage engines.

## 2. Metrics path

~~~text
application
/actuator/prometheus
        │
        ▼
   ServiceMonitor
        │
        ▼
┌──────────────────────┐
│ Prometheus           │
│ scrape + retain      │
└──────────┬───────────┘
           │
           ▼
┌──────────────────────┐
│ Grafana dashboards   │
└──────────────────────┘
~~~

The application exposes Micrometer/Prometheus metrics through its
ServiceMonitor.

Ingress metrics follow a second path:

~~~text
ingress-nginx
      │ metrics
      ▼
additional ServiceMonitor
      │
      ▼
Prometheus
      │
      ├── Grafana
      │
      └── prod canary health check
~~~

Delivery reads ingress request metrics from Prometheus when evaluating a
production canary.

## 3. Alert path

~~~text
kube-state-metrics
        │
        ▼
Prometheus
        │
        ▼
PodContainerRestarted
        │
        │ increase over 5m > 0
        ▼
severity: warning
        │
        ▼
Alertmanager
~~~

The repository ships an explicit pod/container restart alert rather than
enabling the large default kube-prometheus rule set.

**Source:** [alerts/pod-restarts.yaml](alerts/pod-restarts.yaml)

## 4. Cluster log path

~~~text
every Kubernetes node
        │
        ▼
/var/log/containers/*.log
        │
        ▼
┌──────────────────────┐
│ Fluent Bit DaemonSet │
│ tail + metadata      │
└──────────┬───────────┘
           │
           ▼
┌──────────────────────┐
│ Elasticsearch        │
│ kubernetes-*         │
└──────────┬───────────┘
           ▼
┌──────────────────────┐
│ Grafana              │
│ Elasticsearch source │
└──────────────────────┘
~~~

Fluent Bit persists its tail database and buffers on the node so a Pod
restart does not immediately lose its read position.

## 5. Application file-log path

~~~text
Spring Boot
    │ async file appender
    ▼
/var/log/app/app.log
    │
    ▼
Fluent Bit sidecar
    │
    ▼
Elasticsearch
    │
    ▼
app-logs index
    │
    ▼
Grafana
~~~

This is deliberately separate from cluster-wide container collection.
The sidecar ships the application's own log file, which `kubectl logs`
never sees: stdout carries only WARN and above.

## 6. Workload placement

~~~text
node-2
┌────────────────────────┐
│ Prometheus             │
│ Elasticsearch          │
│ application workloads  │
└────────────────────────┘


node-3
┌────────────────────────┐
│ Grafana                │
│ Alertmanager           │
│ Prometheus Operator    │
│ kube-state-metrics     │
│ Jenkins                │
└────────────────────────┘


all nodes
┌────────────────────────┐
│ node-exporter          │
│ Fluent Bit             │
└────────────────────────┘
~~~

Placement is explicit to keep the small lab predictable.

## 7. Persistence

~~~text
Prometheus
    │
    ▼
local-path PVC
2 GiB
    │
    ├── retention: 1d
    └── retentionSize: 1500MB


Elasticsearch
    │
    ▼
local-path PVC
4 GiB
~~~

Data survives Pod recreation on the owning node. Local-path storage does
not provide cross-node storage HA.

## 8. Public vs internal access

~~~text
observability.lab.test
             │
             ▼
        ingress-nginx
             │
       ┌─────┴──────┐
       │            │
       ▼            ▼
 /grafana/     /prometheus/


Elasticsearch
      │
      ▼
/elasticsearch/
no authentication
~~~

Elasticsearch runs with security disabled and is served at
`/elasticsearch/` on the same host. That is only acceptable on a lab edge
network; see [weaknesses](../../docs/weaknesses.md).

## 9. Reconciliation

~~~text
make observability-up
        │
        ▼
worker capacity check
        │
        ▼
namespace + Helm repos
        │
        ▼
kube-prometheus-stack
        │
        ▼
Alertmanager ready
        │
        ▼
Elasticsearch + rules
        │
        ▼
Git-managed dashboards
        │
        ▼
Elasticsearch ready
        │
        ▼
Fluent Bit
        │
        ▼
observability ingress
        │
        ▼
wait for DNS
~~~

The script waits for the DNS record itself, so reconciliation does not
finish before the public endpoints are resolvable.

## 10. Smoke validation

~~~text
make observability-smoke
        │
        ▼
workloads ready
        │
        ▼
alert rule loaded
        │
        ▼
Grafana + Prometheus over HTTPS
        │
        ▼
kubernetes-* index exists
~~~

The smoke test proves the data path, not just Pod readiness.

## 11. Main files

| Path | Responsibility |
|---|---|
| `kube-prometheus-stack/values.yaml` | metrics, Grafana, Alertmanager |
| `elasticsearch/resources.yaml` | log store and persistence |
| `fluent-bit/values.yaml` | cluster log collector |
| `alerts/pod-restarts.yaml` | pod restart alert |
| `dashboards/` | Git-managed Grafana dashboards |
| `ingress.yaml` | Grafana/Prometheus public paths |
| `bin/up` | observability reconciliation |
| `bin/smoke` | workload/data-path smoke validation |

Dashboard and alert changes belong in Git. UI-only Grafana edits are not
source of truth.
