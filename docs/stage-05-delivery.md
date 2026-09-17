# Stage 5 — CI/CD and artifact flow

This stage turns a Git commit into one immutable image artifact and then deploys that exact artifact from that exact commit.

## End-to-end release flow

```text
                                   GitHub main
                                       │
                                       │ SCM poll · 1 min
                                       ▼
                   ╔══════════════════════════════════════╗
                  ╱  Jenkins controller · node-3         ╱│
                 ╚══════════════════════════════════════╝ │
                 │  0 executors · orchestration only     │
                 │                                        │
                 │ schedules                              │
                 ▼                                        │
        ┌──────────────────────────┐                       │
        │ lab-ci-runner          │                       │
        │ node-3                   │                       │
        └─────────────┬────────────┘                       │
                      │                                    │
          ┌───────────┼────────────────────────────┐       │
          │           │                            │       │
          ▼           ▼                            ▼       │
       tests       config checks               BuildKit   │
       Maven       Dockerfile lint             local image│
                   server dry-run                 │       │
                   Ansible syntax                 ▼       │
                                           Trivy + SBOM   │
                                                  │       │
                                                  ▼       │
                                           BuildKit push  │
                                                  │       │
                                                  ▼       │
                                      repository@sha256…  │
                                                  │       │
                                                  │ async │
                                                  ▼       │
                                      ┌──────────────────┐│
                                      │ lab-cd-runner  ││
                                      │ node-3           ││
                                      └────────┬─────────┘│
                                               │          │
                                               ▼          │
                                      exact commit checkout
                                               │
                                               ▼
                                      Ansible deployment
                                               │
                                               ▼
                                      rollout verification
                                               │
                                               ▼
                                      live digest assertion
```

The controller never performs build work. CI and CD use separate exclusive Kubernetes agent templates.

## CI strategy

`delivery/Jenkinsfile.build` performs four validation classes before publication:

| Check | Why |
|---|---|
| Maven tests | application behavior |
| Dockerfile lint | container definition quality |
| `kubectl apply --dry-run=server` | API schema and live admission validation without creating workloads |
| Ansible syntax check | deployment automation parses before release |

Independent checks run in parallel. Image construction starts only after they pass.

## Build strategy

BuildKit is the image builder. The CI runner contains a dedicated BuildKit container and a tools container. Node-local cache state is retained on `node-3`:

```text
/var/lib/lab-ci/m2       Maven dependencies
/var/lib/lab-ci/trivy    vulnerability database/cache
/var/lib/lab-ci/buildkit BuildKit state
```

The runner stays warm for a bounded idle period. Warm state reduces scheduling, dependency, and image-build overhead; it does not change the artifact contract.

The image is built locally first so security inspection can happen before publication.

## Security reporting

```text
local image archive
       │
       ▼
┌──────────────────────┐
│ Trivy                │
│ HIGH + CRITICAL      │
└──────────┬───────────┘
           │
           ├──────────► scan output
           │
           └──────────► CycloneDX SBOM · sbom.json
```

The SBOM is archived by Jenkins. Vulnerability findings are report-only by default because `TRIVY_EXIT_CODE` defaults to `0`. Set a failing exit code when the organization wants vulnerability severity to block publication.

Do not describe the current configuration as a strict vulnerability gate.

## Artifact identity

Publication returns an immutable registry digest:

```text
docker.io/atakangul/sample-java-app@sha256:<64 hex chars>
```

CI carries two release identifiers forward:

```text
Git commit SHA ─────────────┐
                           ├── one release
Image digest ───────────────┘
```

Mutable tags are not accepted as CD deployment input.

## CI to CD handoff

CI enqueues `lab-deploy` asynchronously after the image is published. It does not wait for deployment completion while occupying the CI executor.

The handoff contains:

| Parameter | Contract |
|---|---|
| `IMAGE_REF` | immutable `repository@sha256:...` |
| `COMMIT_SHA` | full 40-character Git SHA |

CD validates both before doing any cluster change.

## CD strategy

`delivery/Jenkinsfile.deploy` checks out the exact requested commit in detached state. This matters because the deployment manifests and Ansible role must come from the same source revision that produced the artifact.

```text
IMAGE_REF + COMMIT_SHA
          │
          ▼
validate immutable inputs
          │
          ▼
git checkout --detach <COMMIT_SHA>
          │
          ▼
ansible-playbook delivery/ansible/deploy.yml
          │
          ▼
render app image to <IMAGE_REF>
          │
          ▼
kubectl apply
          │
          ▼
rollout status
          │
          ▼
read Deployment image
          │
          ├── matches digest → success
          └── differs        → fail
```

The deployment role applies the application ConfigMap, Service, Ingress, and Deployment. It does not permanently rewrite the committed Deployment manifest with the release digest; it renders the image locally for the apply operation.

## Zero-downtime behavior

CD relies on the application Deployment strategy from Stage 4: `maxUnavailable: 0`, readiness probes, and sufficient surge capacity. Jenkins waits for Kubernetes rollout completion before reporting success.

A pipeline success therefore means more than `kubectl apply` returning zero: the rollout completed and the live Deployment reports the requested digest.

## GitHub status

CI and CD publish commit status contexts back to GitHub. CI uses `jenkins/ci`; deployment uses `jenkins/deploy`. Pending, success, and failure states remain tied to the same source revision.

## Agent image

The Jenkins tools image is defined in `delivery/jenkins/ci-agent.Dockerfile`. JCasC references the published image by digest. When tooling changes:

```text
change Dockerfile
     │
     ▼
build + publish agent image
     │
     ▼
record immutable digest
     │
     ▼
update JCasC digest
     │
     ▼
make jenkins-up
```

Do not change the agent image in the Jenkins UI.

## Source paths

`delivery/Jenkinsfile.build` owns CI orchestration. `delivery/Jenkinsfile.deploy` owns CD orchestration. `delivery/ci/` owns build, scan, publish, and status helpers. `delivery/ansible/` owns application reconciliation. `platform/jenkins/jcasc/jenkins.yaml` owns jobs and agent templates.