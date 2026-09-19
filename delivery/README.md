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

1. A chart that inherits the base chart ([`charts/service`](../charts/service/README.md)), with `image.repository` in its values.
2. A Jenkinsfile:

   ```groovy
   @Library('lab-delivery') _
   servicePipeline(chart: 'app/chart', context: 'app', path: 'app/')
   ```

3. One entry in the `services` list in [`platform/jenkins/jcasc/jenkins.yaml`](../platform/jenkins/jcasc/jenkins.yaml). It creates a GitHub multibranch job.
4. One `<chart name>: null` entry under `services` in every [`state/<environment>.yaml`](../state/).
5. If Jenkins releases it, one entry under `releases` in [`environments.yaml`](../environments.yaml). Services not listed there (the admission webhook) are built and recorded, and the operator installs them.

The chart name is the release name and the state entry, and the chart's `image.repository` is the only repository its releases accept. Per-environment values go in `values-<environment>.yaml` next to `values.yaml`.

## Pipeline

```text
branch or pull request ─► service job ─► changeset under `path`? ── no ──► done
                               │ yes
                               ▼
        Validate   hadolint · helm dry-run in dev through the API server and admission
        Build      BuildKit, once; unit tests run inside the Dockerfile
        Scan       Trivy + CycloneDX SBOM of that image
        ── main only ──
        Publish    push the scanned image unchanged; digest must match
                   publish the chart as <Chart.yaml version>-sha-<commit>
                   commit {chart, image} to state/dev.yaml on main
                               │
                               ▼
state/ changed ─► deploy job
        Verify     every image was in the previous environment first
                   dry-run of the recorded chart with the environment's values
        ── main only ──
        Deploy     dev, stage, prod in order; releases already on their chart and image are skipped
                   mint 15-minute deployer token
                   helm upgrade --wait --rollback-on-failure
```

Everything here is native Jenkins and Git:
- **Jobs:** GitHub Branch Source builds every branch and pull request and posts the GitHub commit status.
- **Only relevant changes run:** declarative `when { changeset }`. A new multibranch job has no changelog, so its first build runs the relevant bootstrap checks instead of silently skipping them.
- **Only `main` publishes and deploys:** `when { branch 'main' }`.
- **Release identity:** a chart version and an image digest, published together by one CI run. The state records both, so an image always ships with the chart it was tested with.

## Identities

| Who | Can |
|---|---|
| CI (`jenkins-ci`) | server-side dry-run only; admission denies its real writes |
| CD (`jenkins-agent`) | mint a 15-minute token for the namespace's `deployer`, nothing else |
| `deployer` | manage the chart's objects in its namespace; no Secrets |

No cluster credential is stored in Jenkins.

## Environments

[`environments.yaml`](../environments.yaml) lists the environments in promotion order (`dev` → `stage` → `prod`) with their namespaces, plus the chart registry and the releases Jenkins owns. What runs in an environment is its [`state/<name>.yaml`](../state/): one `{chart, image}` release per service, `null` until first released. The Git history of those files is the deploy history.

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
