# 05 — Delivery

This layer converts one Git commit into one immutable image and deploys that exact artifact back against the same source revision.

## End-to-end flow

```text
GitHub · main
    │
    │ SCM poll · 1 minute
    ▼
┌─────────────────────────────────────────────────────────────┐
│ lab-build · lab-ci-runner · node-3                    │
│                                                             │
│ checkout commit                                             │
│      │                                                      │
│      ├── Maven tests ───────────────┐                       │
│      ├── Dockerfile lint ───────────┤                       │
│      ├── K8s server dry-run ────────┤ parallel validation   │
│      └── Ansible syntax check ──────┘                       │
│      │                                                      │
│      ▼                                                      │
│ BuildKit solve #1                                           │
│ same source + app/ context                                  │
│      │                                                      │
│      ▼                                                      │
│ app-image.tar ──► Trivy HIGH/CRITICAL report + SBOM        │
│      │             scan step completes                     │
│      ▼                                                      │
│ BuildKit solve #2 · same source/context · warm cache        │
│      │                                                      │
│      ▼                                                      │
│ registry push ──► repository@sha256:<digest>                │
└───────────────────────────┬─────────────────────────────────┘
                            │ async enqueue
                            │ exact commit SHA + image digest
                            ▼
┌─────────────────────────────────────────────────────────────┐
│ lab-deploy · lab-cd-runner · node-3                   │
│                                                             │
│ validate immutable inputs                                   │
│      │                                                      │
│      ▼                                                      │
│ checkout --detach <exact commit>                            │
│      │                                                      │
│      ▼                                                      │
│ Ansible render/apply Deployment with immutable digest       │
│      │                                                      │
│      ▼                                                      │
│ rollout status                                              │
│      │                                                      │
│      ▼                                                      │
│ read live Deployment ──► assert exact digest                │
└─────────────────────────────────────────────────────────────┘
```

The local tar is scan input only. The registry publication is a second BuildKit solve after scanning, against the same checked-out source and build context, with the warm BuildKit state reused.

The release identity is the pair:

```text
full Git commit SHA + repository@sha256:image-digest
```

A mutable tag is not accepted by CD.

## Trigger model

Jenkins polls the repository every minute. A source change therefore does not require a manually started build.

The benchmarked path used a real no-behavior source change. The measured reference run was:

| Segment | Time |
|---|---:|
| SCM detection | `50.70s` |
| CI pipeline | `63.72s` |
| CI → CD scheduling | `6.33s` |
| CD pipeline | `69.51s` |
| commit → production ready | `190.26s` |

Those numbers describe one observed run, not an SLO. They prove the complete automatic path and provide a baseline for later optimization.

## CI checks run before publication

The independent validation checks run in parallel:

- Maven unit tests;
- Hadolint Dockerfile lint;
- Kubernetes `--dry-run=server` for runtime manifests;
- Ansible syntax validation.

Server-side dry-run is intentional. It sends objects through the real API server and admission chain without leaving test workloads behind.

Kubernetes authorizes a dry-run exactly like a real write, so the CI identity (`jenkins-ci`) holds write verbs. The `jenkins-ci-dry-run-only` ValidatingAdmissionPolicy rejects any request from it that is not a dry-run; only CD's `jenkins-agent` identity can change the cluster.

A failed check stops artifact publication.

## Build strategy

BuildKit owns image construction. The CI agent has a dedicated BuildKit container and persistent node-local state.

```text
node-3 host state

/var/lib/lab-ci/m2       ─────► Maven cache
/var/lib/lab-ci/trivy    ─────► Trivy cache
/var/lib/lab-ci/buildkit-rootless ► BuildKit state
                                            │
                                            ▼
                                   lab-ci-runner Pod
```

The agent Pod is disposable; expensive dependency, scanner, and layer caches survive on node-3.

The Dockerfile itself also separates dependency resolution from source copy, so unchanged Maven dependencies and unchanged image layers can be reused.

## Security reporting

The first BuildKit solve exports a local Docker archive for scanning. Publication performs a second solve against the same commit and build context, reusing the warm BuildKit cache.

```text
checked-out commit + app/ context
             │
             ▼
      BuildKit solve #1
             │
             ▼
        app-image.tar
             │
             ▼
Trivy scan + CycloneDX SBOM
             │ scan stage completed
             ▼
      BuildKit solve #2
      same source + warm cache
             │
             ▼
        registry push
             │
             ▼
 immutable registry digest
```

Jenkins archives the SBOM.

Trivy is currently report-only because `TRIVY_EXIT_CODE` defaults to `0`. This is explicit behavior, not a hidden gate. Set a failing exit code when vulnerability policy should block publication.

## Immutable publication

Registry credentials exist only around the publication step. CI creates a temporary Docker config from the Jenkins credential binding, pushes through BuildKit, records the resulting digest, and removes the temporary auth directory.

CD receives the digest, not the tag used during the push.

## Asynchronous handoff

CI enqueues `lab-deploy` with `wait: false` after publication.

```text
CI publishes digest
       │
       ├── writes GitHub CI success status
       │
       └── enqueues lab-deploy · wait: false
                        │
                        ▼
                 CI executor is free
```

Deployment duration therefore does not keep the build agent occupied.

## Exact-source deployment

CD validates both inputs:

- `IMAGE_REF` must be `docker.io/atakangul/sample-java-app@sha256:<64 hex>` (checked by the Ansible role; other repositories are rejected);
- `COMMIT_SHA` must be a full 40-character Git SHA.

It then checks out that commit in detached HEAD state. Deployment manifests and Ansible logic therefore come from the same revision that produced the artifact.

## Deployment strategy

Ansible applies the runtime ConfigMap, Service, and Ingress, then renders the Deployment locally with the supplied digest and sends that object to Kubernetes.

```text
immutable IMAGE_REF
       │
       ▼
kubectl set image --local
       │ renders Deployment YAML only
       ▼
kubectl apply
       │
       ▼
kubectl rollout status
       │
       ▼
read live app container image
       │
       ├── equals IMAGE_REF ──► success
       └── mismatch ──────────► fail
```

This final read-back turns "kubectl apply succeeded" into a stronger invariant: the intended immutable artifact is actually the one referenced by the live Deployment.

The application Deployment itself uses `maxUnavailable: 0` and readiness probes, so CD waits on Kubernetes' availability-aware rollout behavior instead of sleeping for an arbitrary period.

## Commit status

Both pipelines write GitHub commit statuses for pending/success/failure. The source revision therefore carries the delivery result without requiring Jenkins to be open while reviewing a commit.

## Source paths

- [`delivery/Jenkinsfile.build`](../../delivery/Jenkinsfile.build) — CI orchestration.
- [`delivery/Jenkinsfile.deploy`](../../delivery/Jenkinsfile.deploy) — CD orchestration.
- [`delivery/ci/`](../../delivery/ci/) — tests, BuildKit, scan, publish, commit status.
- [`delivery/ansible/`](../../delivery/ansible/) — deployment reconciliation.
- [`delivery/jenkins/`](../../delivery/jenkins/) — reproducible CI agent image.
- [`platform/jenkins/jcasc/jenkins.yaml`](../../platform/jenkins/jcasc/jenkins.yaml) — jobs and agent templates.
