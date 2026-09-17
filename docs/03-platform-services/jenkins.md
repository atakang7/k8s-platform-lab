# Jenkins

Jenkins is the delivery controller. Configuration, credentials wiring, agent templates, and pipeline jobs are declared from Git.

## Runtime model

```text
                    https://jenkins.lab.test
                                  │
                                  ▼
                           ingress-nginx
                                  │
                                  ▼
                    ┌────────────────────────┐
                   /                        /│
                  / Jenkins controller     / │
                 └────────────────────────┘  │
                 │ node-3                 │  │
                 │ persistent 8 GiB PVC   │  │
                 │ 0 executors            │ /
                 └───────────┬────────────┘/
                             │ Kubernetes plugin
                 ┌───────────┴───────────┐
                 │                       │
                 ▼                       ▼
        ┌──────────────────┐    ┌──────────────────┐
       / CI agent         /│   / CD agent         /│
      / lab-ci-runner  / │  / lab-cd-runner / │
     └──────────────────┘  │ └──────────────────┘  │
     │ node-3            │ /  │ node-3            │ /
     └──────────────────┘/   └──────────────────┘/
```

The controller never builds or deploys application code itself. `numExecutors: 0` keeps controller CPU, memory, and filesystem state out of the workload execution path.

## Declarative configuration

The Helm chart creates the controller. JCasC then defines:

- the local admin realm;
- GitHub and Docker Hub credentials;
- the cluster kubeconfig credential;
- CI and CD Kubernetes agent templates;
- `lab-build` and `lab-deploy` pipeline jobs.

The controller can therefore be recreated without manually rebuilding jobs in the UI.

Source: [`platform/jenkins/jcasc/jenkins.yaml`](../../platform/jenkins/jcasc/jenkins.yaml).

## Credential path

```text
operator stores values in Vault
            │
            ▼
Vault paths
  secret/ci/github
  secret/ci/dockerhub
            │
            ▼
Vault Secrets Operator
            │
            ▼
Kubernetes Secrets · jenkins namespace
            │
            ▼
JCasC environment / Jenkins credentials store
            │
            ▼
CI/CD jobs
```

Jenkins configuration contains credential references, not credential values. Vault remains the authority for the underlying secrets.

## Agent separation

CI and CD use separate labels and templates even though both are pinned to `node-3`.

| Agent | Owns | Important state |
|---|---|---|
| `lab-ci-runner` | tests, lint, BuildKit, Trivy, publication | Maven, Trivy, BuildKit caches |
| `lab-cd-runner` | exact-commit checkout and Kubernetes deployment | kubeconfig credential only |

The split keeps deployment capability out of the image-build path and makes the execution intent visible in Jenkins scheduling.

## CI warm state

The CI Pod is disposable. Expensive caches are not.

```text
CI Pod starts
    │
    ├── /root/.m2       ──► hostPath /var/lib/lab-ci/m2
    ├── Trivy cache     ──► hostPath /var/lib/lab-ci/trivy
    └── BuildKit state  ──► hostPath /var/lib/lab-ci/buildkit
```

This preserves dependency and layer reuse across agent Pods without making the Jenkins controller a build host.

The current agent template has an instance cap of one. If CI concurrency is increased later, BuildKit state must be separated per concurrent builder instead of sharing one mutable hostPath.

## Agent image

The CI toolchain is built as its own image and pinned in JCasC by digest. This prevents every pipeline run from reinstalling Maven/Kubernetes/Ansible/scanning tools and removes mutable-tag drift from the agent environment.

Change sequence:

```text
change ci-agent.Dockerfile
        │
        ▼
build + publish agent image
        │
        ▼
resolve immutable digest
        │
        ▼
update JCasC digest
        │
        ▼
make jenkins-up
```

## Controller placement and persistence

The controller is pinned to `node-3` and uses an 8 GiB `local-path` PVC. Pod recreation preserves Jenkins home on that node. Node loss is not masked as storage HA; the reference cluster has no distributed storage layer.

## Reconciliation

```bash
make jenkins-up
```

The bootstrap script creates the namespace and Vault integration, waits for synchronized credentials, then installs/upgrades the pinned Jenkins chart with the repository JCasC.

Implementation: [`platform/jenkins/`](../../platform/jenkins/), [`delivery/jenkins/`](../../delivery/jenkins/).
