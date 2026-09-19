# CI helpers

`delivery/ci/` contains the executable steps used by `Jenkinsfile.build` and `Jenkinsfile.deploy`.

```text
checkout
   │
   ├──► test.sh
   ├──► Dockerfile lint
   └──► Helm lint + chart server dry-run
            │
            ▼
      build-image.sh
      BuildKit solve #1
            │
            ▼
       app-image.tar
            │
            ▼
       scan-image.sh
       Trivy + CycloneDX SBOM
            │
            ▼
      publish-image.sh
      BuildKit solve #2 · warm cache
            │
            ▼
       registry push
            │
            ▼
 repository@sha256:<digest>
```

The local tar is scan input only. `publish-image.sh` performs a second BuildKit solve against the same source/context and captures the registry digest.

## Contracts

| File | Contract |
|---|---|
| `test.sh` | application tests must pass |
| `build-image.sh` | BuildKit exports the local scan candidate |
| `scan-image.sh` | scans before publish and writes `sbom.json` |
| `publish-image.sh` | rebuilds from warm cache, pushes, records immutable digest |
| `github-status.sh` | updates commit status contexts |
| `route.sh` | change router: prints the CI flows for a commit range; see [Change router](../README.md#change-router) |
| `check-shell-syntax.sh` | `bash -n` on every shell script under the given paths; fails if none found |
| `deploy.sh` | CD: releases `IMAGE_REF` with `app/chart` through Helm; waits, rolls back on failure |

Trivy scans HIGH/CRITICAL findings but is report-only by default because `TRIVY_EXIT_CODE` defaults to `0`.

These scripts are pipeline building blocks. They remain non-interactive and fail clearly when their input contract is missing.
