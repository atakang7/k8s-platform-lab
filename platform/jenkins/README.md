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
             │ lab-ci-runner  │
             │ heavy CI         │
             ├──────────────────┤
             │ BuildKit         │
             │ Trivy            │
             │ chart tooling    │
             │ persistent cache │
             └──────────────────┘

             ┌──────────────────┐
             │ lab-ci-light   │
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
sample-java-app
      │
      ▼
service CI
      │
      ▼
lab-ci-runner


resource-requests-webhook
      │
      ▼
service CI
      │
      ▼
lab-ci-runner


platform
      │
      ▼
platform validation
      │
      ▼
lab-ci-light


deploy
      │
      ├── verify state
      │      │
      │      ▼
      │  light runner
      │
      └── deploy
             │
             ▼
        cd-runner
~~~

JCasC creates these multibranch delivery jobs from Git.

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
| jobs, JCasC, agent templates | `jcasc/jenkins.yaml` |
| CI Kubernetes access | `resources/agent-rbac.yaml` |
| environment deploy identities | `../environment/namespace.yaml` |
| Vault-to-Jenkins Secrets | `resources/*.yaml` |
| reconciliation | `bin/up` |
| CI/CD agent image | `../../delivery/jenkins/ci-agent.Dockerfile` |
| Pipeline implementation | `../../delivery/pipeline/` |

Durable Jenkins changes belong in Git, not in the Jenkins UI.

For release mechanics, continue with
**[DELIVERY.md](../../DELIVERY.md)**.
