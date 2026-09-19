#!/usr/bin/env bash
set -Eeuo pipefail

readonly CONTROL_PLANE=node-1
readonly LOCAL_API_PORT="${LAB_LOCAL_API_PORT:-16443}"
RUNTIME_DIRECTORY="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
readonly RUNTIME_DIRECTORY

TEMPORARY_DIRECTORY=''
SSH_CONFIG=''
KUBECONFIG_FILE=''
CONTROL_SOCKET=''
API_ADDRESS=''
API_PORT=''
TUNNEL_LOCK_FD=''

fail() {
  printf 'FAIL | %s\n' "$1" >&2
  exit 1
}

cleanup() {
  if [[ -n "${CONTROL_SOCKET}" && -S "${CONTROL_SOCKET}" ]]; then
    ssh -F "${SSH_CONFIG}" \
      -S "${CONTROL_SOCKET}" \
      -O exit \
      "${CONTROL_PLANE}" >/dev/null 2>&1 || true
  fi

  if [[ -n "${TEMPORARY_DIRECTORY}" ]]; then
    rm -rf -- "${TEMPORARY_DIRECTORY}"
  fi
}

prepare_runtime_directory() {
  mkdir -p -- "${RUNTIME_DIRECTORY}"
  chmod 0700 "${RUNTIME_DIRECTORY}"
}

prepare_temporary_files() {
  TEMPORARY_DIRECTORY="$(mktemp -d)"
  SSH_CONFIG="${TEMPORARY_DIRECTORY}/ssh-config"
  KUBECONFIG_FILE="${TEMPORARY_DIRECTORY}/kubeconfig"
  CONTROL_SOCKET="${TEMPORARY_DIRECTORY}/ssh-control"
}

write_ssh_config() {
  vagrant ssh-config "${CONTROL_PLANE}" |
    sed -n '/^Host /,$p' > "${SSH_CONFIG}"

  [[ -s "${SSH_CONFIG}" ]] ||
    fail 'Vagrant did not return control-plane SSH configuration'
}

copy_control_plane_kubeconfig() {
  ssh -F "${SSH_CONFIG}" "${CONTROL_PLANE}" \
    sudo -n cat /etc/kubernetes/admin.conf > "${KUBECONFIG_FILE}"

  [[ -s "${KUBECONFIG_FILE}" ]] ||
    fail 'control-plane kubeconfig is unavailable'
}

read_api_endpoint() {
  local server

  server="$(KUBECONFIG="${KUBECONFIG_FILE}" kubectl config view \
    --minify -o jsonpath='{.clusters[0].cluster.server}')"

  [[ "${server}" =~ ^https://([^:/]+):([0-9]+)$ ]] ||
    fail "unsupported Kubernetes API endpoint: ${server}"

  API_ADDRESS="${BASH_REMATCH[1]}"
  API_PORT="${BASH_REMATCH[2]}"
}

open_api_tunnel() {
  exec {TUNNEL_LOCK_FD}>"${RUNTIME_DIRECTORY}/lab-kube-api.lock"
  flock "${TUNNEL_LOCK_FD}"

  ssh -F "${SSH_CONFIG}" \
    -M \
    -S "${CONTROL_SOCKET}" \
    -fNT \
    -o BatchMode=yes \
    -o ExitOnForwardFailure=yes \
    -o ServerAliveInterval=15 \
    -o ServerAliveCountMax=3 \
    -L "127.0.0.1:${LOCAL_API_PORT}:${API_ADDRESS}:${API_PORT}" \
    "${CONTROL_PLANE}"

  ssh -F "${SSH_CONFIG}" \
    -S "${CONTROL_SOCKET}" \
    -O check \
    "${CONTROL_PLANE}" >/dev/null 2>&1 ||
    fail 'Kubernetes API SSH tunnel did not stay open'
}

point_kubeconfig_at_tunnel() {
  local cluster_name

  cluster_name="$(KUBECONFIG="${KUBECONFIG_FILE}" kubectl config view \
    --minify -o jsonpath='{.clusters[0].name}')"

  [[ -n "${cluster_name}" ]] ||
    fail 'kubeconfig does not contain a current cluster'

  KUBECONFIG="${KUBECONFIG_FILE}" kubectl config set-cluster "${cluster_name}" \
    --server="https://127.0.0.1:${LOCAL_API_PORT}" \
    --tls-server-name="${API_ADDRESS}" >/dev/null
}

verify_api_connection() {
  KUBECONFIG="${KUBECONFIG_FILE}" \
    kubectl version --request-timeout=10s >/dev/null ||
    fail 'Kubernetes API tunnel is open but the API server is unreachable'
}

run_with_temporary_kubeconfig() {
  KUBECONFIG="${KUBECONFIG_FILE}" "$@"
}

main() {
  [[ "$#" -gt 0 ]] ||
    fail 'with-kubeconfig requires a command'

  prepare_runtime_directory
  prepare_temporary_files
  trap cleanup EXIT

  write_ssh_config
  copy_control_plane_kubeconfig
  read_api_endpoint
  open_api_tunnel
  point_kubeconfig_at_tunnel
  verify_api_connection
  run_with_temporary_kubeconfig "$@"
}

main "$@"
