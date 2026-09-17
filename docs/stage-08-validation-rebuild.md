# Stage 8 — Validation and clean rebuild

This stage proves that the repository, documented operator inputs, and documented commands are sufficient to recreate the platform without preserving manual cluster state.

## Validation model

Validation is layered. A later check is meaningful only if the layer below it is healthy.

```text
┌────────────────────────────────────┐
│ clean repository checkout          │
└────────────────┬───────────────────┘
                 ▼
┌────────────────────────────────────┐
│ VM + Kubernetes foundation         │
│ make cluster-validate              │
└────────────────┬───────────────────┘
                 ▼
┌────────────────────────────────────┐
│ edge + trust                       │
│ make edge-smoke / edge-validate    │
└────────────────┬───────────────────┘
                 ▼
┌────────────────────────────────────┐
│ Jenkins + observability            │
│ endpoints / workloads / logs       │
└────────────────┬───────────────────┘
                 ▼
┌────────────────────────────────────┐
│ application runtime                │
│ 4 replicas · spread · HTTPS        │
└────────────────┬───────────────────┘
                 ▼
┌────────────────────────────────────┐
│ delivery                           │
│ commit → digest → live digest      │
└────────────────┬───────────────────┘
                 ▼
┌────────────────────────────────────┐
│ admission policy                   │
│ valid allow · invalid deny         │
└────────────────┬───────────────────┘
                 ▼
┌────────────────────────────────────┐
│ clean-room rebuild accepted        │
└────────────────────────────────────┘
```

A command exiting zero is useful only when it verifies an externally visible contract. Validation should prefer API state, DNS/TLS results, HTTP behavior, rollout state, artifact identity, and admission decisions over checking that a setup script happened to run.

## Existing validators

| Layer | Command / path | Contract |
|---|---|---|
| cluster | `make cluster-validate` | nodes, networking, Service path, storage |
| container | `make container-validate` | build, runtime response/logging, non-root image contract |
| edge smoke | `make edge-smoke` | normal edge health |
| edge deep validation | `make edge-validate` | DNS, TLS, security boundaries, integration |
| observability | `make observability-smoke` | stack health, endpoints, log delivery |
| CI/CD | Jenkins `lab-build` → `lab-deploy` | immutable artifact and rollout identity |
| policy | server-side dry-run cases | allow/deny behavior |

`validation/e2e/` is the correct location for a composite final validator. It should orchestrate existing checks rather than duplicate their implementation.

## Clean-room proof

The working cluster is not proof of reproducibility. The proof is successful reconstruction after state is removed.

```text
                CURRENT HEALTHY ENVIRONMENT
                           │
                           │ finish Git + docs first
                           ▼
                ┌──────────────────────┐
                │ record prerequisites │
                │ protect operator     │
                │ secrets              │
                └──────────┬───────────┘
                           │
                           ▼
                ┌──────────────────────┐
                │ make destroy         │
                │ remove VM state      │
                └──────────┬───────────┘
                           │
                           ▼
                ┌──────────────────────┐
                │ fresh Git checkout   │
                └──────────┬───────────┘
                           │
                           ▼
                ┌──────────────────────┐
                │ documented bootstrap │
                │ only                 │
                └──────────┬───────────┘
                           │
                           ▼
                ┌──────────────────────┐
                │ load operator-held   │
                │ secrets at defined   │
                │ boundaries           │
                └──────────┬───────────┘
                           │
                           ▼
                ┌──────────────────────┐
                │ run all validation   │
                │ contracts            │
                └──────────┬───────────┘
                           │
                      pass │ fail
                     ┌─────┴─────┐
                     ▼           ▼
                reproducible   fix Git/docs,
                               not the cluster
```

If the rebuild requires an undocumented `kubectl edit`, copied secret, manual Helm tweak, package install, or node repair, the repository is not yet reproducible. Capture the missing state in code or documentation and repeat the rebuild.

## Operator-held inputs

Reproducible does not mean secret-free. The operator must still provide root-of-trust material and external account credentials at documented boundaries.

Expected external inputs include:

| Input | Reason |
|---|---|
| Vault initialization/unseal material | Vault trust root; generated outside Git |
| GitHub credential | private SCM checkout/status access |
| Docker Hub credential | private image push/pull |
| local host privileges | host CA, BIND, Vault, resolver configuration |

Secret values must never be added to Git to make bootstrap easier.

## Rebuild acceptance

A clean rebuild is accepted when all of the following are true:

```text
3 Kubernetes nodes Ready
        │
        ├── DNS resolves *.lab.test
        ├── host trusts HTTPS certificate
        ├── ingress VIP is 192.168.56.200
        ├── Jenkins reachable; jobs from JCasC
        ├── observability endpoints reachable
        ├── application has 4 ready replicas across workers
        ├── application HTTPS request returns expected value
        ├── application logs arrive in Elasticsearch
        ├── CI publishes immutable digest + SBOM
        ├── CD deploys and confirms that digest
        └── admission webhook accepts valid and rejects invalid Deployments
```

The Stage 7 capacity/canary manifests are design references and are not required to be installed for the baseline rebuild.

## Failure handling

During a clean rebuild, fix the first failed dependency. Do not patch a later layer around a broken earlier layer. For example, if DNS is wrong, do not hard-code `/etc/hosts` to make the application test pass; repair the Stage 2 source of truth.

## Source paths

`validation/` owns executable outcome checks. Root `Makefile` exposes stable validation entry points. `docs/operations.md` owns the bootstrap/recovery procedure. This document owns the final reproducibility acceptance model.