# Platform

`platform/` owns Kubernetes-resident shared services. Host Vault, BIND9, CA, and resolver configuration remain under [`infra/`](../infra/README.md).

## Shared services

```text
┌────────────────────────── Kubernetes ──────────────────────────┐
│                                                               │
│  Edge                  Delivery                Observability   │
│  ────                  ────────                ─────────────   │
│  MetalLB               Jenkins controller      Prometheus      │
│  ingress-nginx         CI/CD agent Pods        AlertManager    │
│  ExternalDNS                                   Grafana         │
│  Vault Secrets Operator                        Elasticsearch   │
│                                                Fluent Bit      │
│                                                               │
└───────────────────────────────────────────────────────────────┘
```

The application itself stays under `app/`.

## Edge

```text
Kubernetes metadata ──► ExternalDNS ── signed RFC2136 ──► BIND9

host Vault ──► VSO ──► TLS / TSIG / credential Secrets

MetalLB ── assigns + L2-advertises ──► ingress Service · 192.168.56.200
                                               │
                                               ▼
                                      ingress-nginx ×2
                                               │
                         ┌─────────────────────┼─────────────────────┐
                         ▼                     ▼                     ▼
                        app                  Jenkins           observability
```

MetalLB automatic allocation is disabled for the edge pool. ingress-nginx explicitly owns `192.168.56.200` and is spread across workers.

Reconcile through the owning orchestrator:

```bash
make edge-up
make edge-smoke
make edge-validate
```

Details: [edge/README.md](edge/README.md).

## Jenkins

```text
Jenkins controller · node-3 · 0 executors
                  │ Kubernetes plugin
         ┌────────┴────────┐
         ▼                 ▼
lab-ci-runner      lab-cd-runner
node-3               node-3
ci-tools + BuildKit  deployment tools
```

JCasC owns controller configuration, credentials, Kubernetes cloud configuration, both agent templates, the `lab-delivery` library, and the delivery jobs (see [`delivery/`](../delivery/README.md)).

The CI runner keeps Trivy and BuildKit caches under `/var/lib/lab-ci/` on `node-3`. CI runs as the dry-run-only `jenkins-ci` ServiceAccount and CD as `jenkins-agent`; the split is a Kubernetes identity boundary enforced by the `jenkins-ci-dry-run-only` ValidatingAdmissionPolicy.

```bash
make jenkins-up
```

Endpoint: `https://jenkins.lab.test`.

Details: [jenkins/README.md](jenkins/README.md).

## Observability

```text
node-exporter / kube-state-metrics / targets
                  │ scrape
                  ▼
             Prometheus
              │      │
          query│      │firing alerts
              ▼      ▼
           Grafana  AlertManager

container logs ──► platform Fluent Bit ──┐
app.log ─► Pod sidecar Fluent Bit├──► Elasticsearch ──► Grafana
                                         ┘
```

Prometheus and Elasticsearch run on `node-2`. Grafana, AlertManager, kube-state-metrics, and Prometheus Operator run on `node-3`. Platform Fluent Bit and node-exporter run on every node.

```bash
make observability-up
make observability-smoke
```

Details: [observability/README.md](observability/README.md).

## Change model

```text
change desired state in Git
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

Manual Helm upgrades and `kubectl edit` are diagnostic actions only. Persistent changes belong under `platform/` and are reconciled from Git.
