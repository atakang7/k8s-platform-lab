# Platform

`platform/` contains Kubernetes-resident shared services. Host services remain under [`infra/`](../infra/README.md).

```text
                         Kubernetes
┌────────────────────────────────────────────────────────────────────┐
│                                                                    │
│  Edge                         Delivery control                     │
│  MetalLB                      Jenkins controller                   │
│  ingress-nginx                CI/CD agents                         │
│  ExternalDNS                  Vault-sourced credentials            │
│  Vault Secrets Operator                                           │
│                                                                    │
│  Observability                                                     │
│  Prometheus · AlertManager · Grafana · Fluent Bit · Elasticsearch │
│                                                                    │
└────────────────────────────────────────────────────────────────────┘
```

## Edge

`edge/` provides the cluster side of the ingress, DNS, and secrets path.

```text
BIND9 ← RFC2136 ← ExternalDNS
                      │
Vault ── VSO ── TLS / TSIG Secrets
                      │
MetalLB ── 192.168.56.200 ── ingress-nginx ×2
```

- MetalLB uses the explicit `192.168.56.200-220` pool.
- ingress-nginx runs two replicas across workers and owns `192.168.56.200`.
- ExternalDNS writes `lab.test` records through authenticated RFC2136 updates.
- VSO reads narrowly scoped values from the host Vault and creates runtime Kubernetes Secrets.

Lifecycle is orchestrated by the infrastructure entry point:

```bash
make edge-up
make edge-smoke
make edge-validate
```

Do not install or upgrade individual edge charts manually unless diagnosing a failed reconciliation. Version pins and values in Git define the expected state.

## Jenkins

`jenkins/` defines the controller through the official Helm chart and JCasC.

```text
jenkins.lab.test
          │
     ingress-nginx
          │
   Jenkins controller
   node-3 · 0 executors
      ┌───┴───────────────┐
      │                   │
 lab-ci-runner     lab-cd-runner
 node-3              node-3
```

The controller is intentionally not a build worker. JCasC creates two exclusive Kubernetes agent templates:

- `lab-ci-runner`: CI tools + BuildKit, with host-backed Maven, Trivy, and BuildKit caches.
- `lab-cd-runner`: deployment tooling and cluster credentials.

Both templates are pinned to `node-3`, matching the controller placement requirement while keeping build execution outside the controller container.

JCasC also creates `lab-build` and `lab-deploy`. Credentials are sourced from Vault through VSO.

```bash
make jenkins-up
```

The controller URL is `https://jenkins.lab.test`.

## Observability

`observability/` installs the metrics and logging stack.

```text
Kubernetes metrics ── Prometheus ── Grafana
Pod restarts ──────── PrometheusRule ── AlertManager

container logs ── Fluent Bit ──┐
application file logs ─ sidecar ├── Elasticsearch ── Grafana logs dashboard
                               ┘
```

Reconcile and verify:

```bash
make observability-up
make observability-smoke
```

The stack is exposed behind the existing ingress and wildcard TLS certificate:

- `https://observability.lab.test/grafana/`
- `https://observability.lab.test/prometheus/`
- `https://observability.lab.test/elasticsearch/`

Prometheus and Elasticsearch use local-path PVCs. They survive Pod recreation but are not protected from loss of the node holding the local volume.

## Change model

Change chart versions, values, JCasC, alerts, dashboards, or resources in Git first. Re-run the corresponding reconciliation command. Avoid retaining manual Helm or `kubectl edit` changes as operational state.