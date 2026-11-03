# Known issues and limits

| Area | Observed condition |
| --- | --- |
| Grafana | Reconciliation can restart the Grafana Pod and cause startup OOM kills. |
| Jenkins | Snapshot restore has left plugin copies stalled and agent provisioning counts at the configured cap with zero active agents. |
| Vault and BIND9 | They run on the host and have no Prometheus scrape or alert. |
| Elasticsearch | `xpack.security.enabled=false`; the edge ingress exposes its API. |
| Storage | Local-path volumes have no cross-node storage failover. |
| Runtime | The lab uses one selected environment per cluster. |

The Jenkins plugin-copy and provisioning failures were observed after restoring the test VM snapshot. See [platform/jenkins](../../platform/jenkins/README.md) for its deployment inputs.

The Elasticsearch ingress must stay on a trusted lab network. Anyone with network access to it can read and delete log indices.
