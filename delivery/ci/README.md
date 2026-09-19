# CI helpers

`delivery/ci/` contains the executable steps used by `Jenkinsfile.build` and `Jenkinsfile.deploy`.

```text
checkout
   │
   ├──► Dockerfile lint
   └──► Helm lint + chart server dry-run
            │
            ▼
      build-image.sh
      BuildKit · single build + unit tests
            │
            ▼
       app-image/ (OCI layout)
            │
            ▼
       scan-image.sh
       Trivy + CycloneDX SBOM
            │
            ▼
      publish-image.sh
      skopeo push of app-image/, unchanged
      pushed digest == scanned digest, or fail
            │
            ▼
 repository@sha256:<digest>
```

The image is built once. `publish-image.sh` pushes the scanned OCI layout unchanged and fails unless the registry digest equals the scanned manifest digest.

## Contracts

| File | Contract |
|---|---|
| `build-image.sh` | BuildKit runs the unit tests and builds the image once into `app-image/` |
| `scan-image.sh` | scans before publish and writes `sbom.json` |
| `publish-image.sh` | pushes the scanned `app-image/` unchanged, verifies digest equality, records the immutable reference |
| `github-status.sh` | updates commit status contexts |
| `route.sh` | change router: prints the CI flows for a commit range; see [Change router](../README.md#change-router) |
| `check-shell-syntax.sh` | `bash -n` on every shell script under the given paths; fails if none found |
| `deploy.sh` | CD: releases `IMAGE_REF` with `app/chart` through Helm; waits, rolls back on failure |

Trivy scans HIGH/CRITICAL findings but is report-only by default because `TRIVY_EXIT_CODE` defaults to `0`.

These scripts are pipeline building blocks. They remain non-interactive and fail clearly when their input contract is missing.
