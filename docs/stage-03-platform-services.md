# Stage 3 — Shared platform services

This stage installs the long-running services used by delivery and operations: Jenkins, metrics, alerting, dashboards, log collection, and Elasticsearch.

## Placement

```text
                     Kubernetes workers

      node-2                                      node-3
┌──────────────────────┐                   ┌──────────────────────┐
│ application capacity │                   │ Jenkins controller   │
│ Prometheus           │                   │ CI/CD agents         │
│ Elasticsearch        │                   │ Grafana              │
│                      │                   │ AlertManager         │
└──────────────────────┘                   └──────────────────────┘

            local-path PVCs remain node-local
```

Jenkins is pinned to `node-3`. Its controller has zero executors. Build and deployment work runs in dedicated Kubernetes agents, also pinned to `node-3`.

## Jenkins control flow

```text
                     GitHub
                       │
                       │ SCM poll
                       ▼
          ┌────────────────────────┐
          │ Jenkins controller     │
          │ node-3 · 0 executors   │
          │ JCasC owns config/jobs │
          └───────────┬────────────┘
                      │ schedules
             ┌────────┴─────────┐
             ▼                  ▼
┌─────────────────────┐  ┌─────────────────────┐
│ lab-ci-runner     │  │ lab-cd-runner     │
│ node-3              │  │ node-3              │
│ ci-tools + BuildKit │  │ deployment tooling  │
└─────────────────────┘  └─────────────────────┘
```

JCasC defines the controller configuration, credentials, Kubernetes cloud, agent templates, `lab-build`, and `lab-deploy`. Do not recreate persistent Jenkins state manually in the UI.

The CI runner keeps Maven, Trivy, and BuildKit caches on host paths under `/var/lib/lab-ci/`. One warm CI runner and one warm CD runner reduce startup overhead without turning the Jenkins controller into a worker.

## Jenkins secrets

```text
Vault
  │
  │ VSO
  ▼
jenkins namespace
  │
  ├── jenkins-admin
  ├── github-creds
  └── dockerhub-creds
          │
          ▼
        JCasC
```

The controller password and CI credentials originate in Vault. Kubernetes receives runtime copies. JCasC resolves those values into Jenkins credentials at startup/reconciliation.

Reconcile Jenkins:

```bash
make jenkins-up
```

Endpoint: `https://jenkins.lab.test`.

## Metrics and alert flow

```text
Kubernetes / workloads
          │ scrape
          ▼
┌──────────────────────┐
│ Prometheus           │
└──────────┬───────────┘
           │
           ├──────────────► Grafana dashboards
           │
           └── rules ─────► AlertManager
                            │
                            └── Pod restart alert route
```

The repository provisions the dashboard ConfigMaps and the restart `PrometheusRule`. AlertManager keeps the route internally; no external notification provider is required by this environment.

## Log flow

There are two collection paths with different purposes.

```text
Kubernetes container stdout/stderr
               │
               ▼
        node Fluent Bit
               │
               │
               ├─────────────────────────────┐
               │                             │
application.log inside each app Pod          │
               │                             │
               ▼                             │
      sidecar Fluent Bit                     │
               │                             │
               └──────────────┬──────────────┘
                              ▼
                     ┌────────────────┐
                     │ Elasticsearch  │
                     └───────┬────────┘
                             ▼
                       Grafana logs
```

The node-level Fluent Bit covers Kubernetes container logs. The application sidecar handles the explicit asynchronous file-log requirement without coupling the Java process to network log delivery.

## Observability lifecycle

```bash
make observability-up
make observability-smoke
```

The shared hostname is `observability.lab.test`:

| Path | Service |
|---|---|
| `/grafana/` | Grafana |
| `/prometheus/` | Prometheus |
| `/elasticsearch/` | Elasticsearch |

All three reuse ExternalDNS, ingress-nginx, and the wildcard TLS secret from Stage 2.

## Storage strategy

Prometheus, Elasticsearch, and Jenkins use local-path storage because the environment has only two worker nodes and no external storage system. Pod recreation is supported. Worker loss is not storage-HA; the PVC data is tied to the node that owns the local path.

This is an explicit environment constraint, not an implicit availability claim.

## Change strategy

Chart versions, values, JCasC, alerts, dashboards, and Kubernetes resources are changed in Git first. Re-run the owning reconciliation command. Manual Helm upgrades or `kubectl edit` changes are diagnostic only and must not become permanent state.

## Source paths

`platform/jenkins/` owns Jenkins. `platform/observability/` owns metrics, alerts, dashboards, Fluent Bit, Elasticsearch, and the observability ingress. Detailed delivery behavior is documented in Stage 5.