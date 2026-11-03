# Weaknesses

Known gaps we accept in the lab.

## Vault and BIND are not monitored

Both run on the host, outside the cluster, and Prometheus doesn't scrape them.
They are only checked when `make edge-smoke` or `make edge-validate` runs. If
Vault seals itself, Secrets stop syncing and nobody is alerted.

Next step: scrape Vault's metrics and a BIND exporter, and alert on "Vault
sealed" and "BIND down".

## Elasticsearch has no authentication

It runs with `xpack.security.enabled=false` and is served at
`/elasticsearch/` on the edge network. Anyone who can reach the ingress can
read and delete every log index.

Next step: keep ECK's built-in security on, give Grafana and Fluent Bit
their own users, and drop the ingress path.
