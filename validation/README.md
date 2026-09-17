# Validation

`validation/` checks observable outcomes. It does not own platform configuration.

The rule is simple: configuration belongs under `infra/`, `platform/`, `app/`, `delivery/`, or `policies/`; validation only proves that the resulting system behaves as expected.

## Current checks

| Path | Command | Verifies |
|---|---|---|
| `cluster/` | `make cluster-validate` | node health, networking, cross-node Pod traffic, dynamic storage |
| `container/` | `make container-validate` | application tests, runtime image, HTTP behavior, non-root execution, OCI metadata |
| `edge/` | `make edge-smoke` | normal edge health, DNS, HTTPS, Kubernetes workloads |
| `edge/` | `make edge-validate` | deeper DNS/TLS/security integration and create/delete behavior |

`platform/` and `e2e/` are reserved for cross-platform and clean-room validation. They should contain tests that consume the deployed system, not installation logic.

## Validation layers

```text
configuration
    │
    │ reconcile
    │
 running system
    │
    ├─ cluster validation
    ├─ container validation
    ├─ edge validation
    └─ final end-to-end validation
```

A smoke test answers "is the normal path healthy now?". A deeper validation may deliberately create and remove temporary resources to exercise integration boundaries.

## Expected operating order

```bash
make cluster-validate
make edge-smoke
make observability-smoke
```

Application and admission-policy checks should be run after Jenkins has delivered the application and the policy webhook is installed.

For release verification, confirm at minimum:

- three Kubernetes nodes are Ready;
- ingress DNS resolves to `192.168.56.200`;
- HTTPS is trusted for the managed hostnames;
- Jenkins controller is healthy on node-3;
- monitoring and logging endpoints respond;
- `sample-java-app` has four Ready replicas spread across node-2 and node-3;
- the live application responds through `https://app.lab.test`;
- the running application image is an immutable digest from CI/CD;
- the admission webhook accepts complete requests and rejects missing CPU or memory requests.

## Failure handling

Validation scripts should fail on the first broken invariant with enough context to identify the subsystem. Do not make a validator silently repair the system. Repair belongs in the subsystem's reconciliation path, then the validator is rerun.