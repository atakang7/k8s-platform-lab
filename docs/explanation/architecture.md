# Architecture

Vagrant provisions a three-node Ubuntu cluster. Ansible installs kubeadm, containerd, Calico and local-path storage. The control plane uses the private VM network; workers also attach to the host-facing edge subnet.

Vault, BIND9 and the local CA run on the host. Vault Secrets Operator copies selected credentials into Kubernetes. ExternalDNS updates the BIND zone with TSIG, and ingress-nginx terminates HTTPS at the MetalLB address.

Jenkins uses separate service accounts for validation and deployment. CI has dry-run access to the Kubernetes API. Deployment identities are limited to their environment namespace.

Images are scanned and signed by digest before Git records their release identity. Promotion copies the version and digest between environment state files. The active cluster deploys only its configured environment.

Prometheus receives application and cluster metrics. Application logs reach Elasticsearch through the Fluent Bit sidecar; node logs use Fluent Bit DaemonSets.

The local VM network and local-path persistence keep the setup small. There is no cross-node disk failover. Host Vault and DNS are also outside cluster monitoring.
