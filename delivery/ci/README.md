# CI helpers

`delivery/ci/` contains the small executable steps used by `Jenkinsfile.build`.

```text
checkout
   │
   ├──► test.sh
   ├──► Dockerfile lint
   ├──► Kubernetes server dry-run
   └──► Ansible syntax
            │
            ▼
      build-image.sh
            │ local image archive
            ▼
       scan-image.sh
            │ Trivy + CycloneDX SBOM
            ▼
      publish-image.sh
            │
            ▼
 repository@sha256:<digest>
```

## Contracts

| File | Contract |
|---|---|
| `test.sh` | application tests must pass |
| `lint.sh` | static repository/config checks |
| `build-image.sh` | BuildKit produces the local image artifact |
| `scan-image.sh` | scans before publish and writes `sbom.json` |
| `publish-image.sh` | pushes and records the immutable digest |
| `github-status.sh` | updates commit status contexts |
| `benchmark-build-cache.sh` | build-cache measurement only |

Trivy scans HIGH/CRITICAL findings but is report-only by default because `TRIVY_EXIT_CODE` defaults to `0`.

These scripts are pipeline building blocks. They should remain non-interactive and fail clearly when their input contract is missing.