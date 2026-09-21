# Jenkins

Jenkins is the control plane for CI/CD. The controller runs in Kubernetes and schedules Pipeline work onto Kubernetes agent Pods.

[Delivery flow](../../DELIVERY.md) · [CI agent image](../../delivery/jenkins/README.md)

## Contents

1. [How it is wired](#1-how-it-is-wired)
2. [Where it is configured](#2-where-it-is-configured)
3. [Jobs and agents](#3-jobs-and-agents)
4. [Credentials and access](#4-credentials-and-access)
5. [Reconcile and change](#5-reconcile-and-change)

---

## 1. How it is wired

```text
GitHub
  │  multibranch scan
  ▼
Jenkins controller
  │
  │ Kubernetes plugin
  ▼
agent Pods
  ├── lab-ci-runner        build + scan
  ├── lab-ci-light         lint + verify
  └── lab-cd-runner-<env>  deploy
```

The controller owns Jenkins configuration, the job queue, multibranch jobs and the shared delivery library.

Pipeline stages do not run on the controller. JCasC sets `numExecutors: 0`, and execution capacity comes from Kubernetes-plugin agent Pods.

The Helm chart's static agent is also disabled; the dynamic Pods above are the execution plane.

---

## 2. Where it is configured

| Concern | Source of truth |
|---|---|
| Jenkins Helm release, plugins, persistence, ingress | `platform/jenkins/values.yaml` |
| Jenkins configuration, jobs, agent templates | `platform/jenkins/jcasc/jenkins.yaml` |
| CI ServiceAccount and dry-run-only guard | `platform/jenkins/resources/agent-rbac.yaml` |
| Vault → Jenkins Secrets | `platform/jenkins/resources/*.yaml` |
| Environment deploy identities | `platform/environment/namespace.yaml` |
| Jenkins reconciliation | `platform/jenkins/bin/up` |
| Tools inside CI/CD agents | `delivery/jenkins/ci-agent.Dockerfile` |
| Pipeline implementation | `delivery/pipeline/` |

Durable Jenkins changes belong in Git, not in the Jenkins UI.

---

## 3. Jobs and agents

JCasC creates four multibranch delivery jobs:

| Job | Pipeline | Agent |
|---|---|---|
| `sample-java-app` | service CI | `lab-ci-runner` |
| `resource-requests-webhook` | service CI | `lab-ci-runner` |
| `platform` | platform validation | `lab-ci-light` |
| `deploy` | release verification + deployment | light CI → environment CD |

The heavy CI runner contains the delivery tools plus rootless BuildKit and persistent BuildKit/Trivy caches.

The light runner handles work that does not need those caches.

CD uses the common `cd-runner` template, but the deployment pipeline supplies the environment identity:

```text
cd-runner
   │
   ▼
lab-cd-runner-dev
   │
   ▼
jenkins-deploy-dev
   │
   ▼
apps-dev
```

Jenkins scans GitHub every minute because this lab does not expose Jenkins for inbound GitHub webhooks.

Warm jobs keep one Pod of each execution class reusable between builds.

---

## 4. Credentials and access

External Jenkins credentials come from Vault:

```text
Vault
  │
  ▼
Vault Secrets Operator
  │
  ▼
Kubernetes Secrets
  │
  ▼
JCasC credentials
  │
  ▼
Pipeline bindings
```

| Vault path | Used for |
|---|---|
| `secret/jenkins/admin` | Jenkins admin |
| `secret/ci/github` | repository access, statuses, state commits, promotion PRs |
| `secret/ci/dockerhub` | image and chart registry |
| `secret/ci/cosign` | image signing |

Kubernetes deployment access does **not** use a kubeconfig stored in Jenkins.

CI uses `jenkins-ci`. It can perform server-side dry-runs but a ValidatingAdmissionPolicy denies real writes.

CD uses `jenkins-deploy-<environment>`, created by `platform/environment`, and each identity is bound only to its own application namespace.

```text
jenkins-ci
  └── dry-run validation only

jenkins-deploy-dev
  └── apps-dev only
```

---

## 5. Reconcile and change

Reconcile Jenkins with:

```bash
make jenkins-up
```

The command aligns Vault credentials, Kubernetes Secrets, RBAC, the Helm release, JCasC and the warm agent pool.

Use this map when changing Jenkins:

| Change | Edit |
|---|---|
| plugin / controller / ingress / persistence | `values.yaml` |
| job / agent Pod / Jenkins setting | `jcasc/jenkins.yaml` |
| CI Kubernetes permissions | `resources/agent-rbac.yaml` |
| environment deployment permissions | `../environment/namespace.yaml` |
| Jenkins credential source | Vault + `resources/*.yaml` |
| tools available in agents | `delivery/jenkins/ci-agent.Dockerfile` |
| pipeline behavior | `delivery/pipeline/` |

After a JCasC or agent-template change, `make jenkins-up` removes old agent Pods so new work cannot continue on stale templates.
