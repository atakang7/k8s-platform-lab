# Run platform checks

Run these commands from the repository root after [bootstrap](bootstrap.md).

## Quick checks

```sh
make cluster-validate
make edge-smoke
make observability-smoke
make policies-smoke
```

## Full checks

```sh
make edge-validate
make container-validate
make e2e-validate
```

`container-validate` uses the host Docker daemon. `e2e-validate` verifies the image digest in Git, an HTTPS app request, its Elasticsearch log and the Prometheus scrape.

For an isolated run, use the [test VM](../../test/README.md).
