# Delivery

`delivery/` is the platform's CI/CD: it builds, tests, scans, publishes and deploys services. It knows nothing about any particular service; a service plugs in with a Helm chart and a two-line Jenkinsfile.

| Path | Purpose |
|---|---|
| `pipeline/` | Jenkins shared library `lab-delivery`, loaded by JCasC |
| `pipeline/vars/servicePipeline.groovy` | CI for one service; records main's releases in `state/dev.yaml` |
| `pipeline/vars/deployPipeline.groovy` | the `deploy` job: releases every environment to its `state/<name>.yaml` |
| `pipeline/resources/lab/delivery/` | the step scripts the pipelines run |
| `Jenkinsfile.deploy` | `deploy` job entry point |
| `Jenkinsfile.platform` | `platform` job: shellcheck everywhere; `ct lint` on chart pull requests; publishes charts from main |
| `jenkins/` | CI agent image |

## How it fits together

Jenkins runs four multibranch jobs over this one repository, all on the `lab-delivery` library. The jobs are defined in [`platform/jenkins/jcasc/jenkins.yaml`](../platform/jenkins/jcasc/jenkins.yaml) (`services` list, `platform`, `deploy`). Jobs never call each other: service CI commits a release to `state/dev.yaml`, and that commit is what starts the deploy job.

```text
                     GitHub: atakang7/lab
                   (Jenkins re-indexes every minute)
                                   │
     ┌─────────────────┬───────────┴─────┬─────────────────────┐
     ▼                 ▼                 ▼                     ▼
 service job       service job       platform job          deploy job
 sample-java-app   resource-         Jenkinsfile.platform  Jenkinsfile.deploy
                   requests-webhook
     └───────┬─────────┘                 │                     │
             ▼                           ▼                     ▼
     servicePipeline()           shellcheck everything  deployPipeline()
     Validate · Build · Scan     ct lint (PR, charts/)  Verify: promoted from the
             │ main only         publish charts (main)  previous env · chart dry-run
             ▼                                                 │ main only
     Publish image + chart                                     ▼
     commit release ─► state/dev.yaml ───────────────► Deploy dev → stage → prod
                                                               ▲
     promotion PR ───► state/stage.yaml, state/prod.yaml ──────┘
     (code-owner review)                                       │
                                                               ▼
                                               apps-dev · apps-stage · apps-prod
```

The webhook is built and recorded like any service, but it is not in `releases`, so the operator installs it (`make policies-up`), not Jenkins.

Base charts live in [`charts/`](../charts/), and namespaces and deploy identities in [`platform/environment`](../platform/environment/). Neither is delivery.

## Onboarding a service

1. A chart that inherits the base chart ([`charts/service`](../charts/service/README.md)), with `image.repository` in its values. Its `version` is the app version.
2. A Jenkinsfile:

   ```groovy
   @Library('lab-delivery') _
   servicePipeline(chart: 'app/chart', context: 'app', path: 'app/')
   ```

3. One entry in the `services` list in [`platform/jenkins/jcasc/jenkins.yaml`](../platform/jenkins/jcasc/jenkins.yaml). It creates a GitHub multibranch job.
4. One `<chart name>: null` entry under `services` in every [`state/<environment>.yaml`](../state/).
5. If Jenkins releases it, one entry under `releases` in [`environments.yaml`](../environments.yaml). Services not listed there (the admission webhook) are built and recorded, and the operator installs them.

The chart name is the release name and the state entry, and the chart's `image.repository` is the only repository its releases accept. Per-environment values go in `values-<environment>.yaml` next to `values.yaml`.

## Release flow

One immutable image moves from pull request to prod. Machines check every step; people decide only at the two promotion pull requests and the merge.

```text
 1. CODE        developer opens a PR, bumps the app version
                        │
 2. CHECK       build · test · scan · dry-run          ✗ fail → PR blocked
                        │
                   [ review + merge ]
                        │
 3. PUBLISH     image + chart pushed as v1.4.2, signed
                        │
 4. DEV         auto-deploy → smoke test               ✗ fail → auto-rollback
                        │   tag dev-2026.09.19.1
                   [ promotion PR ]
                        │
 5. STAGE       deploy → end-to-end tests              ✗ fail → auto-rollback
                        │   tag stage-2026.09.19.1
                   [ promotion PR + owner approval ]
                        │
 6. PROD        canary 10% → watch metrics → 100%      ✗ bad metrics → auto-rollback
                        │   tag prod-2026.09.19.1
                        │
 7. ROLLBACK    PR restoring an earlier prod-… tag
```

