# Known limits

- Control plane: one `node-1` VM; there is no failover.
- Vault and BIND9: host services are not scraped by Prometheus; a sealed Vault stops secret refresh without an alert.
- Elasticsearch: `/elasticsearch/` is reachable on the lab edge with `xpack.security.enabled=false`, allowing log reads and deletion.
- Production canary: a zero-traffic sample warns and continues instead of blocking promotion.
- Environments: `stage` and `prod` are promotion state in Git, not separate clusters provisioned here.

## Verify

```bash
make edge-smoke
make observability-smoke
```

Check [DELIVERY.md](../DELIVERY.md) for canary settings and [environments.yaml](../environments.yaml) for the selected cluster environment.
