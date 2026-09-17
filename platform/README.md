# Platform

`platform/` owns Kubernetes-resident shared services. Host services stay under [`infra/`](../infra/README.md).

Detailed stage: [`docs/stage-03-platform-services.md`](../docs/stage-03-platform-services.md).

## Platform planes

```text
                         Kubernetes

       ╔══════════════════════════════════════════════════════╗
      ╱  Edge                                               ╱│
     ║  MetalLB · ingress-nginx · ExternalDNS · VSO          ║
     ╚═══════════════════════╤═══════════════════════════════╝
                             │
                             ▼
       ╔══════════════════════════════════════════════════════╗
      ╱  Delivery control                                  ╱│
     ║  Jenkins controller · CI runner · CD runner           ║
     ╚═══════════════════════╤═══════════════════════════════╝
                             │
                             ▼
       ╔══════════════════════════════════════════════════════╗
      ╱  Observability                                     ╱│
     ║  Prometheus · AlertManager · Grafana                  ║
     ║  Fluent Bit · Elasticsearch                           ║
     ╚═══════════════════════════════════════════════════════╝
```

These are shared services. The application itself remains under `app/`.

## Edge

Cluster-side edge control flow:

```text
Ingress / Service metadata
          │
          ▼
      ExternalDNS
          │ RFC2136 + TSIG
          ▼
         BIND9

Vault
  │ AppRole
  ▼
VSO
  │
  ├──► TLS Secret
  ├──► ExternalDNS TSIG Secret
  ├──► Jenkins credentials
  └──► registry pull Secret
```

Traffic path:

```text
host client
    │
    ▼
192.168.56.200
    │ MetalLB
    ▼
ingress-nginx ×2
    │
    ├──► app
    ├──► Jenkins
    └──► observability
```

MetalLB uses the explicit `192.168.56.200-220` pool with automatic allocation disabled. ingress-nginx owns `192.168.56.200` and is spread across workers.

Reconcile through the owning infrastructure entry point:

```bash
make edge-up
make edge-smoke
make edge-validate
```

Do not retain one-off Helm changes to individual edge components.

## Jenkins

```text
                       GitHub
                          │
                          ▼
              ┌──────────────────────┐
              │ Jenkins controller   │
              │ node-3              │
              │ 0 executors         │
              └──────────┬───────────┘
                         │ schedules
                 ┌───────┴───────┐
                 ▼               ▼
      ┌──────────────────┐  ┌──────────────────┐
      │ lab-ci-runner  │  │ lab-cd-runner  │
      │ node-3           │  │ node-3           │
      │ ci-tools         │  │ deployment tools │
      │ BuildKit         │  │ kubeconfig       │
      └──────────────────┘  └──────────────────┘
```

JCasC owns controller configuration, credentials, Kubernetes cloud configuration, both agent templates, and the `lab-build` / `lab-deploy` jobs.

The CI runner keeps Maven, Trivy, and BuildKit caches under `/var/lib/lab-ci/` on `node-3`. Cache state improves speed but is disposable; a cold build must still work.

Reconcile:

```bash
make jenkins-up
```

Endpoint: `https://jenkins.lab.test`.

Do not create durable Jenkins jobs or credentials in the UI. If it must survive rebuild, it belongs in JCasC/Vault.

## Observability

Metrics path:

```text
Kubernetes / workloads
        │ scrape
        ▼
Prometheus
   │
   ├──► Grafana dashboards
   │
   └──► PrometheusRule ──► AlertManager
```

Logging path:

```text
container stdout/stderr ──► node Fluent Bit ──┐
                                               ├──► Elasticsearch ──► Grafana
application.log ──► Pod Fluent Bit sidecar ───┘
```

The node daemon covers general Kubernetes container logs. The application sidecar specifically handles the application's asynchronous file log.

Reconcile and check:

```bash
make observability-up
make observability-smoke
```

Endpoints:

| Path | Service |
|---|---|
| `https://observability.lab.test/grafana/` | Grafana |
| `https://observability.lab.test/prometheus/` | Prometheus |
| `https://observability.lab.test/elasticsearch/` | Elasticsearch |

Prometheus and Elasticsearch use local-path PVCs. Jenkins does as well. These volumes survive Pod recreation; they do not provide cross-node storage HA.

## Change model

```text
change Git
   │
   ▼
run owning reconciliation command
   │
   ▼
observe rollout
   │
   ▼
run smoke / validation
```

Manual Helm upgrades and `kubectl edit` are diagnostic actions only. If a change is meant to persist, capture it under `platform/` and reconcile from Git.