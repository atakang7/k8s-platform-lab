# Jenkins

`platform/jenkins/` owns the Jenkins control plane: controller configuration, Kubernetes agent templates, job definitions, credentials wiring, and the reconciliation path that keeps them aligned with Git and Vault.

[Delivery behavior](../../delivery/README.md) · [CI agent image](../../delivery/jenkins/README.md)

## Table of contents

1. [Architecture](#1-architecture)
2. [Controller](#2-controller)
3. [Kubernetes execution plane](#3-kubernetes-execution-plane)
4. [Jobs and scheduling](#4-jobs-and-scheduling)
5. [Identity and permissions](#5-identity-and-permissions)
6. [Credentials and Vault](#6-credentials-and-vault)
7. [Reconciliation](#7-reconciliation)
8. [Warm agents and capacity](#8-warm-agents-and-capacity)
9. [Operating rules](#9-operating-rules)
10. [Validation](#10-validation)

---

## 1. Architecture

Jenkins is split into a persistent controller and ephemeral Kubernetes execution Pods.

~~~text
                         GitHub
                           │
                    multibranch scan
                           │
                           ▼
                ┌──────────────────────┐
                │ Jenkins controller   │
                │ StatefulSet · node-3 │
                │ queue / JCasC / jobs │
                │ shared library       │
                └──────────┬───────────┘
                           │ Kubernetes plugin
             ┌─────────────┼─────────────┐
             ▼             ▼             ▼
      lab-ci-runner  lab-ci-light  lab-cd-runner-<env>
      build + scan     lint + verify   deploy
      jenkins-ci       jenkins-ci      jenkins-deploy-<env>
~~~

The controller coordinates Jenkins. Pipeline work is scheduled onto Kubernetes agent Pods.

The literal JCasC setting is:

~~~yaml
jenkins:
  numExecutors: 0
~~~

That disables the controller's **built-in node** as a place to run Pipeline stages. It does not mean Jenkins has no executors: execution capacity is supplied by the Kubernetes-plugin agent Pods below.

The Helm chart's own static agent is also disabled:

~~~yaml
agent:
  enabled: false
~~~

This is separate from the Kubernetes plugin. Dynamic agent Pods remain the execution model.

---

## 2. Controller

The controller is installed with the pinned Jenkins Helm chart and runs as a StatefulSet in namespace `jenkins`.

~~~text
node-3
  │
  ▼
Jenkins StatefulSet
  │
  ├── persistent Jenkins home
  ├── JCasC
  ├── pinned plugins
  ├── Job DSL
  ├── GitHub Branch Source
  └── Kubernetes plugin
  │
  ▼
ClusterIP Service
  │
  ▼
nginx Ingress
  │
  ▼
https://jenkins.lab.test
~~~

### Runtime shape

| Property | Configuration |
|---|---|
| Placement | `node-3` |
| Persistence | 8 GiB `local-path` PVC |
| Service | ClusterIP |
| External endpoint | `https://jenkins.lab.test` |
| Agent transport | WebSocket |
| Jenkins TCP agent listener | disabled |
| Config auto-reload sidecar | disabled |

The controller is deliberately stateful because Jenkins keeps job/build metadata under Jenkins home. Durable configuration is still Git-owned through Helm values and JCasC.

### Plugin ownership

`values.yaml` pins the complete resolved plugin set and sets:

~~~yaml
installLatestPlugins: false
~~~

Plugin upgrades are explicit repository changes. Jenkins is not allowed to silently resolve a newer plugin set during reconciliation.

### Configuration as code

`jcasc/jenkins.yaml` owns:

- Jenkins security realm;
- Kubernetes cloud configuration;
- agent Pod templates;
- Jenkins credentials exposed from Kubernetes Secrets;
- multibranch jobs;
- warm-agent jobs;
- the `lab-delivery` shared library.

Durable controller configuration should not be edited in the UI.

---

## 3. Kubernetes execution plane

The Kubernetes plugin provisions three execution classes.

### 3.1 Heavy CI — `lab-ci-runner`

Used by service CI for image build and scan work.

~~~text
lab-ci-runner Pod · node-3
│
├── Jenkins agent connection
├── ci-tools
│   ├── git
│   ├── kubectl
│   ├── helm
│   ├── hadolint
│   ├── trivy
│   ├── skopeo
│   ├── cosign
│   └── shellcheck
│
├── chart-testing
│
└── rootless BuildKit
    │
    └── persistent BuildKit state
~~~

Important properties:

- fixed to `node-3` because its caches are node-local;
- runs as ServiceAccount `jenkins-ci`;
- one instance maximum;
- ten-minute idle retention;
- persistent hostPath BuildKit state;
- persistent hostPath Trivy cache;
- delivery tools run as uid/gid 1000;
- BuildKit is rootless and not privileged.

An init container corrects ownership of the cache paths before the non-root containers use them.

### 3.2 Light CI — `lab-ci-light`

Used for work that does not need image-build state:

~~~text
platform lint
chart testing
deploy verification
server-side dry-run
~~~

It runs with `jenkins-ci` but has no BuildKit or Trivy hostPath state.

This prevents lightweight validation from queueing behind the single heavy image builder.

### 3.3 CD — `lab-cd-runner-<environment>`

`cd-runner` is a base Pod template. The deployment pipeline inherits it and supplies the environment-specific ServiceAccount dynamically:

~~~text
cd-runner template
      │
      │ deployPipeline()
      ▼
lab-cd-runner-dev
      │
      ▼
ServiceAccount
jenkins-deploy-dev
      │
      ▼
apps-dev
~~~

The same pattern applies to stage and prod clusters.

The base CD template carries no fixed deployment identity of its own. The identity is selected by the environment being released.

---

## 4. Jobs and scheduling

JCasC creates four GitHub multibranch delivery jobs:

| Job | Jenkinsfile | Execution |
|---|---|---|
| `sample-java-app` | `app/Jenkinsfile` | service CI |
| `resource-requests-webhook` | `policies/resource-requests-webhook/Jenkinsfile` | service CI |
| `platform` | `delivery/Jenkinsfile.platform` | platform/repository validation |
| `deploy` | `delivery/Jenkinsfile.deploy` | state verification and CD |

All use the platform-owned `lab-delivery` shared library from:

~~~text
delivery/pipeline/
~~~

Library version override is disabled, so a service cannot select a different delivery implementation.

### GitHub discovery

Jenkins is not reachable from GitHub in this lab, so jobs do not depend on inbound webhooks.

Each multibranch job re-indexes GitHub every minute:

~~~text
GitHub
  │
  │ periodic scan
  ▼
main / PR heads
  │
  ▼
matching Jenkins job
~~~

Only `main` and pull requests are built. Ordinary feature branches reach CI through their PR.

GitHub Branch Source posts the resulting commit statuses.

### Service onboarding

A new service needs:

~~~text
service Jenkinsfile
      +
JCasC services[] entry
      +
service chart/state configuration
~~~

Jenkins itself does not contain service-specific pipeline logic beyond selecting the service Jenkinsfile.

---

## 5. Identity and permissions

Execution identity is separated from Jenkins credentials.

### CI identity

Heavy and light CI use:

~~~text
system:serviceaccount:jenkins:jenkins-ci
~~~

Environment namespaces bind `jenkins-ci` to the deployer's verbs because Kubernetes server-side dry-run requires authorization as if the operation were real.

A cluster-wide `ValidatingAdmissionPolicy` then blocks every non-dry-run mutation from that identity:

~~~text
jenkins-ci request
      │
      ▼
RBAC authorizes operation
      │
      ▼
jenkins-ci-dry-run-only
      │
      ├── dryRun=true  ──► allow validation path
      └── real write   ──► deny
~~~

So CI can exercise the real API/admission path without becoming a deployment identity.

### CD identities

`platform/environment` creates one deployment ServiceAccount for the environment run by that cluster:

~~~text
jenkins-deploy-dev
jenkins-deploy-stage
jenkins-deploy-prod
~~~

Each is bound only inside its environment namespace.

The repository verifies that a deploy identity:

- can create deployments in its own namespace;
- cannot create deployments cluster-wide;
- cannot read Secrets in the application namespace.

No kubeconfig or long-lived cluster token is stored as a Jenkins credential. Agent Pods use their Kubernetes ServiceAccount identity directly.

Legacy agent token/kubeconfig resources are explicitly removed during reconciliation.

---

## 6. Credentials and Vault

External Jenkins credentials originate in Vault.

~~~text
operator input
    │ first load / rotation
    ▼
Vault KV
    │
    │ Vault Secrets Operator
    ▼
Kubernetes Secrets · jenkins namespace
    │
    ▼
Jenkins controller environment
    │
    ▼
JCasC credentials
    │
    ▼
Pipeline credential binding
~~~

### Vault paths

| Vault path | Purpose |
|---|---|
| `secret/jenkins/admin` | Jenkins local admin |
| `secret/ci/github` | private repository access, statuses, state commits and promotion PRs |
| `secret/ci/dockerhub` | image/chart registry access |
| `secret/ci/cosign` | image signing key and password |

VSO materializes these as Kubernetes Secrets.

The controller reads them at startup. The corresponding `VaultStaticSecret` resources declare the Jenkins StatefulSet as a restart target when values change.

### Reconciliation behavior

On `make jenkins-up`:

- provided operator values are written only when different;
- existing Vault values are reused when variables are omitted;
- missing mandatory Vault entries fail clearly;
- Kubernetes Secrets are checked against Vault before Jenkins is reconciled.

This avoids creating needless Vault versions or restarting Jenkins when credential values have not changed.

---

## 7. Reconciliation

The supported entry point is:

~~~bash
make jenkins-up
~~~

The flow is:

~~~text
Vault
  │
  ├── reconcile CI credentials
  ├── create/reuse admin credential
  └── reconcile Jenkins AppRole
  │
  ▼
Kubernetes
  │
  ├── namespace + Vault CA
  ├── VaultConnection / VaultAuth
  ├── VaultStaticSecrets
  ├── CI ServiceAccount + dry-run policy
  └── remove obsolete delivery credentials
  │
  ▼
verify Vault ↔ Kubernetes Secret equality
  │
  ▼
Helm upgrade --install Jenkins
  │
  ▼
JCasC creates cloud / jobs / credentials / library
  │
  ▼
remove existing agent Pods
  │
  ▼
prime warm agent jobs
~~~

The Helm reconciliation uses:

~~~text
--wait
--rollback-on-failure
--timeout 10m
--history-max 5
~~~

Existing agent Pods are removed after reconciliation because agent templates are materialized when a Pod is created. Without this cleanup, a retained warm Pod could continue using an old tool image or identity after Git changed.

---

## 8. Warm agents and capacity

Dynamic Pods normally introduce provisioning latency. This repository keeps one agent of each active class warm.

JCasC creates:

~~~text
warm-ci-runner
warm-ci-light
warm-cd-runner-dev
~~~

Each job runs once per minute and briefly requests its corresponding node label.

~~~text
warm job
   │
   ▼
Kubernetes plugin sees demand
   │
   ▼
agent Pod exists
   │
   ▼
idleMinutes = 10
   │
   ▼
real pipeline reuses Pod
~~~

`make jenkins-up` also triggers the warm jobs immediately after reconciliation rather than waiting for the next cron tick.

Capacity is deliberately bounded for the small edge cluster:

~~~text
Kubernetes cloud cap: 3 agent Pods

ci-runner   instanceCap: 1
ci-light    instanceCap: 1
cd-runner   instanceCap: 1
~~~

The goal is predictable resource use, not maximum parallelism.

---

## 9. Operating rules

~~~text
Git/JCasC  = controller and job configuration
Vault      = credential source
Kubernetes = execution identity
Jenkins    = orchestration
~~~

Rules:

- do not create durable jobs manually in the Jenkins UI;
- do not change agent templates in the UI;
- do not store kubeconfigs or ServiceAccount tokens as Jenkins credentials;
- rotate external credentials through Vault;
- change the CI tools image through `delivery/jenkins/build-ci-agent.sh`;
- pin the resulting agent image digest in JCasC;
- run `make jenkins-up` after Jenkins configuration changes.

The CI-agent image itself is documented in [`delivery/jenkins/README.md`](../../delivery/jenkins/README.md).

---

## 10. Validation

The end-to-end validator checks the running Jenkins installation as part of:

~~~bash
make e2e-validate
~~~

Its Jenkins checks prove:

- the required credential Secrets exist;
- the controller StatefulSet is Ready;
- exactly one controller Pod is running on `node-3`;
- Jenkins persistence is Bound;
- the nginx Ingress exists;
- DNS resolves the Jenkins hostname through the platform ingress VIP;
- the HTTPS login endpoint responds;
- the configured built-in-node executor count is zero.

The environment reconciliation separately proves the access model:

~~~text
jenkins-ci
  real write ──► denied

jenkins-deploy-<env>
  own namespace deployment ──► allowed
  all namespaces            ──► denied
  Secrets read              ──► denied
~~~

These checks validate the runtime contract rather than relying only on YAML inspection.
