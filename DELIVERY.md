# Delivery

How code becomes a running workload here, why it is built this way, and what it deliberately does not do.
Operator commands: [delivery/README.md](delivery/README.md). Base chart: [charts/service/README.md](charts/service/README.md).

## Contents
1. [The contract](#1-the-contract)
2. [System map](#2-system-map)
3. [Service CI](#3-service-ci)
4. [Artifact identity](#4-artifact-identity)
5. [State, promotion, rollback](#5-state-promotion-rollback)
6. [Deploy](#6-deploy)
7. [Trust boundaries](#7-trust-boundaries)
8. [Performance](#8-performance)
9. [Failure and recovery](#9-failure-and-recovery)
10. [Evidence](#10-evidence)
11. [Known limits](#11-known-limits)

---

## 1. The contract

> **Build once. Scan the bytes you ship. Deploy by digest. Git says what runs.**

```text
  source ──► build ──► scan ──► publish ──► record ──► verify ──► deploy ──► test ──► tag ──► promote
             └────── one OCI layout ──────┘   │                                               │
                                              └──── state/<env>.yaml (Git) ◄──────────────────┘
```

Invariants the code enforces, not conventions:

| Invariant | Enforced by |
|---|---|
| Scanned image = published image | `publish-image.sh` pushes the scanned OCI layout and fails if registry digest ≠ scanned digest |
| Published digest = recorded digest = deployed digest | CI writes `pushed.digest` into state; deploy passes it as `image.digest`; chart rejects anything but `sha256:<64 hex>` |
| CD never builds | deploy job has no BuildKit container and no build step |
| A version is published once | tag reuse allowed only if its OCI `revision` label equals the current service source revision |
| Promotion moves the same digest | `requirePromoted`: digest must appear in the previous environment's state history |
| Only delivery-signed images deploy | `cosign verify` against the key shipped in the `main` library |

---

## 2. System map

One repository, four multibranch jobs, one shared library. Jobs never call each other — Git commits are the only hand-off.

```text
                          GitHub  atakang7/lab
                        (Jenkins re-indexes every 1m; no webhooks)
                                        │
      ┌──────────────────┬──────────────┴───────┬──────────────────────┐
      ▼                  ▼                      ▼                      ▼
 sample-java-app   resource-requests-webhook  platform               deploy
 app/Jenkinsfile   policies/.../Jenkinsfile   Jenkinsfile.platform   Jenkinsfile.deploy
      └────────┬─────────┘                      │                      │
               ▼                                ▼                      ▼
        servicePipeline()               shellcheck · ct lint     deployPipeline()
        (lab-delivery lib,            publish base charts      verify → deploy → test
         pinned to main)                                          → tag → promotion PR
               │                                │                      │
               ▼                                ▼                      ▼
     ┌─────────────────────┐          ┌──────────────────┐   ┌──────────────────────┐
     │ Docker Hub           │          │ Docker Hub (OCI) │   │ apps-dev (this       │
     │ image:<ver>@sha256   │          │ charts/service   │   │ cluster)             │
     │ chart:<ver> · sig    │          └──────────────────┘   │ apps-stage/prod      │
     └─────────────────────┘                                  │ (own clusters)       │
               │                                              └──────────────────────┘
               ▼                                                       ▲
        state/dev.yaml  ───── commit on main = deploy trigger ─────────┘
```

| Job | Owns | Does not |
|---|---|---|
| `sample-java-app` | build, test, scan, publish, record dev release | deploy |
| `resource-requests-webhook` | same as above | get deployed by Jenkins — not in `releases`; operator runs `make policies-up` |
| `platform` | shellcheck all scripts, `ct lint` chart PRs, publish base charts | apply platform/infra (operator `make` only) |
| `deploy` | reconcile `clusterEnvironment` to its state file | build, scan, or touch other clusters |

Adding a service = chart + 2-line Jenkinsfile + one JCasC entry + `null` in each state file. No pipeline code.

```groovy
@Library('lab-delivery') _
servicePipeline(chart: 'app/chart', context: 'app', path: 'app/')
```

---

## 3. Service CI

[servicePipeline.groovy](delivery/pipeline/vars/servicePipeline.groovy)

```text
            PR and main                                          main only
 ┌──────────┬──────────────────┬───────────────┬───────────────┐ ┌──────────────────────────────────┐
 │ Checkout │ Validate         │ Build + Test  │ Scan          │ │ Publish                          │
 │          │ hadolint         │ BuildKit      │ Trivy         │ │ skopeo copy (same layout)        │
 │ service  │ version bump(PR) │ mvnw package  │ CRITICAL gate │ │ digest == scanned digest         │
 │ revision │ helm render      │  ├ JUnit 5    │ CycloneDX SBOM│ │ cosign sign @digest              │
 │ state    │ server dry-run   │  └ Spring ctx │ (1 scan run)  │ │ helm push chart:<ver>            │
 │ lookup   │  (dev namespace) │ → OCI layout  │               │ │ commit {ver,digest} → dev state  │
 └──────────┴──────────────────┴───────────────┴───────────────┘ └──────────────────────────────────┘
      ✗ any failure stops here; nothing is published from a red build
```

**When the Service stages run** (anything else skips them on this job):

```text
 changes under path/ ─────────────┐
 previous build not SUCCESS ──────┼──► run
 main AND version not in dev state┘     (catches a publish/record that failed last time)
```

What each step actually proves:

| Step | Proves | Detail |
|---|---|---|
| Checkout | identity | `SERVICE_REVISION` = last commit touching the service path, not HEAD. Unrelated commits don't change it. |
| Validate | chart is deployable | Released services: render + `kubectl apply --dry-run=server` in `apps-dev` — full schema + admission chain with a placeholder digest. Operator-owned services: `helm lint`. |
| Version bump | no silent overwrite | PR touching the service must raise `Chart.yaml` `version` (`sort -V`). Promotion PRs touch only `state/`, so they owe nothing. |
| Build + Test | code works | Tests run **inside** the Dockerfile's `mvnw package`: `@WebMvcTest(HelloController)` (success, missing param → 400, release marker) and `@SpringBootTest` context load. Failing test = failed image build. |
| Scan | no known CRITICAL CVE | One `trivy image --input app-image` produces the gate result and the package list; `trivy convert` makes the table and SBOM from that same report. SBOM archived on every build. |
| Publish | registry has exactly what was scanned | Skopeo pushes the local layout — no rebuild, no re-pull. |
| Record | release exists | `recordRelease` commits to `main`; `retry(3)` refetches and reapplies on push race. |

---

## 4. Artifact identity

```text
 service path commit ──► Chart.yaml version ──► image tag + chart version + state version
   SERVICE_REVISION         1.2.14                  (one number, three places)
          │
          └──► OCI label org.opencontainers.image.revision
                                      │
 BuildKit OCI layout ──► sha256:2758e8…dcd1824 ──► registry ──► state/dev.yaml ──► Pod image
                             (scanned)          (== scanned)    (recorded)       repo@sha256:…
```

- **Version** is the human name. **Digest** is the identity. Runtime never resolves a tag.
- The base chart rejects a missing/malformed digest at render time (`service.image` in [_manifests.tpl](charts/service/templates/_manifests.tpl)).
- Version reuse:

```text
 tag exists? ── no ──► push scanned layout, verify digest, sign
     │
    yes ── same source revision? ── yes ──► reuse published digest, re-sign (idempotent rebuild)
                  │
                  no ──► FAIL "raise the version"
```

- `charts/service` (base chart) is versioned on its own; app charts pin it (`service: 1.2.0`). `ct lint --check-version-increment` enforces bumps.

---

## 5. State, promotion, rollback

[environments.yaml](environments.yaml) is the topology. [state/](state/) is the desired state. Git history is the deploy log.

```yaml
# state/dev.yaml
environment: dev
services:
  sample-java-app:            {version: 1.2.14, image: sha256:2758e8…dcd1824}
  resource-requests-webhook:  {version: 0.2.2,  image: sha256:cc0ca4…4258}
```

```text
            CI commit               promotion PR              promotion PR
            (no review)             (CODEOWNERS)              (CODEOWNERS)
 main ────► state/dev.yaml ──────►  state/stage.yaml ──────►  state/prod.yaml
                 │                        │                        │
            deploy dev               deploy stage             canary → deploy prod
            helm test                helm test (e2e)          helm test
            tag dev-YYYY.MM.DD.n     tag stage-…              tag prod-…
            open PR → stage          open PR → prod
```

Rules:

| Rule | Mechanism |
|---|---|
| Digest must have been in the previous env | `git log -S <digest> -- state/<previous>.yaml` must be non-empty. Checked for **every** env on **every** state PR, not just this cluster's. |
| Human gate for stage/prod | [.github/CODEOWNERS](.github/CODEOWNERS) on `state/stage.yaml`, `state/prod.yaml`, `environments.yaml`. Real only while branch protection requires code-owner review. |
| One open promotion per service per env | branch `promote/<env>/<service>`, force-pushed; a newer healthy release replaces the proposal. 422 "already exists" = refresh, anything else fails loud. |
| Tags only on change | `tagRelease` skips if state file unchanged since the last `<env>-*` tag. Number = max+1, not count (deleted tags leave gaps safely). |

**Rollback** is a state change like any other:

```text
git checkout prod-2026.09.19.1 -- state/prod.yaml   →  PR  →  merge  →  deploy job
```

The promotion rule accepts it because every digest in an old prod state was in stage before.

**One cluster = one environment.** `clusterEnvironment: dev` here. The deploy job verifies all environments' state but deploys only `clusterEnvironment`. Stage/prod state lives in Git; their clusters would run the same job with a different `clusterEnvironment`.

---

## 6. Deploy

[deployPipeline.groovy](delivery/pipeline/vars/deployPipeline.groovy) · [deploy.sh](delivery/pipeline/resources/lab/delivery/deploy.sh)

```text
 trigger: change in state/** or environments.yaml, OR previous build not SUCCESS
                                   │
 ┌─ Verify ─────────── lab-ci-light (jenkins-ci, dry-run only) ── PRs and main ─┐
 │ for every recorded release in every env:                                        │
 │   requirePromoted                                                              │
 │   if this cluster's env AND Jenkins-released:                                  │
 │     pull chart:<ver> · render · cosign verify every image@digest · dry-run     │
 └────────────────────────────────────────────────────────────────────────────────┘
                                   │ main only
 ┌─ Deploy ─────────── lab-cd-runner-dev (jenkins-deploy-dev) ──────────────────┐
 │ for each release in clusterEnvironment:                                         │
 │   already running this chart version + digest? ──► skip                        │
 │   canary env and stable exists? ──► canary (below)                             │
 │   helm upgrade --install --wait --rollback-on-failure --timeout 5m             │
 │   helm test ── fail ──► rollback (or uninstall first install) ──► FAIL         │
 │ all passed ──► tag env ──► open promotion PRs                                  │
 └────────────────────────────────────────────────────────────────────────────────┘
```

A state PR gets Verify as a commit status before merge — reviewers see signature and dry-run results on the promotion itself.

**Two layers of automatic rollback:**

| Failure | Action |
|---|---|
| Pods never Ready within 5m | Helm `--rollback-on-failure` restores last good revision |
| Ready but `helm test` fails (base smoke test `GET /api/foos?val=smoke` + service tests) | `helm rollback` to previous revision; first install → `helm uninstall` |

**Prod canary** (`canary: {weight: 10, minutes: 5, maxErrorRate: 0.01}`):

```text
 install <svc>-canary (1 replica, no PDB, ingress canary-weight 10%) ──► helm test canary
        │
        ▼  every 60s × 5
 PromQL: 5xx / all  from nginx_ingress_controller_requests{canary=~"<ns>-<svc>-canary-.+"}
        │
        ├─ rate > 1% ──────► FAIL; canary removed (EXIT trap); stable untouched
        ├─ no traffic ─────► keep waiting; if never any → WARN and pass
        └─ healthy ────────► upgrade stable ──► helm test ──► canary removed
```

The canary is removed on every exit path by a `trap`, so a crashed deploy never leaves 10% of traffic on an unjudged version. First install skips the canary — there is no stable to compare against.

---

## 7. Trust boundaries

```text
 ┌──────────────── Jenkins (namespace jenkins) ────────────────┐
 │                                                             │
 │  lab-ci-runner / ci-light         lab-cd-runner-<env>   │
 │  SA jenkins-ci                      SA jenkins-deploy-<env> │
 │  holds: registry, cosign key,       holds: registry (pull)  │
 │         GitHub token                       GitHub token     │
 └──────────┬──────────────────────────────────┬───────────────┘
            │ dry-run only                     │ real writes
            ▼                                  ▼
   ValidatingAdmissionPolicy          Role in apps-<env> only:
   jenkins-ci-dry-run-only            deployments, services, configmaps,
   (Deny unless request.dryRun)       ingresses, pdbs, servicemonitors, pods
                                      NO secrets → HELM_DRIVER=configmap
```

| Boundary | Guarantee |
|---|---|
| CI → cluster | CI has the deployer's RBAC (needed for server-side dry-run), but an admission policy denies every non-dry-run write from `jenkins-ci`. It can validate, never change. |
| CD → cluster | One ServiceAccount per environment, bound only in that namespace. No Secrets access — Helm history lives in ConfigMaps. No kubeconfig stored in Jenkins. |
| Pipeline code | `lab-delivery` library loads from `main`, `allowVersionOverride: false`. A branch can't swap the pipeline. |
| Signing key | `cosign.pub` ships inside that library. A branch can't change the key its images are verified against. |
| CI agent image | Every binary pinned by version **and** SHA-256; image referenced by digest in JCasC; built only via `build-ci-agent.sh` (refuses uncommitted changes). |
| All third-party images | pinned by digest (BuildKit, chart-testing, Temurin, fluent-bit, Ubuntu). |
| Build | rootless BuildKit, uid 1000, no privileged container. |
| Credentials | Vault → VSO → Kubernetes Secret → JCasC. None in the repo. |

---

## 8. Performance

The lab cluster is memory-constrained (`containerCap: 3`). The design spends that budget on keeping exactly the right Pods warm.

```text
                    node-3 (pinned)                               any worker
 ┌───────────────────────────────────────────────┐       ┌─────────────────────────┐
 │ lab-ci-runner      (heavy: builds)          │       │ lab-ci-light          │
 │  ├ ci-tools   ◄── hostPath /var/lib/…/trivy   │       │  ci-tools · chart-testing│
 │  ├ buildkit   ◄── hostPath /var/lib/…/buildkit│       │  (lint, deploy Verify)  │
 │  └ chart-testing                              │       └─────────────────────────┘
 │ lab-cd-runner-dev  (deploy identity)        │
 │  └ ci-tools                                   │
 └───────────────────────────────────────────────┘
   each: instanceCap 1 · idleMinutes 10 · warm-* cron job every minute
```

| Optimization | What it removes |
|---|---|
| Warm runners (`warm-ci-runner`, `warm-ci-light`, `warm-cd-runner-dev`, cron `* * * * *` + `idleMinutes: 10`) | Pod scheduling + image pull + JNLP connect. Agent acquisition **~51s → ~5s**. |
| CD warm Pod uses the real `jenkins-deploy-dev` SA and fixed label | Deploy reuses the authorized Pod instead of creating one per run. |
| Heavy/light split | Deploy Verify and platform lint never queue behind an image build. |
| Persistent BuildKit state on node-3 hostPath | Base layers and `dependency:go-offline` Maven layer survive Pod restarts. Dockerfile copies `pom.xml` before `src/`, so code-only changes skip dependency download. |
| Persistent Trivy DB on node-3 hostPath | No vulnerability DB download per build. |
| Build to local OCI layout | Scan reads local files; publish copies those files. No push-then-pull, no second build. |
| One Trivy run | Gate, log table, and SBOM from one report. |
| Path `changeset` gating | A docs or platform commit doesn't build the app. |
| State-driven republish (`UNRECORDED`) | Recovery doesn't require a code change or a manual rebuild. |
| Idempotent publish | Existing image (same source) → reuse digest; existing chart → skip. |
| `release_is_current` | Deploy skips Helm entirely when chart version + digest already run. |
| CD does no build/scan/package | CD cost = pull chart + verify + helm upgrade + tests. |
| `--history-max 5`, `logRotator` | Bounded ConfigMap and build history. |

Measured, release **1.2.14**, warm runners:

```text
 CI  #27  ████████████████████████████████████████████                 1m26s
 CD  #24  ██████████████████████████████████████                       1m16s
          ────────────────────────────────────────────────────────────────────
 total execution                                                        2m42s
```

Add up to one poll interval (≤1m) before CI and one before CD — Jenkins isn't reachable from GitHub, so there are no webhooks.

---

## 9. Failure and recovery

| Failure | Result | Recovery |
|---|---|---|
| Hadolint / dry-run / test / CRITICAL CVE | PR red, nothing published | fix code |
| Version not bumped on service PR | PR red | bump `Chart.yaml` |
| Version already published from other source | publish fails | bump version |
| Registry digest ≠ scanned digest | publish fails before signing | investigate registry; rerun |
| Publish or record fails on `main` | build red | next `main` build republishes (`UNRECORDED` + previous-not-success trigger) |
| State push race with another service | automatic | `retry(3)` refetch + reapply |
| Digest not in previous env's history | Verify fails, PR red | promote through the previous env first |
| Bad signature | Verify fails | only CI-signed images deploy |
| Readiness timeout | Helm auto-rollback, build red | fix and release new version, or revert state |
| Helm test fails | rollback / uninstall, build red | same |
| Canary 5xx > 1% | canary removed, stable untouched, build red | same |
| Deploy job red for any reason | next build retries even without state change | automatic |

Note: after an automatic rollback the cluster runs the old version while state still names the new one. That drift is intentional and visible (red build, no tag); revert or fix the state commit.

---

## 10. Evidence

One release traced end to end:

```text
 app/chart version 1.2.14
   └─► sample-java-app CI #27  (1m26s)
         └─► docker.io/atakangul/sample-java-app@sha256:2758e8fba94b…dcd1824  (signed)
               └─► commit 75769b4 "Deploy sample-java-app 1.2.14 to dev"
                     └─► deploy/main #24  (1m16s)
                           └─► tag dev-2026.09.21.5  → 75769b4
```

Promotion exercised: `resource-requests-webhook 0.2.2` promoted dev → stage by PR (commit 728b294), same digest `sha256:cc0ca4…4258` in both state files.

Code: [servicePipeline](delivery/pipeline/vars/servicePipeline.groovy) · [deployPipeline](delivery/pipeline/vars/deployPipeline.groovy) · [delivery.groovy](delivery/pipeline/vars/delivery.groovy) · [Jenkinsfile.platform](delivery/Jenkinsfile.platform) · [build](delivery/pipeline/resources/lab/delivery/build-image.sh) · [scan](delivery/pipeline/resources/lab/delivery/scan-image.sh) · [publish](delivery/pipeline/resources/lab/delivery/publish-image.sh) · [validate](delivery/pipeline/resources/lab/delivery/validate-release.sh) · [deploy](delivery/pipeline/resources/lab/delivery/deploy.sh) · [JCasC](platform/jenkins/jcasc/jenkins.yaml)

---

## 11. Known limits

Chosen trade-offs, not oversights:

| Limit | Why it's acceptable here / what fixes it |
|---|---|
| Gate is CRITICAL-only | HIGH findings are visible in the log and SBOM; tighten `--severity` when there's a triage process. |
| SBOM archived, not signed/attested | add `cosign attest --type cyclonedx`. |
| No Rekor transparency log | uploading would publish image names; key-based verification instead. Key rotation is manual. |
| Signature verified in the pipeline, not at admission | a manual `kubectl` bypasses it; add a policy-controller admission check. |
| Canary with zero traffic passes with WARN | lab has no real traffic; add synthetic load or fail-on-no-traffic in real prod. |
| Polling, not webhooks | Jenkins isn't publicly reachable; costs ≤1m per hop. |
| Heavy runner pinned to node-3 | caches are hostPath; node-3 loss = cold caches + CI down until re-pinned. A shared cache (registry cache export) would remove the pin. |
| One heavy runner (`instanceCap: 1`) | memory budget; concurrent service builds queue. |
| State and cluster can drift after auto-rollback | deliberate: Git records intent, the red build records reality. |
| Stage/prod and canary are implemented but not exercised for the app | only dev has a cluster. Webhook stage promotion proves the PR path, not a stage deploy. |
| CODEOWNERS gate depends on GitHub branch protection | outside the repo; verify the setting. |
