# Delivery

This is the map of how a service moves through the repository: source → immutable artifact → Git state → Kubernetes.

[Delivery implementation](delivery/README.md) · [Jenkins](platform/jenkins/README.md) · [Base chart](charts/service/README.md)

## Contents

1. [Model](#1-model)
2. [Where it is configured](#2-where-it-is-configured)
3. [Service CI](#3-service-ci)
4. [Deploy and promotion](#4-deploy-and-promotion)
5. [Security and failure behavior](#5-security-and-failure-behavior)
6. [Operate and validate](#6-operate-and-validate)

---

## 1. Model

The delivery contract is:

```text
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
publish + sign
  │
  ▼
Git state
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
```

CI and CD are decoupled through Git.

```text
service CI
    │
    │ commits release
    ▼
state/dev.yaml
    │
    ▼
deploy job
    │
    ▼
Kubernetes
```

A release is identified by:

```text
chart version + image digest
```

Literal state:

```yaml
sample-java-app:
  version: 1.2.14
  image: sha256:2758e8...
```

`image` contains the OCI digest. The same `{version,image}` moves between environments; it is not rebuilt.

---

## 2. Where it is configured

| Concern | Source of truth |
|---|---|
| Environment order, namespaces, deploy-owned services, canary | `environments.yaml` |
| Desired release per environment | `state/dev.yaml`, `state/stage.yaml`, `state/prod.yaml` |
| Service CI flow | `delivery/pipeline/vars/servicePipeline.groovy` |
| Deployment / promotion flow | `delivery/pipeline/vars/deployPipeline.groovy` |
| State and promotion helpers | `delivery/pipeline/vars/delivery.groovy` |
| Build / scan / publish / deploy steps | `delivery/pipeline/resources/lab/delivery/` |
| Platform validation job | `delivery/Jenkinsfile.platform` |
| Jenkins jobs and agents | `platform/jenkins/jcasc/jenkins.yaml` |
| Promotion ownership | `.github/CODEOWNERS` |
| Shared service runtime defaults | `charts/service/` |

Current environment order:

```text
dev ──► stage ──► prod
```

The current lab cluster runs:

```yaml
clusterEnvironment: dev
```

One cluster runs one environment. The deploy job only acts on that cluster's configured environment.

---

## 3. Service CI

A service connects to the shared pipeline with a small Jenkinsfile:

```groovy
@Library('lab-delivery') _
servicePipeline(
    chart: 'app/chart',
    context: 'app',
    path: 'app/'
)
```

Flow:

```text
PR / main
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
   ├── PR ends here
   │
   ▼ main
Publish image + chart
   │
   ▼
Sign image digest
   │
   ▼
Record state/dev.yaml
```

The important implementation rule is **build once**:

```text
BuildKit
   │
   ▼
app-image/
   │
   ├── Trivy scans this
   └── registry receives this
```

There is no rebuild after scanning.

### Validation

For Jenkins-released services such as `sample-java-app`:

```text
Hadolint
version check
Helm render
server-side dry-run
admission
```

The operator-owned `resource-requests-webhook` is built by the same service pipeline but only Helm-linted there; Jenkins does not release it because it is not listed under `releases` in `environments.yaml`.

### Publication

On `main`:

- the exact scanned image is pushed;
- the registry digest is checked against the scanned manifest;
- the digest is signed with Cosign;
- the chart is published;
- `{version,image}` is committed to `state/dev.yaml`.

A published version can be reused only when it belongs to the same service source revision. Different source requires a new version.

---

## 4. Deploy and promotion

A state change drives deployment.

```text
state/<env>.yaml
      │
      ▼
Verify
      │
      ▼
Deploy
      │
      ▼
Helm test
      │
      ▼
tag healthy state
      │
      ▼
promotion PR
```

### Verify

Before changing runtime, the deploy job checks:

```text
state schema
   +
promotion history
   +
Cosign signature
   +
Helm render
   +
server-side dry-run
```

A release may enter a later environment only if the same image digest appeared in the previous environment's Git history.

### Deploy

The recorded digest is passed to Helm:

```text
state/dev.yaml
    │
    ▼
sample-java-app
version: 1.2.14
image: sha256:abc
    │
    ▼
Helm
    │
    ▼
image repository@sha256:abc
```

After rollout, `helm test` runs the base smoke test and any service-owned tests.

A healthy environment is tagged:

```text
dev-2026.09.21.5
stage-...
prod-...
```

Then Jenkins opens or refreshes the next promotion PR.

```text
dev healthy
   │
   ▼
PR: state/stage.yaml
   │
   ▼
stage healthy
   │
   ▼
PR: state/prod.yaml
```

`CODEOWNERS` covers stage/prod state and `environments.yaml`; branch protection must require code-owner review for that approval boundary to be enforced.

### Production canary

Prod is configured in `environments.yaml`:

```yaml
canary:
  weight: 10
  minutes: 5
  maxErrorRate: 0.01
```

When a stable release already exists, the new release first receives 10% traffic. Ingress 5xx rate is checked in Prometheus before the stable release is replaced.

---

## 5. Security and failure behavior

Artifact trust:

```text
build
  ▼
scan
  ▼
publish exact digest
  ▼
Cosign sign
  ▼
Git state
  ▼
Cosign verify
  ▼
server-side dry-run
  ▼
deploy
```

Jenkins does not store a deployment kubeconfig.

```text
CI: jenkins-ci
    └── server-side dry-run only

CD: jenkins-deploy-<environment>
    └── own environment namespace only
```

See [Jenkins](platform/jenkins/README.md) for how those identities are configured.

Failure behavior is intentionally simple:

```text
validation / scan / signature failure
    └── stop before deploy

readiness failure
    └── Helm rollback

Helm test failure
    └── rollback previous revision
       or uninstall failed first install

bad prod canary
    └── remove canary
       stable release stays
```

A runtime rollback does **not** rewrite Git state. Git still contains the desired release until it is fixed or reverted.

A deliberate rollback is a Git change restoring an earlier healthy state.

---

## 6. Operate and validate

### Common changes

| Change | Edit |
|---|---|
| service CI behavior | `servicePipeline.groovy` / delivery scripts |
| deployment behavior | `deployPipeline.groovy` / `deploy.sh` |
| environment order / namespace / canary | `environments.yaml` |
| desired release | `state/<environment>.yaml` |
| promotion ownership | `.github/CODEOWNERS` |
| Jenkins job / agent configuration | `platform/jenkins/jcasc/jenkins.yaml` |
| shared runtime defaults | `charts/service/` |
| service-specific runtime values | service chart `values*.yaml` |

Platform and infrastructure are reconciled by the operator; Jenkins does not apply them.

Useful entry points:

```bash
make jenkins-up
make environment-up
make policies-up
make e2e-validate
```

`make e2e-validate` is the final running-platform proof. It validates the cluster/edge path, Jenkins, admission policy, deployed application, DNS/HTTPS, metrics and log delivery.

For lower-level implementation details, follow the component READMEs rather than expanding this document.
