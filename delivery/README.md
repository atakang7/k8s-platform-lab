# Delivery

`delivery/` owns application build, security reporting, artifact publication, and Kubernetes deployment.

The release contract is simple: CI produces an immutable image digest for one Git commit. CD checks out that exact commit and deploys that exact digest.

## Flow

```text
GitHub main
    │
    │ Jenkins SCM poll · 1 minute
    │
┌───┴────────────────────────────────────────────────────────────┐
│ lab-build · lab-ci-runner                                │
│                                                              │
│ checkout                                                     │
│   ├─ Maven tests                                             │
│   ├─ Dockerfile lint                                         │
│   ├─ Kubernetes server-side dry-run                          │
│   └─ Ansible syntax check                                    │
│                                                              │
│ BuildKit local image                                         │
│ Trivy HIGH/CRITICAL report + CycloneDX SBOM                  │
│ BuildKit registry push                                       │
└──────────────────────────────┬───────────────────────────────┘
                               │ repository@sha256:...
                               │ exact commit SHA
┌──────────────────────────────┴───────────────────────────────┐
│ lab-deploy · lab-cd-runner                              │
│                                                             │
│ validate inputs                                              │
│ detached checkout of exact commit                           │
│ Ansible apply                                                │
│ rollout status                                               │
│ assert live image == requested digest                       │
└─────────────────────────────────────────────────────────────┘
```

CI queues CD asynchronously after publication. A slow deployment does not keep the build executor occupied.

## CI

`Jenkinsfile.build` runs on the exclusive `lab-ci-runner` agent.

The validation work is parallelized before the image build. Kubernetes manifests are checked with `--dry-run=server`, so admission and API validation use the live API server without creating test workloads.

Image construction uses BuildKit. The warm runner keeps these node-local caches on `node-3`:

- Maven: `/var/lib/lab-ci/m2`
- Trivy: `/var/lib/lab-ci/trivy`
- BuildKit: `/var/lib/lab-ci/buildkit`

The final registry reference is written as `repository@sha256:<digest>`. CD does not accept mutable tags as deployment input.

### Security scan

`ci/scan-image.sh` scans the local image before publication and writes a CycloneDX SBOM to `sbom.json`. Jenkins archives that SBOM.

By default, Trivy findings are **report-only** because `TRIVY_EXIT_CODE` defaults to `0`. Set `TRIVY_EXIT_CODE` to a failing value when vulnerability findings should block publication.

## CD

`Jenkinsfile.deploy` runs on the exclusive `lab-cd-runner` agent.

CD rejects an image unless it matches an immutable SHA-256 digest reference and rejects a source revision unless it is a full Git SHA. It checks out that revision detached before deployment.

`ansible/deploy.yml` applies the application ConfigMap, Service, and Ingress, then renders the Deployment with the supplied image digest. The deployment role waits for rollout completion and reads the live Deployment back to verify the requested digest is running.

The application Deployment uses `maxUnavailable: 0`; the rollout does not intentionally remove an old replica before replacement capacity is ready.

## Jenkins integration

Jenkins jobs and agent templates are defined in [`platform/jenkins/jcasc/jenkins.yaml`](../platform/jenkins/jcasc/jenkins.yaml). Do not recreate job definitions manually in the Jenkins UI.

The CI agent image is defined by:

- `jenkins/ci-agent.Dockerfile`
- `jenkins/build-ci-agent.sh`
- `jenkins/agent.yaml`

The JCasC image reference is pinned by digest. When the agent image changes, publish the new image first, update the digest in JCasC, then reconcile Jenkins.

## Files

| Path | Purpose |
|---|---|
| `Jenkinsfile.build` | CI orchestration |
| `Jenkinsfile.deploy` | CD orchestration |
| `ci/test.sh` | Application tests |
| `ci/lint.sh` | Static configuration checks |
| `ci/build-image.sh` | Build local image artifact with BuildKit |
| `ci/scan-image.sh` | Trivy report and CycloneDX SBOM |
| `ci/publish-image.sh` | Registry push and immutable digest capture |
| `ci/github-status.sh` | Commit status reporting |
| `ansible/` | Kubernetes release reconciliation |
| `jenkins/` | Reproducible Jenkins agent image |

## Operating rule

A release is identified by two values: the full Git commit SHA and the immutable image digest. Keep those together when debugging or rolling back. A manual cluster image change breaks that traceability and should not be treated as a normal release path.