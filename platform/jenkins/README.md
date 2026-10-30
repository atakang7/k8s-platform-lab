# Jenkins

Jenkins is the CI/CD control plane. The controller runs in Kubernetes,
while Pipeline work runs on Kubernetes agent Pods.

## 1. Execution model

~~~text
GitHub
  │ multibranch scan
  ▼
┌──────────────────────┐
│ Jenkins controller   │
│ node-3               │
│ numExecutors: 0      │
└──────────┬───────────┘
           │ schedules
           ▼
┌──────────────────────┐
│ Kubernetes plugin    │
└──────────┬───────────┘
           │
     ┌─────┼──────────────┐
     │     │              │
     ▼     ▼              ▼
 heavy   light           CD
 CI      CI              agent
~~~

The controller owns configuration, jobs, queueing, and agent
orchestration. It does not execute Pipeline stages itself.

## 2. Agent classes

~~~text
                  EXECUTION PLANE

             ┌──────────────────┐
             │ lab-ci-runner    │
             │ heavy CI         │
             ├──────────────────┤
             │ BuildKit         │
             │ Trivy            │
             │ chart tooling    │
             │ persistent cache │
             └──────────────────┘

             ┌──────────────────┐
             │ lab-ci-light     │
             │ light checks     │
             ├──────────────────┤
             │ lint             │
             │ verify           │
             │ state checks     │
             └──────────────────┘

             ┌──────────────────┐
             │ cd-runner        │
             │ deployment       │
             ├──────────────────┤
             │ env identity     │
             │ Helm / kubectl   │
             └──────────────────┘
~~~

Heavy builds stay separate from light validation so expensive image work
does not block small checks.

Warm jobs keep one reusable Pod from each execution class available.

## 3. Job map

~~~text
GitHub poll (every minute)
      │
      ├── sample-java-app ──────────► lab-ci-runner
      │   main + PR, service CI
      │
      ├── resource-requests-webhook ► lab-ci-runner
      │   main + PR, service CI
      │
      ├── platform ─────────────────► lab-ci-light
      │   main + PR, platform validation
      │
      └── deploy ───────────────────► cd-runner
          main + PR, state verification / deploy


cron (every minute)
      │
      ├── warm-ci-runner ───────────► lab-ci-runner
      ├── warm-ci-light ────────────► lab-ci-light
      └── warm-cd-runner-dev ───────► cd-runner (jenkins-deploy-dev)
~~~

Four multibranch jobs watch main and pull requests via GitHub polling.
Three cron jobs keep one agent Pod of each class warm so the first real
build does not wait for provisioning.

A commit can start all four multibranch builds, but each pipeline's
own conditions decide which stages actually execute.

## 4. CI identity

~~~text
jenkins-ci
    │
    ▼
Kubernetes API
    │
    ├── server-side dry-run  ✓
    │
    └── real write           ✗
~~~

CI needs the real admission chain for validation, but it must not become
a deployment identity. A Kubernetes policy permits dry-run validation
while denying real writes.

## 5. CD identity

~~~text
deploy job
    │ selects environment
    ▼
cd-runner
    │ uses
    ▼
jenkins-deploy-dev
    │ bound only to
    ▼
apps-dev
~~~

Each environment gets its own deployment service account.

~~~text
jenkins-deploy-dev    ──► apps-dev
jenkins-deploy-stage  ──► apps-stage
jenkins-deploy-prod   ──► apps-prod
~~~

The deployment identity is namespace-scoped and cannot read application
Secrets.

No deployment kubeconfig is stored in Jenkins.

## 6. Credential path

~~~text
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
~~~

Runtime credentials come from Vault rather than being committed to Git.

| Vault path | Used for |
|---|---|
| `secret/jenkins/admin` | Jenkins administrator |
| `secret/ci/github` | repository and promotion operations |
| `secret/ci/dockerhub` | image and chart registry |
| `secret/ci/cosign` | image signing |

## 7. Controller placement

~~~text
              node-3
                 │
       ┌─────────┴─────────┐
       │                   │
       ▼                   ▼
┌──────────────┐    ┌──────────────┐
│ Jenkins      │    │ CI/CD agents │
│ controller   │    │ dynamic Pods │
└──────────────┘    └──────────────┘
       │
       ▼
persistent local-path PVC
~~~

The controller is pinned to `node-3` and keeps Jenkins state on a
persistent volume.

## 8. Access path

~~~text
client
  │
  ▼
jenkins.lab.test
  │
  ▼
BIND9
  │
  ▼
MetalLB ingress VIP
  │
  ▼
ingress-nginx
  │
  ▼
Jenkins ClusterIP Service
  │
  ▼
controller
~~~

Jenkins is exposed through the shared ingress LoadBalancer rather than
through a dedicated LoadBalancer Service.

## 9. Repository polling

~~~text
GitHub
  ▲
  │ poll every minute
  │
Jenkins multibranch jobs
~~~

This lab does not expose an inbound GitHub webhook endpoint, so Jenkins
discovers repository changes by polling.

## 10. Reconcile

~~~text
make jenkins-up
      │
      ▼
Vault credentials
      │
      ▼
Kubernetes Secrets
      │
      ▼
RBAC
      │
      ▼
Helm release
      │
      ▼
JCasC
      │
      ▼
warm agent pool
~~~

After agent-template changes, reconciliation removes stale agent Pods so
new work cannot continue on an old template.

## 11. Sources of truth

| Concern | File |
|---|---|
| controller, plugins, persistence, ingress | `values.yaml` |
| login | `jcasc/security.yaml` |
| agent templates | `jcasc/agents.yaml` |
| agent pod specs | `pods/*.yaml` |
| credentials | `jcasc/credentials.yaml` |
| jobs | `jobs.groovy` |
| pipeline library | `jcasc/jobs.yaml` |
| CI Kubernetes access | `resources/agent-rbac.yaml` |
| environment deploy identities | `../environment/namespace.yaml` |
| Vault-to-Jenkins Secrets | `resources/*.yaml` |
| reconciliation | `bin/up` |
| CI/CD agent image | `../../delivery/jenkins/ci-agent.Dockerfile` |
| Pipeline implementation | `../../delivery/pipeline/` |

Durable Jenkins changes belong in Git, not in the Jenkins UI.

For release mechanics, continue with
**[DELIVERY.md](../../DELIVERY.md)**.
