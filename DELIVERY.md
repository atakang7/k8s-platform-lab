# Delivery

CI/CD reference for application and platform delivery.

[Operations](delivery/README.md) · [Jenkins](platform/jenkins/README.md) · [Base chart](charts/service/README.md)

## Contents

1. [Model](#1-model)
2. [Pipelines](#2-pipelines)
3. [Release flow](#3-release-flow)
4. [Deployment](#4-deployment)
5. [Failure behavior](#5-failure-behavior)
6. [Security](#6-security)
7. [Performance](#7-performance)
8. [Evidence and limits](#8-evidence-and-limits)

---

## 1. Model

```text
source
  │
  ▼
Service CI
  │
  ├─ test
  ├─ build
  ├─ scan
  ├─ publish
  └─ sign
  │
  ▼
Git state
{version,image}
  │
  ▼
Deployment
  │
  ├─ verify
  ├─ deploy
  └─ test
  │
  ▼
Kubernetes
```

Core rules:

```text
build once
deploy by digest
promote the same artifact
Git stores desired release state
CI does not call CD directly
verify before changing runtime
```

Application state lives in:

```text
state/
├── dev.yaml
├── stage.yaml
└── prod.yaml
```

Platform and infrastructure reconciliation are operator-owned.

---

## 2. Pipelines

Four Jenkins jobs use three implementations:

| Job                         | Pipeline               | Purpose                     |
| --------------------------- | ---------------------- | --------------------------- |
| `sample-java-app`           | `servicePipeline`      | application CI              |
| `resource-requests-webhook` | `servicePipeline`      | application CI              |
| `platform`                  | `Jenkinsfile.platform` | platform validation/publish |
| `deploy`                    | `deployPipeline`       | application CD              |

### Service CI

```text
Checkout → Validate → Build/Test → Scan
                                  │
                               main only
                                  ▼
                              Publish
                                  ▼
                            Record dev state
```

| Stage      | Work                                                    |
| ---------- | ------------------------------------------------------- |
| Checkout   | read chart/state; derive service source revision        |
| Validate   | Hadolint · version check · Helm render · server dry-run¹ |
| Build/Test | one BuildKit build; Maven/JUnit run inside the Dockerfile |
| Scan       | Trivy CRITICAL gate · CycloneDX SBOM                    |
| Publish    | OCI image/chart · digest verify · Cosign sign           |
| Record     | commit `{version,image}` to dev state                  |

¹ Jenkins-released services only. `resource-requests-webhook` gets `helm lint` and is installed by the operator.

PRs stop after scan.

Existing versions may be reused only when their recorded source revision matches the current service revision.

### Platform CI

```text
Shellcheck
    │
    ├─ chart PR   → ct lint + version check
    └─ main       → publish missing OCI chart versions
```

`charts/service` provides the shared runtime defaults for stateless HTTP services:

```text
Deployment · Service · probes · security defaults
topology spread · optional PDB · ingress · metrics · Helm test
```

---

## 3. Release flow

`Chart.yaml.version` is the application release version.

```text
source revision
      ↓
   version
      ↓
    digest
      ↓
  Git state
      ↓
  workload
```

Example state:

```yaml
sample-java-app:
  version: 1.2.14
  image: sha256:2758e8...dcd1824   # image digest
```

Promotion copies the same release identity:

```text
dev
{1.2.14, abc}
      │
      ▼
stage
{1.2.14, abc}
      │
      ▼
prod
{1.2.14, abc}
```

No rebuild occurs between environments.

Configuration and secrets may differ by environment; application artifact identity does not.

The Git state commit is the CI → CD handoff:

```text
servicePipeline
      │
      ▼
state/dev.yaml
      │
      ▼
Git
      │
      ▼
deployPipeline
```

---

## 4. Deployment

```text
Verify → Deploy → Test → Tag → Promote
```

| Stage   | Work                                                                     |
| ------- | ------------------------------------------------------------------------ |
| Verify  | state schema · promotion history · Cosign · Helm render · server dry-run |
| Deploy  | Helm with `repository@sha256:...`                                        |
| Test    | HTTP smoke + service Helm tests                                          |
| Tag     | `<environment>-<YYYY.MM.DD>.<n>`                                         |
| Promote | PR copies `{version,image}` to next environment                         |

The deployment job only acts on its configured `clusterEnvironment`.

### Production canary

```text
10% traffic
    ↓
5 minutes
    ↓
ingress 5xx
  │      │
≤1%     >1%
 │       │
continue fail
```

The canary is skipped on a first install: there is no stable release to compare. A no-traffic canary currently warns and passes.

---

## 5. Failure behavior

```text
Verify failure ─────────► stop
Deploy/readiness failure ► rollback
Helm test failure ──────► rollback
First install failure ──► uninstall
Promotion failure ──────► target unchanged
```

Rollback restores a previously known release:

```text
{1.2.14, new}
      │
      ▼
{1.2.13, old}
```

It does not rebuild an old version or mutate image tags.

An automatic rollback does not change Git: the state file still names the failed release, and the deploy job retries it after every failed build until someone reverts or fixes the state. A deliberate rollback is a PR restoring an earlier `<environment>-…` tag's state.

---

## 6. Security

```text
source
  ↓
BuildKit
  ↓
tests
  ↓
Trivy
  ↓
OCI artifact
  ↓
digest verification
  ↓
Cosign
  ↓
Git state
  ↓
deployment verification
  ↓
Kubernetes
```

| System       | Stores / owns                       |
| ------------ | ----------------------------------- |
| Git          | source + desired `{version,image}` |
| OCI registry | images · charts                     |
| Vault/VSO    | Jenkins credentials · runtime secrets |
| Jenkins      | delivery credentials / execution    |
| Kubernetes   | runtime                             |

Deployment state contains artifact identity, not secrets.

The CycloneDX SBOM is archived with the Jenkins build.

Stage/prod promotion is gated by `CODEOWNERS` only while `main`'s branch protection requires code-owner review. Without it, anyone who can merge can deploy to prod.

---

## 7. Performance

```text
light runners → validation
heavy runners → build / scan
CD runners    → deployment
```

Optimizations:

| Mechanism                 | Effect                         |
| ------------------------- | ------------------------------ |
| warm runners              | acquisition ~5s (cold ~51s)    |
| persistent BuildKit state | image/Maven cache reuse        |
| persistent Trivy cache    | vulnerability DB reuse         |
| path filtering            | unrelated changes skip CI      |
| artifact checks           | duplicate publish skipped      |
| state-driven CD           | no rebuild during deploy       |
| release equality check    | unchanged Helm release skipped |

Measured release `1.2.14`:

```text
CI   1m26s
CD   1m16s
──────────
     2m42s
```

Jenkins polls GitHub every minute, so wall-clock delivery may include one polling interval before CI and one before CD.

---

## 8. Evidence and limits

Release trace:

```text
1.2.14
   ↓
sha256:2758e8...dcd1824
   ↓
state commit 75769b4
   ↓
deploy/main #24
   ↓
dev-2026.09.21.5
```

Implementation:

* [service pipeline](delivery/pipeline/vars/servicePipeline.groovy)
* [platform pipeline](delivery/Jenkinsfile.platform)
* [deployment pipeline](delivery/pipeline/vars/deployPipeline.groovy)
* [build](delivery/pipeline/resources/lab/delivery/build-image.sh)
* [scan](delivery/pipeline/resources/lab/delivery/scan-image.sh)
* [publish](delivery/pipeline/resources/lab/delivery/publish-image.sh)
* [verify](delivery/pipeline/resources/lab/delivery/validate-release.sh)

Known limits:

```text
CRITICAL-only vulnerability gate
SBOM generated but not attested
Cosign transparency-log upload disabled
no-traffic canary warns and passes
stage/prod/canary paths implemented but not exercised in this lab
```
