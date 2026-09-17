#!/usr/bin/env bash
set -Eeuo pipefail

repository_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly repository_root
readonly inventory="${repository_root}/.vagrant/provisioners/ansible/inventory/vagrant_ansible_inventory"

if [[ ! -f "${inventory}" ]]; then
  printf 'FAIL | Vagrant inventory is missing; run vagrant up from the repository root first\n' >&2
  exit 1
fi

temporary_directory="$(mktemp -d)"
trap 'rm -rf -- "${temporary_directory}"' EXIT

# Vagrant's generated Ansible inventory can retain only one SSH key. Its live
# SSH config includes every key and the current forwarded ports.
(cd "${repository_root}" && vagrant ssh-config) |
  sed -n '/^Host /,$p' > "${temporary_directory}/ssh_config"
sed -E '/^node-[123] ansible_host=/s/ .*$//' "${inventory}" > "${temporary_directory}/inventory"

export ANSIBLE_CONFIG="${repository_root}/infra/ansible/ansible.cfg"
ansible-playbook \
  --inventory "${temporary_directory}/inventory" \
  --extra-vars "{\"ansible_ssh_common_args\":\"-F ${temporary_directory}/ssh_config\"}" \
  "${repository_root}/infra/ansible/validate.yml"
