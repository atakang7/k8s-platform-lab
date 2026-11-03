Part of [k8s-platform-lab](../README.md)

# Test VM

A libvirt VM runs the full lab through nested VirtualBox and records a reusable snapshot.

## Run

```sh
make test-vm
make test-vm-ssh
make test-vm-snapshot
```

Use `make test-vm-restore` to restore `ready` and `make test-vm-destroy` to remove the VM.

## Config

| Setting | Default | Use |
| --- | --- | --- |
| VM address | `192.168.150.10` | SSH |
| RAM | `13312` MiB | Nested cluster |
| Virtual disk | `70` GiB | VM storage |
| SSH key | `~/.ssh/id_ed25519.pub` | VM access |

## Interfaces

| Path | Purpose |
| --- | --- |
| [bin/up](bin/up) | Download image and boot VM |
| [bin/runbook](bin/runbook) | Run the cluster setup |
| [bin/browser](bin/browser) | Firefox via SSH SOCKS proxy |
| [vm/network.xml](vm/network.xml) | libvirt network |

Install KVM, libvirt, virt-install and rsync first. Nested virtualization must be enabled on the host.
