# Resource request webhook

This webhook rejects Deployment CREATE/UPDATE requests when any regular
or init container omits a non-zero CPU or memory request.

Lifecycle and install: [policies/README.md](../README.md).

## 1. Admission path

~~~text
Deployment
CREATE / UPDATE
      │
      ▼
┌──────────────────────┐
│ Kubernetes API       │
└──────────┬───────────┘
           │ AdmissionReview v1
           │ HTTPS
           ▼
┌──────────────────────┐
│ webhook :8443        │
└──────────┬───────────┘
           │
           ▼
validate request shape
           │
           ▼
inspect containers
           │
           ▼
inspect initContainers
           │
      ┌────┴─────┐
      │          │
      ▼          ▼
CPU + RAM      missing
present        either
      │          │
      ▼          ▼
    ALLOW       DENY
~~~

The handler validates the API resource and operation itself instead of
assuming webhook registration will always route the correct object.

## 2. Validation rule

~~~text
for every regular container
        │
        ├── requests.cpu    > 0
        └── requests.memory > 0

for every init container
        │
        ├── requests.cpu    > 0
        └── requests.memory > 0
~~~

Any missing or zero value rejects the whole Deployment request.

## 3. Namespace scope

~~~text
namespace labels
       │
       ▼
delivery.lab.test/environment
       │
   ┌───┴────┐
   │        │
present   absent
   │        │
   ▼        ▼
apply     ignore
~~~

The policy also excludes its own release namespace and Kubernetes system
namespaces explicitly.

## 4. Fail-closed path

~~~text
API server
   │
   ▼
webhook call
   │
┌──┴──────────┐
│             │
answer      timeout/error
│             │
▼             ▼
decision    reject write
~~~

`failurePolicy: Fail` prevents an unavailable webhook from silently
allowing invalid in-scope Deployments.

## 5. Serving path

~~~text
Kubernetes API
      │ HTTPS :443
      ▼
┌──────────────────────┐
│ ClusterIP Service    │
└──────────┬───────────┘
           │ targetPort 8443
           ▼
┌──────────────────────┐
│ webhook Pod          │
│ HTTPS :8443          │
└──────────────────────┘
~~~

The Service certificate covers the webhook Service DNS names.

## 6. TLS ownership

~~~text
first install
     │
     ▼
private CA
     │
     ▼
Service certificate
     │
     ├──────────────┐
     ▼              ▼
TLS Secret      caBundle
     │              │
     └──────┬───────┘
            ▼
        admission TLS
~~~

Normal upgrades reuse the existing Secret, keeping the serving identity
stable.

## 7. Runtime deployment

~~~text
policy-system
     │
     ▼
webhook Deployment
2 replicas
     │
     ▼
spread across workers
     │
     ▼
PDB minAvailable: 1
~~~

The runtime is non-root, drops Linux capabilities, and is deployed from
an immutable image digest.

## 8. Build path

~~~text
Go source
   │
   ▼
go test ./...
   │
   ▼
builder image
   │
   ▼
static webhook binary
   │
   ▼
distroless non-root image
   │
   ▼
Trivy + publish
   │
   ▼
state/<env>.yaml
~~~

Builder and runtime base images are pinned by digest.

## 9. Helm chart

The chart lives at:

~~~text
helm/resource-requests-webhook/
~~~

It creates:

~~~text
Deployment
    │
Service
    │
TLS Secret
    │
ValidatingWebhookConfiguration
~~~

Manual example after publishing an image:

~~~bash
helm upgrade --install resource-requests-webhook \
  helm/resource-requests-webhook \
  --namespace policy-system \
  --create-namespace \
  --set image.repository=docker.io/atakangul/resource-requests-webhook \
  --set image.digest=sha256:<published-digest>
~~~

Normal repository operation uses `make policies-up` instead.

## 10. Test path

Unit tests:

~~~bash
cd policies/resource-requests-webhook
go test ./...
~~~

Tests cover:

~~~text
regular containers
init containers
wrong resource type
unsupported operation
empty admission object
~~~

## 11. Real API verification

`policies/bin/smoke` uses server-side dry-run.

~~~text
kubectl apply
--dry-run=server
      │
      ▼
Kubernetes API
      │
      ▼
Service + TLS
      │
      ▼
webhook code
      │
      ▼
AdmissionReview response
~~~

The test objects are not persisted, but the real admission path executes.

Expected decisions:

~~~text
regular CPU + memory  ──► accepted
CPU missing           ──► rejected
memory missing        ──► rejected
~~~
