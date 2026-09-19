#!/usr/bin/env bash
set -Eeuo pipefail

readonly CONTROL_PLANE=node-1
readonly API_ADDRESS=10.50.0.10
readonly API_PORT=6443
readonly LOCAL_API_PORT=16443

fail() {
  printf 'FAIL | %s\n' "$1" >&2
  exit 1
}

cleanup() {
  if [[ -S "${control_socket:-}" ]]; then
    ssh -S "${control_socket}" -O exit "${CONTROL_PLANE}" >/dev/null 2>&1 || true
  fi
  rm -rf -- "${temporary:-}"
}

readonly runtime_directory="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
mkdir -p -- "${runtime_directory}"
chmod 0700 "${runtime_directory}"

write_ssh_config() {
  vagrant ssh-config "${CONTROL_PLANE}" |
    sed -n '/^Host /,$p' > "${ssh_config}"
  [[ -s "${ssh_config}" ]] || fail 'Vagrant did not return control-plane SSH configuration'
}

write_kubeconfig() {
  ssh -F "${ssh_config}" "${CONTROL_PLANE}" \
    sudo -n cat /etc/kubernetes/admin.conf > "${kubeconfig}"
  [[ -s "${kubeconfig}" ]] || fail 'Control-plane kubeconfig is unavailable'
}

open_api_tunnel() {
  exec {tunnel_lock}>"${runtime_directory}/lab-kube-api.lock"
  flock "${tunnel_lock}"
  ssh -F "${ssh_config}" -M -S "${control_socket}" -fNT \
    -o BatchMode=yes -o ExitOnForwardFailure=yes \
    -o ServerAliveInterval=15 -o ServerAliveCountMax=3 \
    -L "127.0.0.1:${LOCAL_API_PORT}:${API_ADDRESS}:${API_PORT}" "${CONTROL_PLANE}"
  ssh -F "${ssh_config}" -S "${control_socket}" -O check "${CONTROL_PLANE}" >/dev/null 2>&1
}

point_kubeconfig_at_tunnel() {
  local cluster
  cluster="$(KUBECONFIG="${kubeconfig}" kubectl config view --minify -o jsonpath='{.clusters[0].name}')"
  [[ -n "${cluster}" ]] || fail 'Kubeconfig does not contain a current cluster'
  KUBECONFIG="${kubeconfig}" kubectl config set-cluster "${cluster}" \
    --server="https://127.0.0.1:${local_port}" \
    --tls-server-name="${API_ADDRESS}" >/dev/null
}

[[ "$#" -gt 0 ]] || fail 'with-kubeconfig requires a command'
temporary="$(mktemp -d)"
readonly temporary
readonly ssh_config="${temporary}/ssh-config"
readonly kubeconfig="${temporary}/kubeconfig"
readonly control_socket="${temporary}/ssh-control"
readonly local_port="${LOCAL_API_PORT}"
trap cleanup EXIT

write_ssh_config
write_kubeconfig
open_api_tunnel
point_kubeconfig_at_tunnel
KUBECONFIG="${kubeconfig}" kubectl version --request-timeout=10s >/dev/null ||
  fail 'Kubernetes API tunnel opened but the API server is unreachable'
KUBECONFIG="${kubeconfig}" "$@"
