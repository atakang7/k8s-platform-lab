# Delivery implementation

`delivery/` is the reusable CI/CD implementation. A service plugs into
it with a Helm chart and a small Jenkinsfile.

## 1. Delivery ownership

~~~text
service repository path
        │
        ▼
service Jenkinsfile
        │
        ▼
┌──────────────────────┐
│ lab-delivery         │
│ shared library       │
└──────────┬───────────┘
           │
     ┌─────┴──────────────┐
     │                    │
     ▼                    ▼
servicePipeline()    deployPipeline()
     │                    │
     ▼                    ▼
build / scan         verify / deploy
publish / state      promote / rollback
~~~

Delivery does not own service business logic, platform infrastructure,
or environment namespaces.

## 2. Main implementation paths

| Path | Responsibility |
|---|---|
| `pipeline/vars/servicePipeline.groovy` | service CI |
| `pipeline/vars/deployPipeline.groovy` | environment CD |
| `pipeline/vars/delivery.groovy` | shared helpers |
| `pipeline/resources/lab/delivery/` | shell implementation |
| `Jenkinsfile.deploy` | deploy job entry |
| `Jenkinsfile.platform` | platform checks/chart publish |
| `jenkins/` | CI/CD agent image |

## 3. Jenkins job model

~~~text
GitHub
  │
  ▼
Jenkins multibranch
  │
  ├── sample-java-app
  │      │
  │      ▼
  │   servicePipeline
  │
  ├── resource-requests-webhook
  │      │
  │      ▼
  │   servicePipeline
  │
  ├── platform
  │      │
  │      ▼
  │   Jenkinsfile.platform
  │
  └── deploy
         │
         ▼
      deployPipeline
~~~

Jobs do not directly trigger each other.

A service job writes release state to Git; the resulting state change is
what the deploy job observes.

## 4. Service CI

~~~text
service change
     │
     ▼
Validate
     │
     ├── Dockerfile lint
     ├── version increase
     ├── Helm render
     └── server dry-run
     │
     ▼
Build
     │
     └── unit tests inside image build
     │
     ▼
Scan
     │
     ├── CRITICAL gate
     └── CycloneDX SBOM
     │
     ▼
main only
     │
     ▼
Publish + sign
     │
     ▼
state/dev.yaml
~~~

The webhook uses the same image pipeline, but its deployment is
operator-owned because it is not listed under `releases`.

## 5. Build-once implementation

~~~text
build-image.sh
      │
      ▼
OCI layout
      │
  ┌───┴───────────┐
  │               │
  ▼               ▼
scan-image.sh   publish-image.sh
  │               │
  └───────┬───────┘
          ▼
 exact digest match
          │
          ▼
        Cosign
~~~

The publish step sends the already-scanned OCI bytes instead of
rebuilding the image.

## 6. Git state handoff

~~~text
CI
 │
 ▼
state/dev.yaml
 │
 │ Git commit
 ▼
deploy job
 │
 ▼
current environment
~~~

A release entry is:

~~~yaml
sample-java-app:
  version: 1.2.14
  image: sha256:<digest>
~~~

That pair is the CI-to-CD contract.

## 7. Deploy pipeline

~~~text
state/<env>.yaml
       │
       ▼
promotion check
       │
       ▼
signature check
       │
       ▼
chart render
       │
       ▼
server dry-run
       │
       ▼
deploy.sh
       │
       ▼
helm upgrade --wait
       │
       ▼
helm test
       │
   ┌───┴────┐
   │        │
 pass      fail
   │        │
   ▼        ▼
tag env   rollback
~~~

The deploy identity is supplied by the current environment and is scoped
to that application namespace.

## 8. Promotion

~~~text
state/dev.yaml
     │
     ▼
healthy dev tag
     │
     ▼
promotion PR
     │
     ▼
state/stage.yaml
     │
     ▼
healthy stage tag
     │
     ▼
promotion PR
     │
     ▼
state/prod.yaml
~~~

Promotion copies the same version and digest.

The deploy pipeline checks Git history so a release cannot jump directly
into a later environment.

## 9. Production canary

~~~text
prod desired release
       │
       ▼
<service>-canary
1 replica
       │
       ▼
ingress canary weight
       │
       ▼
Prometheus 5xx rate
       │
   ┌───┴────────┐
   │            │
 good          bad
   │            │
   ▼            ▼
stable        remove
upgrade       canary
   │          stable stays
   ▼
remove canary
~~~

The current production policy comes from
[`environments.yaml`](../environments.yaml).

## 10. Environment model

~~~text
clusterEnvironment
       │
       ▼
one cluster
       │
       ▼
one environment namespace
       │
       ▼
one state/<env>.yaml
~~~

The lab cluster currently runs `dev`.

~~~text
dev
 │
 ▼
stage
 │
 ▼
prod
~~~

The three state files model promotion order; they are not three
application namespaces simultaneously deployed by this one lab cluster.

## 11. Onboarding a service

~~~text
1. service chart
       │
       ▼
2. tiny Jenkinsfile
       │
       ▼
3. Jenkins service entry
       │
       ▼
4. state entry in every env
       │
       ▼
5. optional Jenkins release entry
~~~

Service Jenkinsfile:

~~~groovy
@Library('lab-delivery') _
servicePipeline(
  chart: 'app/chart',
  context: 'app',
  path: 'app/'
)
~~~

A normal application also inherits the shared
[service chart](../charts/service/README.md).

If Jenkins owns runtime deployment, add the service under `releases`
in [`environments.yaml`](../environments.yaml).

If it is operator-owned, leave it out; CI still builds and records it.

## 12. Identity boundary

~~~text
jenkins-ci
    │
    ▼
server dry-run
real writes denied


jenkins-deploy-<env>
    │
    ▼
apps-<env>
no Secret read
~~~

No cluster kubeconfig is stored in Jenkins.

## 13. Rollback

Runtime failure:

~~~text
Helm deploy/test failure
        │
        ▼
restore previous
runtime revision
~~~

Desired-state rollback:

~~~text
known healthy env tag
        │
        ▼
restore state/<env>.yaml
        │
        ▼
normal PR path
        │
        ▼
deploy job converges
~~~

Runtime rollback and Git desired state are separate concerns.

## 14. Operating rules

~~~text
change service release
        │
        ▼
state/<env>.yaml


change pipeline behavior
        │
        ▼
delivery/pipeline/


change CI agent tools
        │
        ▼
delivery/jenkins/


change platform / infra
        │
        ▼
operator make targets
NOT Jenkins deployment
~~~

The top-level release model is documented in
**[DELIVERY.md](../DELIVERY.md)**.
