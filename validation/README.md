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
| `e2e/` | `make e2e-validate` | installed platform, application metrics/logs, and admission policy |

Validation consumes the deployed system. Installation logic stays in the owning subsystem.

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

A smoke test answers "is the normal path healthy now?". A deeper validation may deliberately create and remove temporary resources to exercise integration boundaries. Those resources are cleaned before and after the check so an interrupted previous run cannot satisfy a later validation.

## Expected operating order

```bash
make cluster-validate
make edge-smoke
make observability-smoke
make e2e-validate
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
- the application Pod runtime keeps service-account tokens and service links disabled, uses the RuntimeDefault seccomp profile, and enforces the two-replica disruption budget;
- the admission webhook accepts complete requests and rejects missing CPU or memory requests.

## Failure handling

Validation scripts should fail on the first broken invariant with enough context to identify the subsystem. They may clean up only resources that the validation itself owns; they must not repair platform state. Repair belongs in the owning subsystem's reconciliation path, then the validator is rerun.

Keep validation data flow explicit. Values that connect checks—such as an end-to-end request ID—are created by the orchestrator and passed as arguments instead of being smuggled through stdout or mutable ambient state.
