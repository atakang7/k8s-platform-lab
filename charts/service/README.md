# Service base chart

`charts/service/` is the reusable library chart for stateless HTTP
services. Applications inherit it instead of copying platform boilerplate.

## 1. Composition model

~~~text
application chart
      │
      │ depends on
      ▼
┌──────────────────────┐
│ charts/service       │
│ library chart        │
└──────────┬───────────┘
           │
           ▼
service.manifests
           │
     ┌─────┼──────────────┐
     │     │              │
     ▼     ▼              ▼
Deployment Service      Helm test
     │
     ├── optional Ingress
     ├── optional ServiceMonitor
     ├── optional ConfigMaps
     └── optional PDB
~~~

Consumer template:

~~~yaml
{{ include "service.manifests" . }}
~~~

Consumer dependency:

~~~yaml
dependencies:
  - name: service
    version: 1.2.0
    repository: oci://registry-1.docker.io/atakangul
~~~

## 2. Value ownership

~~~text
library defaults
templates/_defaults.tpl
        │
        ▼
application values.yaml
        │
        ▼
environment overrides
values-<env>.yaml
        │
        ▼
delivery injects
image.digest
        │
        ▼
rendered runtime
~~~

`image.repository` is application-owned.

`image.digest` is delivery-owned and must be an immutable
`sha256:<64 hex>` value.

## 3. Secure runtime defaults

~~~text
Pod
 │
 ├── non-root
 ├── no privilege escalation
 ├── drop ALL capabilities
 ├── RuntimeDefault seccomp
 ├── service-account token OFF
 ├── service links OFF
 └── termination grace 30s
~~~

Delivery namespaces enforce the restricted Pod Security standard. Any
application override must remain compliant.

## 4. Scheduling defaults

~~~text
replicas
   │
   ▼
topology spread
   │
   ▼
worker placement
~~~

With `autoscaling.enabled`, a HorizontalPodAutoscaler owns the replica count
(between `minReplicas` and `maxReplicas`, at `targetCPUUtilization`% of the
CPU request) and the Deployment leaves `replicas` unset. It needs
metrics-server, which `make observability-up` installs.

Topology spread is enabled by default.

Applications can add stricter affinity when their runtime needs it.

## 5. Disruption budget

PDB support is opt-in because the correct budget depends on replica
count and available cluster capacity.

~~~yaml
podDisruptionBudget:
  enabled: true
  minAvailable: 2
~~~

~~~text
single replica
      │
      ▼
PDB usually disabled


multiple replicas
      │
      ▼
choose minAvailable
that still permits eviction
~~~

A PDB that makes every Pod non-evictable prevents normal node drain.

## 6. Health contract

~~~text
Pod starts
   │
   ▼
startup probe
   │
   ▼
readiness probe
   │
   ▼
Service traffic
   │
   ▼
liveness probe
~~~

The application supplies the actual probe paths and timing through its
values.

## 7. Service and ingress

~~~text
Pod
 │
 ▼
Service
 │
 ├───────────────┐
 │               │
 ▼               ▼
cluster use    Ingress
                 │
                 ▼
           ingress-nginx
~~~

Ingress is optional and uses the host supplied by the application chart.

## 8. Metrics

~~~text
application metrics endpoint
          │
          ▼
Service
          │
          ▼
ServiceMonitor
          │
          ▼
Prometheus
~~~

ServiceMonitor creation is optional and driven by chart values.

## 9. Release smoke test

Every rendered service can carry a Helm test Pod.

~~~text
deployment complete
       │
       ▼
Helm test Pod
       │
       ▼
Service
       │
       ▼
smokeTest.path
       │
   ┌───┴────┐
   │        │
  2xx      fail
   │        │
   ▼        ▼
 PASS     deploy rollback
~~~

Point `smokeTest.path` at a real service endpoint, not only a generic
health endpoint.

Application-specific Helm test hooks run alongside the base smoke test.

## 10. Canary support

Applications do not choose canary weight directly during normal release.

~~~text
delivery
   │
   ▼
<service>-canary
   │
   ▼
ingress.canaryWeight
   │
   ▼
ingress-nginx canary annotation
   │
   ▼
percentage of same-host traffic
~~~

The stable and canary releases share the same host. ingress-nginx splits
traffic according to the weight supplied by delivery.

## 11. Immutable chart versions

~~~text
chart change
    │
    ▼
version bump required
    │
    ▼
chart-testing
    │
    ▼
merge to main
    │
    ▼
publish only if version absent
~~~

Released chart versions are immutable. Pull requests that change this
library must bump `Chart.yaml` version.

## 12. Main sources

| Concern | Source |
|---|---|
| library metadata | `Chart.yaml` |
| defaults | `templates/_defaults.tpl` |
| rendered objects | `templates/` |
| app consumer example | `../../app/chart/` |
| delivery behavior | `../../DELIVERY.md` |
