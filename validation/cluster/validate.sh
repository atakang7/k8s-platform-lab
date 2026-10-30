#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly ROOT
readonly VAGRANT_INVENTORY="${ROOT}/.vagrant/provisioners/ansible/inventory/vagrant_ansible_inventory"

TEMPORARY_DIRECTORY=''

fail() {
  printf 'FAIL | %s\n' "$1" >&2
  exit 1
}

cleanup() {
  if [[ -n "${TEMPORARY_DIRECTORY}" ]]; then
    rm -rf -- "${TEMPORARY_DIRECTORY}"
  fi
}

prepare_validation_files() {
  [[ -f "${VAGRANT_INVENTORY}" ]] ||
    fail 'Vagrant inventory is missing; run vagrant up from the repository root first'

  TEMPORARY_DIRECTORY="$(mktemp -d)"
  trap cleanup EXIT

  # Vagrant's generated Ansible inventory can retain only one SSH key. Its
  # live SSH config contains every current key and forwarded SSH port.
  (
    cd "${ROOT}"
    vagrant ssh-config
  ) | sed -n '/^Host /,$p' > "${TEMPORARY_DIRECTORY}/ssh-config"

  [[ -s "${TEMPORARY_DIRECTORY}/ssh-config" ]] ||
    fail 'Vagrant returned an empty SSH configuration'

  # Let OpenSSH resolve host/port/key details from the live config instead of
  # using stale ansible_host values retained in Vagrant's generated inventory.
  sed -E '/^node-[123] ansible_host=/s/ .*$//' "${VAGRANT_INVENTORY}" \
    > "${TEMPORARY_DIRECTORY}/inventory"

  [[ -s "${TEMPORARY_DIRECTORY}/inventory" ]] ||
    fail 'derived Ansible inventory is empty'
}

run_foundation_validation() {
  export ANSIBLE_CONFIG="${ROOT}/infra/ansible/ansible.cfg"

  ansible-playbook \
    --inventory "${TEMPORARY_DIRECTORY}/inventory" \
    --extra-vars \
      "{\"ansible_ssh_common_args\":\"-F ${TEMPORARY_DIRECTORY}/ssh-config\"}" \
    "${ROOT}/infra/ansible/validate.yml"
}

main() {
  [[ "$#" -eq 0 ]] || fail 'cluster validation does not accept arguments'

  prepare_validation_files
  run_foundation_validation
}

main "$@"
