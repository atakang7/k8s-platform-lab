#!/usr/bin/env bash

hold_sudo_credential() {
  local owner_pid="$$"

  if [[ -n "${LAB_SUDO_KEEPALIVE_PID:-}" ]] &&
    kill -0 "${LAB_SUDO_KEEPALIVE_PID}" 2>/dev/null; then
    return 0
  fi

  (
    while kill -0 "${owner_pid}" 2>/dev/null; do
      sudo -n true 2>/dev/null || exit 0
      sleep 45
    done
  ) &

  LAB_SUDO_KEEPALIVE_PID=$!
}

require_sudo() {
  local context="${1:-operation}"

  if sudo -n true 2>/dev/null; then
    hold_sudo_credential
    return 0
  fi

  if [[ ! -t 0 ]]; then
    printf 'FAIL | %s requires sudo authentication from an interactive terminal\n' "${context}" >&2
    return 1
  fi

  printf 'WAIT | sudo authentication required for %s\n' "${context}"
  sudo -v || {
    printf 'FAIL | sudo authentication failed for %s\n' "${context}" >&2
    return 1
  }

  hold_sudo_credential
}
