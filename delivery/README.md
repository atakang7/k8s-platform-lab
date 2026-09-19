# Delivery

`delivery/` is the platform's CI/CD: it builds, tests, scans, publishes and deploys services. It knows nothing about any particular service; a service plugs in with a Helm chart and a two-line Jenkinsfile.

| Path | Purpose |
|---|---|
| `pipeline/` | Jenkins shared library `lab-delivery`, loaded by JCasC |
| `pipeline/vars/servicePipeline.groovy` | CI/CD for one service |
| `pipeline/vars/deployPipeline.groovy` | the `deploy` job: one chart × one digest |
| `pipeline/resources/lab/delivery/` | the step scripts the pipelines run |
| `Jenkinsfile.deploy` | `deploy` job entry point |
| `Jenkinsfile.platform` | `platform` job: shellcheck everywhere; `ct lint` on chart pull requests; publishes charts from main; lints policies |
| `jenkins/` | CI agent image |

Base charts live in [`charts/`](../charts/), and namespaces and deploy identities in [`platform/environment`](../platform/environment/). Neither is delivery.

## Onboarding a service

1. A chart that inherits the base chart ([`charts/service`](../charts/service/README.md)), with `image.repository` in its values.
2. A Jenkinsfile:

   ```groovy
   @Library('lab-delivery') _
   servicePipeline(chart: 'app/chart', context: 'app', path: 'app/')
   ```

3. One entry in the `services` list in [`platform/jenkins/jcasc/jenkins.yaml`](../platform/jenkins/jcasc/jenkins.yaml). It creates a GitHub multibranch job.

The chart name is the release name, and the chart's `image.repository` is the only repository its releases accept.

## Pipeline

```text
branch or pull request ─► multibranch job ─► changeset under `path`? ── no ──► done
                                 │ yes
                                 ▼
          Validate   hadolint · helm dry-run through the API server and admission
          Build      BuildKit, once; unit tests run inside the Dockerfile
          Scan       Trivy + CycloneDX SBOM of that image
          ── main only ──
          Publish    push the scanned image unchanged; digest must match
          Deploy     approval if environment.yaml says so ─► deploy job
                                 │
                                 ▼
          deploy job: checkout exact commit · image repo must match the chart
                      helm upgrade --wait --rollback-on-failure
```

Everything here is native Jenkins:
- **Jobs:** GitHub Branch Source builds every branch and pull request and posts the GitHub commit status.
- **Only relevant changes run:** declarative `when { changeset }`. The first build of a branch has no changelog, so it always runs.
- **Only `main` publishes and deploys:** `when { branch 'main' }`.
- **Release identity:** the full commit SHA plus the image digest. Nothing mutable is deployed.

## Identities

| Who | Can |
|---|---|
| CI (`jenkins-ci`) | server-side dry-run only; admission denies its real writes |
| CD (`jenkins-agent`) | mint a 15-minute token for the namespace's `deployer`, nothing else |
| `deployer` | manage the chart's objects in its namespace; no Secrets |

No cluster credential is stored in Jenkins.

## Environments

A repository is one environment, described by [`environment.yaml`](../environment.yaml): name, namespace, approval gate and chart registry. This repository is `dev`. A `stage` or `prod` copy changes `environment.yaml` and its app values. Nothing in `delivery/` changes.

## Operating rules

- Roll back by re-running the `deploy` job with a previous commit + digest. A failed deploy already rolls itself back.
- Change the CI image only through `jenkins/build-ci-agent.sh` ([jenkins/README.md](jenkins/README.md)).
- Platform and infra are applied by the operator (`make`), never by Jenkins; the `platform` job only checks them.
