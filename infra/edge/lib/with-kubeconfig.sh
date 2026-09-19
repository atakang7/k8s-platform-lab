#!/usr/bin/env bash
set -Eeuo pipefail

readonly control_plane=node-1
readonly local_api_port="${LAB_LOCAL_API_PORT:-16443}"
readonly runtime_directory="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"

fail() {
  printf 'FAIL | %s\n' "$1" >&2
  exit 1
}

cleanup() {
  if [[ -n "${control_socket:-}" && -S "${control_socket}" ]]; then
    ssh -F "${ssh_config}" -S "${control_socket}" -O exit "${control_plane}" \
      >/dev/null 2>&1 || true
  fi

  if [[ -n "${temporary:-}" ]]; then
    rm -rf -- "${temporary}"
  fi
}

write_ssh_config() {
  vagrant ssh-config "${control_plane}" |
    sed -n '/^Host /,$p' > "${ssh_config}"

  [[ -s "${ssh_config}" ]] ||
    fail 'Vagrant did not return control-plane SSH configuration'
}

write_kubeconfig() {
  ssh -F "${ssh_config}" "${control_plane}" \
    sudo -n cat /etc/kubernetes/admin.conf > "${kubeconfig}"

  [[ -s "${kubeconfig}" ]] ||
    fail 'control-plane kubeconfig is unavailable'
}

read_api_endpoint() {
  local server

  server="$(KUBECONFIG="${kubeconfig}" kubectl config view \
    --minify -o jsonpath='{.clusters[0].cluster.server}')"

  [[ "${server}" =~ ^https://([^:/]+):([0-9]+)$ ]] ||
    fail "unsupported Kubernetes API endpoint: ${server}"

  api_address="${BASH_REMATCH[1]}"
  api_port="${BASH_REMATCH[2]}"
}

open_api_tunnel() {
  exec {tunnel_lock}>"${runtime_directory}/lab-kube-api.lock"
  flock "${tunnel_lock}"

  ssh -F "${ssh_config}" \
    -M -S "${control_socket}" -fNT \
    -o BatchMode=yes \
    -o ExitOnForwardFailure=yes \
    -o ServerAliveInterval=15 \
    -o ServerAliveCountMax=3 \
    -L "127.0.0.1:${local_api_port}:${api_address}:${api_port}" \
    "${control_plane}"

  ssh -F "${ssh_config}" -S "${control_socket}" -O check "${control_plane}" \
    >/dev/null 2>&1 ||
    fail 'Kubernetes API SSH tunnel did not stay open'
}

point_kubeconfig_at_tunnel() {
  local cluster

  cluster="$(KUBECONFIG="${kubeconfig}" kubectl config view \
    --minify -o jsonpath='{.clusters[0].name}')"
  [[ -n "${cluster}" ]] ||
    fail 'kubeconfig does not contain a current cluster'

  KUBECONFIG="${kubeconfig}" kubectl config set-cluster "${cluster}" \
    --server="https://127.0.0.1:${local_api_port}" \
    --tls-server-name="${api_address}" >/dev/null
}

main() {
  [[ "$#" -gt 0 ]] ||
    fail 'with-kubeconfig requires a command'

  mkdir -p -- "${runtime_directory}"
  chmod 0700 "${runtime_directory}"

  temporary="$(mktemp -d)"
  ssh_config="${temporary}/ssh-config"
  kubeconfig="${temporary}/kubeconfig"
  control_socket="${temporary}/ssh-control"
  trap cleanup EXIT

  write_ssh_config
  write_kubeconfig
  read_api_endpoint
  open_api_tunnel
  point_kubeconfig_at_tunnel

  KUBECONFIG="${kubeconfig}" kubectl version --request-timeout=10s >/dev/null ||
    fail 'Kubernetes API tunnel is open but the API server is unreachable'

  KUBECONFIG="${kubeconfig}" "$@"
}

main "$@"
