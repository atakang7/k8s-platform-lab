# Weaknesses

Known gaps we accept in the lab.

## Vault and BIND are not monitored

Both run on the host, outside the cluster, and Prometheus doesn't scrape them.
They are only checked when `make edge-smoke` or `make edge-validate` runs. If
Vault seals itself, Secrets stop syncing and nobody is alerted.

Next step: scrape Vault's metrics and a BIND exporter, and alert on "Vault
sealed" and "BIND down".

## Workers use Vagrant's shared SSH key

`insert_key = false` keeps Vagrant's default key, which every Vagrant install
has. SSH is closed on the edge network (`roles/edge_firewall`), so it is only
reachable through Vagrant's port forward on the operator machine.

Next step: `insert_key = true`, so each node gets its own key.
