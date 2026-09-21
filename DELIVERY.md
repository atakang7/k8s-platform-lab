# Delivery

This document describes the repository's delivery system as implemented on `main`: how source becomes an immutable artifact, how that artifact becomes desired state, and how desired state reaches Kubernetes.

The detailed operating notes remain next to the implementation:

[Delivery operations](delivery/README.md) · [Jenkins](platform/jenkins/README.md) · [Base chart](charts/service/README.md) · [Validation](validation/README.md)

## Table of contents

1. [Scope](#1-scope)
2. [Delivery model](#2-delivery-model)
3. [Release identity and Git state](#3-release-identity-and-git-state)
4. [Jenkins execution model](#4-jenkins-execution-model)
5. [Service CI](#5-service-ci)
6. [Platform CI](#6-platform-ci)
7. [Deployment and promotion](#7-deployment-and-promotion)
8. [Production canary](#8-production-canary)
9. [Failure and recovery](#9-failure-and-recovery)
10. [Security and permissions](#10-security-and-permissions)
11. [Performance model](#11-performance-model)
12. [Validation evidence and limits](#12-validation-evidence-and-limits)

---

## 1. Scope

Delivery owns:

- service validation, build, test, scan, publication and signing;
- OCI chart publication;
- immutable release state under `state/`;
- application deployment from that state;
- promotion pull requests between environments;
- release tags and rollback state.

Delivery does **not** own infrastructure or platform reconciliation.

~~~text
operator / make
    │
    ├── infrastructure
    ├── Jenkins
    ├── observability
    ├── environment identities
    └── admission policies

Jenkins
    │
    ├── validates platform changes
    ├── builds service artifacts
    ├── records application release state
    └── deploys application releases
~~~

The admission webhook is built by the service pipeline and recorded in Git like a service, but it is operator-installed because it is not listed under `releases` in `environments.yaml`.

The current lab cluster is the `dev` cluster. `stage` and `prod` remain separate delivery targets in Git and are intended to run on their own clusters.

---

## 2. Delivery model

The central rule is simple:

~~~text
source
  │
  ▼
validate
  │
  ▼
build once
  │
  ▼
scan exact build
  │
  ▼
publish exact build
  │
  ▼
sign digest
  │
  ▼
Git desired state
{version,image}
  │
  ▼
verify
  │
  ▼
deploy by digest
  │
  ▼
test
  │
  ▼
promote same artifact
~~~

The system is deliberately state-driven.

~~~text
service CI
    │
    │ commit
    ▼
state/dev.yaml
    │
    │ Git is the handoff
    ▼
deploy job
    │
    ▼
Kubernetes
~~~

CI does not invoke CD directly. Jenkins re-indexes GitHub every minute; the state commit is what makes the deployment job observe a new desired release.

Core invariants:

~~~text
build once
scan what is published
deploy by digest
promote without rebuilding
Git records desired release state
verify before changing runtime
environment permissions are isolated
~~~

---

## 3. Release identity and Git state

Application release identity is:

~~~text
Chart.yaml version
       +
published OCI image digest
       │
       ▼
{version,image}
~~~

`version` is the application version and Helm chart version.

`image` is the immutable OCI image digest.

Current state shape:

~~~yaml
sample-java-app:
  version: 1.2.14
  image: sha256:2758e8fba94b92423860dbb36245617c9163ad74fea23417308f17304dcd1824
~~~

State lives in:

~~~text
state/
├── dev.yaml
├── stage.yaml
└── prod.yaml
~~~

The environment order is defined once in `environments.yaml`:

~~~text
dev ──► stage ──► prod
~~~

A release may enter a later environment only after the same digest has appeared in the previous environment's Git history.

That check is historical, not merely a comparison with the previous environment's current state. `delivery.requirePromoted` searches the previous state file's Git history for the image digest.

Promotion therefore preserves artifact identity:

~~~text
dev
{1.2.14, sha256:abc}
        │
        ▼
stage
{1.2.14, sha256:abc}
        │
        ▼
prod
{1.2.14, sha256:abc}
~~~

No image rebuild occurs between environments.

Environment-specific configuration may change. The application artifact does not.

---

## 4. Jenkins execution model

Jenkins orchestrates delivery; Kubernetes agent Pods execute it.

The controller owns the queue, multibranch jobs, JCasC and the `lab-delivery` shared library. Its built-in node is disabled for Pipeline execution (`numExecutors: 0`), and the Helm chart's static agent is disabled. Execution capacity comes from Kubernetes-plugin Pods.

~~~text
Jenkins controller
      │
      │ schedules
      ▼
Kubernetes plugin
      │
      ├── lab-ci-runner       build + scan
      ├── lab-ci-light        lint + verify
      └── lab-cd-runner-<env> deployment
~~~

Four multibranch delivery jobs use three pipeline implementations:

| Job | Implementation | Execution path |
|---|---|---|
| `sample-java-app` | `servicePipeline` | heavy CI |
| `resource-requests-webhook` | `servicePipeline` | heavy CI |
| `platform` | `Jenkinsfile.platform` | light CI |
| `deploy` | `deployPipeline` | light verification → environment CD |

The execution identities are different by purpose:

~~~text
CI
lab-ci-runner / lab-ci-light
        │
        ▼
jenkins-ci
dry-run validation only

CD
lab-cd-runner-<environment>
        │
        ▼
jenkins-deploy-<environment>
environment namespace only
~~~

JCasC also creates one warm job for each active execution class so the Kubernetes plugin can keep reusable agent Pods during their idle window.

Controller topology, agent Pod composition, Vault wiring, warm-agent behavior and reconciliation are documented in [`platform/jenkins/README.md`](platform/jenkins/README.md).

---

## 5. Service CI

A service plugs into delivery with a chart, build context and path:

~~~groovy
@Library('lab-delivery') _
servicePipeline(
    chart: 'app/chart',
    context: 'app',
    path: 'app/'
)
~~~

### Flow

~~~text
Checkout
   │
   ▼
Validate
   │
   ▼
Build
   │
   ▼
Scan
   │
   └────────────── PR stops here
   │
   ▼ main
Publish image
   │
   ▼
Verify pushed digest
   │
   ▼
Sign digest
   │
   ▼
Publish chart
   │
   ▼
Record dev state
~~~

### Checkout

The pipeline derives the service source identity from the last Git commit that changed that service path.

That source revision is embedded in the image as `org.opencontainers.image.revision` and is later used to prevent an existing version from being silently reused for different source.

### Validate

For Jenkins-released services such as `sample-java-app`:

~~~text
Hadolint
   +
PR version bump check
   +
Helm render
   +
server-side dry-run
   +
admission chain
~~~

The dry-run uses a placeholder digest before the image exists.

For `resource-requests-webhook`, which Jenkins builds but does not release, validation uses `helm lint` rather than the release server-side dry-run.

### Build

BuildKit produces one OCI layout:

~~~text
source
  │
  ▼
Dockerfile
  │
  ├── Maven build
  └── unit tests
  │
  ▼
app-image/
~~~

There is no second image build later.

`app-image/` is both:

- the object Trivy scans;
- the object publication pushes.

### Scan

Trivy scans the OCI layout and:

- fails the build on any `CRITICAL` vulnerability;
- prints findings in the build log;
- creates a CycloneDX SBOM;
- archives the SBOM with the Jenkins build.

~~~text
app-image/
   │
   ▼
Trivy
   │
   ├── CRITICAL found ──► fail
   │
   └── clean ───────────► continue
~~~

### Publish

Publication runs only on `main`.

The pipeline:

1. checks whether `<image>:<version>` already exists;
2. if it exists, verifies its recorded source revision matches this service revision;
3. otherwise pushes the exact scanned OCI layout;
4. verifies the registry digest equals the scanned manifest digest;
5. signs `repository@sha256:...` with Cosign;
6. publishes the service chart;
7. commits `{version,image}` into `state/dev.yaml`.

A version already published from different source fails. The version must be raised.

A version already published from the same service revision may be reused. This makes retries idempotent without allowing mutable release identity.

---

## 6. Platform CI

The `platform` job validates repository-owned delivery/platform material but does not reconcile infrastructure.

~~~text
platform job
    │
    ├── Shellcheck
    │
    ├── PR + charts/** ──► ct lint + version increment check
    │
    └── main ────────────► publish missing base-chart versions
~~~

Shellcheck scans `*.sh` files and `bin/` helpers under:

~~~text
delivery/
infra/
platform/
policies/
validation/
~~~

Base charts are published idempotently. An already published chart version is skipped; a missing version is caught by the next `main` build.

Platform and infrastructure changes are still applied by the operator through repository commands such as `make jenkins-up`, `make environment-up` and the other component-specific reconciliation targets.

---

## 7. Deployment and promotion

The deploy job is a multibranch job over the same repository.

State or `environments.yaml` changes cause the deployment pipeline to run.

~~~text
state change
    │
    ▼
Verify
    │
    ▼ main only
Deploy
    │
    ▼
Helm test
    │
    ▼
Tag healthy environment
    │
    ▼
Open promotion PR
~~~

### Verify

The pipeline first validates the repository contract while reading it:

- environment configuration;
- state schema;
- `{version,image}` format;
- environment ordering.

For every recorded later-environment release it checks promotion history.

For releases owned by this cluster it additionally verifies:

~~~text
recorded image digest
       │
       ▼
Cosign signature
       │
       ▼
Helm render
       │
       ▼
kubectl --dry-run=server
       │
       ▼
API validation + admission
~~~

Verification happens before runtime is changed.

### Deploy

Deployment runs only from `main` and only for `clusterEnvironment`.

The lab configuration is:

~~~yaml
clusterEnvironment: dev
~~~

The deploy Pod runs under the environment-specific Kubernetes identity:

~~~text
lab-cd-runner-dev
        │
        ▼
ServiceAccount
jenkins-deploy-dev
        │
        ▼
apps-dev only
~~~

For each release, Helm receives the recorded digest and deploys the chart with:

- `helm upgrade --install`;
- `--wait`;
- five-minute timeout;
- rollback on readiness failure;
- release history limited to five revisions.

The deploy identity intentionally cannot read Kubernetes Secrets, so Helm release metadata uses the ConfigMap storage driver.

A release already running both the expected chart version and expected digest is skipped.

### Test

After a successful rollout:

~~~text
helm test
    │
    ├── base chart smoke test
    └── service-owned tests
~~~

The environment is not tagged or promoted unless all owned releases complete their tests.

### Release tag

A healthy environment is recorded as:

~~~text
<environment>-<YYYY.MM.DD>.<n>
~~~

Example:

~~~text
dev-2026.09.21.5
~~~

A tag represents the complete state of that environment at a known healthy point.

### Promotion

After a healthy release, Jenkins opens or refreshes a promotion pull request for each service whose next-environment state differs.

~~~text
dev healthy
    │
    ▼
promote/stage/<service>
    │
    ▼
PR changes state/stage.yaml
    │
    ▼
merge
    │
    ▼
stage deploy
~~~

The same mechanism advances `stage → prod`.

`CODEOWNERS` declares ownership for:

~~~text
state/stage.yaml
state/prod.yaml
environments.yaml
~~~

That approval boundary is effective only when the repository's `main` protection requires code-owner review.

---

## 8. Production canary

`prod` currently defines:

~~~yaml
canary:
  weight: 10
  minutes: 5
  maxErrorRate: 0.01
~~~

When a stable release already exists:

~~~text
new release
    │
    ▼
1-replica canary
    │
    ▼
10% ingress traffic
    │
    ▼
Prometheus ingress 5xx ratio
    │
    ├── > 1% ──► fail; remove canary; stable untouched
    │
    └── ≤ 1% ──► continue observation
                         │
                         ▼
                  stable deployment
                         │
                         ▼
                  remove canary
~~~

The canary is observed for five minutes and queried through ingress-nginx metrics in Prometheus.

A first installation skips canary evaluation because no stable release exists for comparison.

If the canary receives no measurable traffic during the observation window, the implementation currently warns and continues.

---

## 9. Failure and recovery

Delivery is fail-closed before publication and conservative after runtime changes.

| Failure | Result |
|---|---|
| lint / version / dry-run failure | build stops |
| unit-test failure inside image build | image is not produced |
| CRITICAL vulnerability | publication stops |
| reused version from different source | publication stops |
| registry digest differs from scanned digest | publication stops |
| signature verification failure | deployment stops before runtime change |
| promotion-history failure | deployment stops |
| Helm readiness failure | Helm restores the previous successful release |
| Helm test failure | previous revision is restored; first install is removed |
| canary error rate above threshold | canary is removed; stable release remains |
| promotion PR not merged | next environment remains unchanged |

Runtime rollback and desired-state rollback are intentionally separate.

~~~text
Git wants 1.2.14
      │
      ▼
deploy fails
      │
      ▼
runtime returns to 1.2.13
      │
      ▼
Git still wants 1.2.14
~~~

The failed state is not silently rewritten.

The deploy job will continue to see the desired release until someone:

- fixes the release; or
- changes Git state.

A deliberate rollback restores a previous healthy environment tag's state in a pull request.

---

## 10. Security and permissions

### Artifact trust

~~~text
source
  │
  ▼
BuildKit
  │
  ▼
unit tests
  │
  ▼
Trivy
  │
  ▼
exact OCI artifact
  │
  ▼
registry digest verification
  │
  ▼
Cosign signature
  │
  ▼
Git state
  │
  ▼
Cosign verification
  │
  ▼
server-side dry-run
  │
  ▼
Kubernetes
~~~

For Jenkins-released services on this cluster, deploy verification refuses a recorded image that is not signed by the delivery key committed as `cosign.pub`.

The private signing key and password are delivered to Jenkins from Vault-backed credentials.

Cosign uses key-based verification and deliberately disables transparency-log upload.

### Credential ownership

| System | Stores / owns |
|---|---|
| Git | source, delivery configuration, desired `{version,image}` state |
| OCI registry | application images and Helm charts |
| Vault / VSO | external Jenkins credentials and runtime secret material |
| Jenkins | execution and injected delivery credentials |
| Kubernetes | runtime objects and environment-scoped identities |

No kubeconfig is stored as a Jenkins deployment credential.

CI and CD use Kubernetes ServiceAccounts.

### CI identity

`jenkins-ci` is allowed to perform the server-side validation path but is not allowed to make real application writes.

### CD identity

Each environment gets a separate identity:

~~~text
jenkins-deploy-dev
jenkins-deploy-stage
jenkins-deploy-prod
~~~

The identity may manage release objects only in its environment namespace and cannot read Secrets.

This means application deployment authority is environment-scoped even if Jenkins itself is compromised at the job level.

### Desired state contains no secrets

State files contain only release identity:

~~~yaml
version: 1.2.14
image: sha256:...
~~~

Secrets and configuration remain separate from artifact identity.

---

## 11. Performance model

The pipeline separates expensive and lightweight work.

~~~text
heavy CI runner
build + scan
persistent caches
      │
      ├──────────────┐
      │              │
      ▼              ▼
light runner      CD runner
validation        deployment
~~~

Optimizations implemented in the repository:

| Mechanism | Effect |
|---|---|
| warm agent Pods | avoids normal Kubernetes agent cold start |
| persistent BuildKit state | reuses image and Maven build layers |
| persistent Trivy cache | reuses vulnerability database data |
| dedicated light runner | lint/verification do not wait for image builds |
| service path filtering | unrelated changes skip service work |
| idempotent chart publication | existing versions are skipped |
| source-aware image reuse | safe retry without rebuilding published source |
| state-driven CD | deployment never rebuilds the image |
| current-release check | unchanged Helm release is skipped |

Observed during the validated `sample-java-app 1.2.14` release:

~~~text
warm agent acquisition   ~5s
cold agent acquisition  ~51s

CI                     1m26s
CD                     1m16s
                       ─────
Jenkins execution      2m42s
~~~

Jenkins cannot receive GitHub webhooks in this lab, so each multibranch job re-indexes GitHub once per minute. End-to-end wall time can therefore include a polling interval before CI and another before CD.

---

## 12. Validation evidence and limits

### Verified release trace

The current `dev` state records:

~~~text
sample-java-app 1.2.14
        │
        ▼
sha256:2758e8fba94b92423860dbb36245617c9163ad74fea23417308f17304dcd1824
        │
        ▼
Git state commit
75769b4736f47ed7801c545eb7cd937b42ff494b
        │
        ▼
deploy/main #24
        │
        ▼
dev-2026.09.21.5
~~~

Commit `75769b4` is the delivery-generated commit:

~~~text
Deploy sample-java-app 1.2.14 to dev
~~~

The environment tag `dev-2026.09.21.5` exists for the validated release state.

### End-to-end platform proof

The repository's final validator is:

~~~bash
make e2e-validate
~~~

It composes the lower-level checks and proves the running platform contract, including:

- cluster and edge validation;
- admission policy behavior;
- Jenkins placement, persistence, HTTPS and built-in-node execution policy;
- immutable application image deployment;
- application runtime security and replica placement;
- DNS and HTTPS request path;
- Prometheus application metrics;
- Grafana provisioning;
- application log delivery to Elasticsearch.

### Implementation entry points

| Concern | Source |
|---|---|
| service CI | `delivery/pipeline/vars/servicePipeline.groovy` |
| deployment | `delivery/pipeline/vars/deployPipeline.groovy` |
| shared state/promotion helpers | `delivery/pipeline/vars/delivery.groovy` |
| platform CI | `delivery/Jenkinsfile.platform` |
| build | `delivery/pipeline/resources/lab/delivery/build-image.sh` |
| scan | `delivery/pipeline/resources/lab/delivery/scan-image.sh` |
| publication/signing | `delivery/pipeline/resources/lab/delivery/publish-image.sh` |
| release verification | `delivery/pipeline/resources/lab/delivery/validate-release.sh` |
| runtime deployment/canary | `delivery/pipeline/resources/lab/delivery/deploy.sh` |
| Jenkins topology | `platform/jenkins/jcasc/jenkins.yaml` |
| environment contract | `environments.yaml` |
| desired state | `state/*.yaml` |

### Known limits

~~~text
vulnerability gate: CRITICAL only
SBOM: generated and archived, not attested
Cosign: transparency-log upload disabled
canary: no traffic warns and passes
promotion approval: depends on branch protection enforcing CODEOWNERS
lab runtime: dev exercised; stage/prod/canary paths implemented but not exercised here
~~~

These are explicit boundaries of the implementation, not hidden assumptions.
