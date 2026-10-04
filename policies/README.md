# Policies

`policies/` owns admission controls that reject invalid Kubernetes
desired state before it is persisted.

## 1. Admission boundary

~~~text
Deployment CREATE / UPDATE
           │
           ▼
┌──────────────────────┐
│ Kubernetes API       │
└──────────┬───────────┘
           │ AdmissionReview v1
           ▼
┌──────────────────────┐
│ resource-request     │
│ validating webhook   │
└──────────┬───────────┘
           │
      ┌────┴─────┐
      │          │
      ▼          ▼
all requests   missing CPU
present        or memory
      │          │
      ▼          ▼
    ALLOW       DENY
~~~

The webhook checks both regular containers and init containers.

## 2. Scope

~~~text
namespace
   │
   ▼
delivery.lab.test/environment
   │
   ├── present ──► policy applies
   │
   └── absent  ──► policy ignored
~~~

The webhook also excludes its own release namespace and Kubernetes
system namespaces by name.

~~~text
policy-system       excluded
kube-system         excluded
other system ns     excluded
apps-<env>          in scope
~~~

This prevents an accidental environment label from deadlocking the
webhook itself or core cluster components.

## 3. Fail-closed behavior

~~~text
in-scope Deployment
        │
        ▼
API calls webhook
        │
    ┌───┴────────┐
    │            │
 response      no response
    │            │
    ▼            ▼
allow/deny    FAIL CLOSED
~~~

`failurePolicy: Fail` means the API rejects in-scope writes when the
webhook cannot answer.

## 4. Build and release

~~~text
webhook source
     │
     ▼
go test ./...
     │
     ▼
BuildKit
     │
     ▼
Trivy
     │
     ▼
publish immutable image
     │
     ▼
state/<env>.yaml
     │
     ▼
operator installs digest
~~~

Delivery builds, scans, publishes, and records the webhook like a
service.

It is not listed under Jenkins-managed `releases`, so deployment is
operator-owned:

~~~bash
make policies-up
~~~

The operator reads the digest for this cluster's
`clusterEnvironment`.

## 5. Serving TLS

~~~text
first install
     │
     ▼
generate private CA
     │
     ▼
generate Service cert
     │
     ├──────────────┐
     ▼              ▼
TLS Secret      webhook caBundle
     │              │
     └──────┬───────┘
            ▼
       HTTPS admission
~~~

On normal upgrades:

~~~text
existing TLS Secret
        │
        ▼
reuse serving identity
        │
        ▼
stable caBundle
~~~

Deleting the TLS Secret intentionally causes the next reconciliation to
generate a new serving identity.

## 6. Runtime shape

~~~text
policy-system
     │
     ▼
┌──────────────────────┐
│ webhook Deployment   │
│ 2 replicas           │
└──────────┬───────────┘
           │
           ▼
┌──────────────────────┐
│ ClusterIP Service    │
│ 443 → 8443 HTTPS     │
└──────────┬───────────┘
           │
           ▼
ValidatingWebhookConfiguration
~~~

The replicas are spread across workers and protected by a disruption
budget.

The runtime image is deployed by immutable digest.

## 7. Smoke validation

~~~text
make policies-smoke
        │
        ▼
rollout ready
        │
        ▼
failurePolicy: Fail
        │
        ▼
real server dry-runs
~~~

Admission behavior is tested through the real Kubernetes API:

~~~text
CPU + memory       ──► accepted
CPU missing        ──► rejected
memory missing     ──► rejected
~~~

## 8. Commands

Unit tests:

~~~bash
cd policies/resource-requests-webhook
go test ./...
~~~

Install and verify:

~~~bash
make policies-up
make policies-smoke
~~~

## 9. Responsibility boundary

This webhook enforces one invariant only:

~~~text
Deployment container
resources.requests.cpu
resources.requests.memory
        │
        ▼
must both be non-zero
~~~

It does not replace ResourceQuota, LimitRange, PriorityClass, PDBs, or
autoscaling.

Implementation detail continues in
**[resource-requests-webhook/README.md](resource-requests-webhook/README.md)**.