| Step | What happens | Where |
|---|---|---|
| 1 Code | The app version is `version` in the service chart's `Chart.yaml`. A pull request that changes a service must raise it. | `servicePipeline` Validate |
| 2 Check | hadolint; BuildKit builds once with unit tests inside the Dockerfile; Trivy fails on CRITICAL and writes a CycloneDX SBOM; server-side dry-run of the chart in dev through the API server and admission. | `servicePipeline`, `build-image.sh`, `scan-image.sh`, `validate-release.sh` |
| 3 Publish | main only. The scanned bytes are pushed as `<image>:<version>` (never rebuilt), the chart as `<chart>:<version>`, and the image is signed with cosign. A version already published from another commit is refused. CI commits `{version, image}` to `state/dev.yaml`. | `publish-image.sh`, `publish-chart.sh`, `delivery.recordRelease` |
| 4 Dev | The state commit starts the deploy job. It verifies the promotion rule, the signature and a dry-run, releases with `helm upgrade --wait`, then runs the chart's Helm tests. A failed test rolls the release back. A healthy environment is tagged, and a pull request promoting the release to stage opens. | `deployPipeline`, `deploy.sh` |
| 5 Stage | Same as dev. A service's own Helm tests are its end-to-end tests; the base chart's smoke test runs for every service. Success opens the promotion pull request to prod. | same |
| 6 Prod | Environments with `canary` in `environments.yaml` first release `<service>-canary` with one replica behind 10% of the ingress traffic and watch its 5xx rate in Prometheus. Bad metrics remove the canary and leave the stable release untouched; good metrics release the stable version and remove the canary. | `deploy.sh` |
| 7 Rollback | `git checkout prod-2026.09.19.1 -- state/prod.yaml` in a pull request. The promotion rule accepts it because every image in it was in stage before. | Git |

Every step leaves a record in Git: a state commit per deploy and a `<environment>-<date>.<n>` tag per healthy environment.

Jobs run only for relevant changes (`when { changeset }`); a new multibranch job has no changelog, so its first build runs every check instead of silently skipping them.

## Identities

| Who | Can |
|---|---|
| CI (`jenkins-ci`) | server-side dry-run only; admission denies its real writes |
| CD (`jenkins-deploy-<environment>`) | manage the chart's objects in that environment's namespace only; no Secrets |

No cluster credential is stored in Jenkins.

## Environments

[`environments.yaml`](../environments.yaml) lists the environments in promotion order (`dev` → `stage` → `prod`) with their namespaces, plus the chart registry and the releases Jenkins owns. What runs in an environment is its [`state/<name>.yaml`](../state/): one `{version, image}` release per service (app version and image digest), `null` until first released. The Git history of those files is the deploy history.

| To | Do |
|---|---|
| deploy to dev | merge a service change; CI commits the new release to `state/dev.yaml` |
| promote | pull request copying a release into `state/stage.yaml` or `state/prod.yaml`; the deploy job verifies it, a code owner ([`.github/CODEOWNERS`](../.github/CODEOWNERS)) approves it |
| roll back | revert the state commit |

A failed deploy rolls itself back and fails the build. The state file still names the new release until someone reverts or fixes it.

Jenkins pushes state commits to `main` with `github-creds`. That token needs contents write access, and branch protection must allow the push. The promotion gate holds only while `main`'s branch protection requires code-owner review; without it, anyone who can merge can deploy to prod.

## Operating rules

- Change what runs only through `state/`. A manual `helm upgrade` is taken back by the next deploy of that release.
- Change the CI image only through `jenkins/build-ci-agent.sh` ([jenkins/README.md](jenkins/README.md)).
- Platform and infra are applied by the operator (`make`), never by Jenkins; the `platform` job only checks them.
