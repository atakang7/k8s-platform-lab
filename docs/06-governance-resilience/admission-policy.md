# Admission policy

The cluster rejects Deployments that omit CPU or memory requests on any regular container.

## Admission flow

```text
kubectl / controller
        │
        │ CREATE or UPDATE Deployment
        ▼
┌────────────────────────────┐
│ Kubernetes API server      │
└─────────────┬──────────────┘
              │ AdmissionReview v1 · HTTPS
              ▼
┌────────────────────────────┐
│ resource-requests-webhook  │
│ policy-system              │
└─────────────┬──────────────┘
              │
      ┌───────┴────────┐
      │                │
      ▼                ▼
all containers     request missing
have CPU + RAM     CPU or memory
      │                │
      ▼                ▼
    allow              deny
      │                │
      └───────┬────────┘
              ▼
       API response returned
```

The API server remains the enforcement point. The webhook only evaluates the object and returns allow/deny.

## Policy

For every regular container in an in-scope `Deployment`:

```text
resources.requests.cpu     must exist and be non-zero
resources.requests.memory  must exist and be non-zero
```

If either value is missing, admission returns:

```text
container "<name>" must specify both CPU and memory requests
```

The policy applies on CREATE and UPDATE, so an already-valid Deployment cannot later be edited into an unrequested state.

## Why a webhook

Kubernetes has native resource controls such as `ResourceQuota`, `LimitRange`, PriorityClass, and CEL-based admission policies. They solve related but different problems.

This implementation uses a custom validating webhook because the required invariant is explicit Deployment-level validation and the platform requirement calls for a custom webhook. The rule is therefore visible as code, unit-tested, and exercised through real API-server admission.

## Failure behavior

`failurePolicy: Fail` is intentional.

```text
API server cannot reach webhook
             │
             ▼
request is rejected
```

For this policy, silently accepting an unvalidated Deployment would be worse than failing the write.

The webhook namespace and Kubernetes system namespaces are excluded so the policy service cannot block its own bootstrap or core control-plane objects.

## TLS

The webhook listens on HTTPS `8443`. The Helm chart creates serving certificate material for the Service DNS names and places the matching CA bundle into the `ValidatingWebhookConfiguration`.

```text
API server
   │ validates webhook certificate using caBundle
   ▼
resource-requests-webhook.policy-system.svc:443
   │
   ▼
Pod :8443
```

The runtime image is a static Go binary on a distroless non-root base.

## Validation strategy

Admission is tested with `kubectl apply --dry-run=server`.

```text
valid Deployment        → accepted
CPU missing             → rejected
memory missing          → rejected
existing app manifest   → accepted
```

Server dry-run is important: it exercises the actual API server, TLS path, webhook Service, and policy code without leaving temporary Deployments in the cluster.

## Responsibility boundary

This webhook enforces one invariant only. It does not:

- reserve capacity;
- set default requests;
- enforce namespace quotas;
- autoscale workloads;
- choose which Pod wins scheduling contention.

Those behaviors stay with the Kubernetes primitives designed for them.

## Source paths

- [`policies/resource-requests-webhook/cmd/webhook/`](../../policies/resource-requests-webhook/cmd/webhook/) — admission server and tests.
- [`policies/resource-requests-webhook/Dockerfile`](../../policies/resource-requests-webhook/Dockerfile) — static non-root runtime image.
- [`policies/resource-requests-webhook/helm/resource-requests-webhook/`](../../policies/resource-requests-webhook/helm/resource-requests-webhook/) — Service, Deployment, TLS, and ValidatingWebhookConfiguration.
