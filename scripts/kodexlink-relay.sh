#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
COMPOSE_FILE="${ROOT_DIR}/docker-compose.kodexlink-relay.yml"
CONFIG_DIR="${XDG_CONFIG_HOME:-${HOME}/.config}/kodexlink-tools"
ENV_FILE="${KODEXLINK_RELAY_ENV_FILE:-${CONFIG_DIR}/relay.env}"
if [[ -n "${KODEXLINK_RELAY_REPO:-}" ]]; then
  DEFAULT_RELAY_REPO="${KODEXLINK_RELAY_REPO}"
else
  DEFAULT_RELAY_REPO="$(cd "${ROOT_DIR}/../kodexlink-mobile-relay" 2>/dev/null && pwd || true)"
fi

usage() {
  cat <<'EOF'
Usage: ./scripts/kodexlink-relay.sh <command> [args]

Commands:
  init-env [public-url]       Create relay.env with generated database password.
  set-relay-repo <path>       Update the upstream relay source directory.
  set-public-url <url>        Update KODEXLINK_RELAY_PUBLIC_BASE_URL.
  up                          Build and start PostgreSQL, Redis, and relay.
  down                        Stop containers.
  restart                     Restart containers.
  status                      Show container status.
  logs [service]              Follow logs for all services or one service.
  health                      Check local relay health endpoint.
  measure                     Print one-shot Docker CPU and memory stats.
  public-url                  Print the configured public relay base URL.
  desktop-start               Start KodexLink desktop agent with this relay.
  desktop-pair                Open the KodexLink local QR pairing panel.
  desktop-service-install     Install macOS LaunchAgent with this relay.
  desktop-service-stop        Stop the macOS LaunchAgent.
  desktop-service-remove      Remove the macOS LaunchAgent.
  desktop-status              Show KodexLink desktop agent status.
  tailscale-serve             Publish privately to your tailnet over HTTPS.
  tailscale-serve-off         Disable the Tailscale Serve HTTPS 443 proxy.
  tailscale-funnel            Publish publicly with Tailscale Funnel.
  tailscale-funnel-off        Disable the Tailscale Funnel HTTPS 443 proxy.
EOF
}

fail() {
  printf '[kodexlink-relay][ERROR] %s\n' "$1" >&2
  exit 1
}

info() {
  printf '[kodexlink-relay] %s\n' "$1"
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "missing required command: $1"
}

random_hex() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 24
    return
  fi

  require_command od
  od -An -N24 -tx1 /dev/urandom | tr -d ' \n'
  printf '\n'
}

ensure_env() {
  [[ -f "${ENV_FILE}" ]] || fail "missing ${ENV_FILE}; run: ./scripts/kodexlink-relay.sh init-env https://your-relay.example.com"
  [[ -r "${ENV_FILE}" ]] || fail "cannot read ${ENV_FILE}"
}

load_env() {
  ensure_env
  load_env_key COMPOSE_PROJECT_NAME
  load_env_key KODEXLINK_TOOLS_DIR
  load_env_key KODEXLINK_RELAY_REPO
  load_env_key KODEXLINK_RELAY_PUBLIC_BASE_URL
  load_env_key KODEXLINK_RELAY_HOST_PORT
  load_env_key KODEXLINK_POSTGRES_DB
  load_env_key KODEXLINK_POSTGRES_USER
  load_env_key KODEXLINK_POSTGRES_PASSWORD
}

env_value() {
  local key="$1"
  local line
  local value

  ensure_env
  while IFS= read -r line || [[ -n "${line}" ]]; do
    case "${line}" in
      ''|'#'*)
        continue
        ;;
      "${key}="*)
        value="${line#*=}"
        if [[ "${#value}" -ge 2 ]]; then
          local first_char="${value:0:1}"
          local last_char="${value: -1}"
          if { [[ "${first_char}" == "'" && "${last_char}" == "'" ]] || [[ "${first_char}" == '"' && "${last_char}" == '"' ]]; }; then
            value="${value:1:${#value}-2}"
          fi
        fi
        printf '%s\n' "${value}"
        return 0
        ;;
      *)
        ;;
    esac
  done < "${ENV_FILE}"

  return 1
}

load_env_key() {
  local key="$1"
  local value
  local rc

  set +e
  value="$(env_value "${key}")"
  rc=$?
  set -e

  if [[ "${rc}" -eq 0 ]]; then
    printf -v "${key}" '%s' "${value}"
    export "${key?}"
  else
    unset "${key?}"
  fi
}

write_env_assignment() {
  local key="$1"
  local value="$2"

  [[ "${value}" != *$'\n'* && "${value}" != *$'\r'* ]] || fail "${key} cannot contain newlines"
  printf '%s=%s\n' "${key}" "${value}"
}

compose() {
  load_env
  KODEXLINK_TOOLS_DIR="${ROOT_DIR}" docker compose --env-file "${ENV_FILE}" -f "${COMPOSE_FILE}" "$@"
}

init_env() {
  local public_url="${1:-http://127.0.0.1:8787}"

  if [[ -f "${ENV_FILE}" ]]; then
    fail "${ENV_FILE} already exists; edit it directly if you need to change the relay URL"
  fi

  require_command docker
  [[ -n "${DEFAULT_RELAY_REPO}" ]] || fail "cannot locate kodexlink-mobile-relay beside this repository; set KODEXLINK_RELAY_REPO in ${ENV_FILE}"
  [[ -d "${DEFAULT_RELAY_REPO}" ]] || fail "relay source directory does not exist: ${DEFAULT_RELAY_REPO}"
  [[ -f "${DEFAULT_RELAY_REPO}/package.json" ]] || fail "relay source directory does not look like the upstream repository: ${DEFAULT_RELAY_REPO}"

  local postgres_password
  postgres_password="$(random_hex)"

  mkdir -p "${CONFIG_DIR}"
  umask 077
  {
    write_env_assignment COMPOSE_PROJECT_NAME kodexlink-relay
    write_env_assignment KODEXLINK_TOOLS_DIR "${ROOT_DIR}"
    write_env_assignment KODEXLINK_RELAY_REPO "${DEFAULT_RELAY_REPO}"
    write_env_assignment KODEXLINK_RELAY_PUBLIC_BASE_URL "${public_url}"
    write_env_assignment KODEXLINK_RELAY_HOST_PORT 8787
    write_env_assignment KODEXLINK_POSTGRES_DB codex_mobile
    write_env_assignment KODEXLINK_POSTGRES_USER kodexlink
    write_env_assignment KODEXLINK_POSTGRES_PASSWORD "${postgres_password}"
  } > "${ENV_FILE}"

  info "created ${ENV_FILE}"
  info "public relay URL: ${public_url}"
}

set_public_url() {
  local public_url="${1:-}"
  [[ -n "${public_url}" ]] || fail "usage: ./scripts/kodexlink-relay.sh set-public-url https://machine.tailnet.ts.net"

  if [[ ! -f "${ENV_FILE}" ]]; then
    init_env "${public_url}"
    return
  fi

  local tmp_file
  if ! tmp_file="$(mktemp "${ENV_FILE}.XXXXXX")"; then
    fail "failed to create temporary file"
  fi

  local found=0
  while IFS= read -r line || [[ -n "${line}" ]]; do
    case "${line}" in
      KODEXLINK_RELAY_PUBLIC_BASE_URL=*)
        write_env_assignment KODEXLINK_RELAY_PUBLIC_BASE_URL "${public_url}"
        found=1
        ;;
      *)
        printf '%s\n' "${line}"
        ;;
    esac
  done < "${ENV_FILE}" > "${tmp_file}"

  if [[ "${found}" -eq 0 ]]; then
    write_env_assignment KODEXLINK_RELAY_PUBLIC_BASE_URL "${public_url}" >> "${tmp_file}"
  fi

  mv "${tmp_file}" "${ENV_FILE}"
  chmod 0600 "${ENV_FILE}"
  info "updated public relay URL: ${public_url}"
}

set_relay_repo() {
  local relay_repo="${1:-}"
  [[ -n "${relay_repo}" ]] || fail "usage: ./scripts/kodexlink-relay.sh set-relay-repo /path/to/codex-mobile-relay"
  [[ -d "${relay_repo}" ]] || fail "relay source directory does not exist: ${relay_repo}"
  [[ -f "${relay_repo}/package.json" ]] || fail "relay source directory does not look like the upstream repository: ${relay_repo}"

  if [[ ! -f "${ENV_FILE}" ]]; then
    DEFAULT_RELAY_REPO="${relay_repo}" init_env
    return
  fi

  local tmp_file
  if ! tmp_file="$(mktemp "${ENV_FILE}.XXXXXX")"; then
    fail "failed to create temporary file"
  fi

  local found=0
  while IFS= read -r line || [[ -n "${line}" ]]; do
    case "${line}" in
      KODEXLINK_RELAY_REPO=*)
        write_env_assignment KODEXLINK_RELAY_REPO "${relay_repo}"
        found=1
        ;;
      *)
        printf '%s\n' "${line}"
        ;;
    esac
  done < "${ENV_FILE}" > "${tmp_file}"

  if [[ "${found}" -eq 0 ]]; then
    write_env_assignment KODEXLINK_RELAY_REPO "${relay_repo}" >> "${tmp_file}"
  fi

  mv "${tmp_file}" "${ENV_FILE}"
  chmod 0600 "${ENV_FILE}"
  info "updated relay source directory"
}

health() {
  load_env
  local port="${KODEXLINK_RELAY_HOST_PORT:-8787}"
  require_command curl
  curl -fsS "http://127.0.0.1:${port}/healthz"
  printf '\n'
}

measure() {
  load_env
  local -a container_ids=()
  local container_id
  local ids_output
  ids_output="$(docker compose --env-file "${ENV_FILE}" -f "${COMPOSE_FILE}" ps -q)"
  while IFS= read -r container_id; do
    [[ -n "${container_id}" ]] && container_ids+=("${container_id}")
  done <<< "${ids_output}"
  if [[ "${#container_ids[@]}" -eq 0 ]]; then
    fail "no running containers for this compose project"
  fi
  docker stats --no-stream --format 'table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.NetIO}}\t{{.BlockIO}}' "${container_ids[@]}"
}

print_public_url() {
  load_env
  printf '%s\n' "${KODEXLINK_RELAY_PUBLIC_BASE_URL:?}"
}

desktop_command() {
  local subcommand="$1"
  shift
  load_env
  require_command kodexlink
  kodexlink "${subcommand}" --relay "${KODEXLINK_RELAY_PUBLIC_BASE_URL:?}" "$@"
}

require_tailscale() {
  require_command tailscale
}

tailscale_target() {
  printf 'http://127.0.0.1:%s\n' "${KODEXLINK_RELAY_HOST_PORT:-8787}"
}

tailscale_serve() {
  require_tailscale
  load_env
  local target
  target="$(tailscale_target)"
  tailscale serve --bg --https=443 "${target}"
  tailscale serve status
}

tailscale_serve_off() {
  require_tailscale
  tailscale serve --https=443 off
  tailscale serve status
}

tailscale_funnel() {
  require_tailscale
  load_env
  local target
  target="$(tailscale_target)"
  tailscale funnel --bg --https=443 "${target}"
  tailscale funnel status
}

tailscale_funnel_off() {
  require_tailscale
  if ! tailscale status --json | grep -Eq '"funnel"|"https://tailscale.com/cap/funnel"'; then
    info "Tailscale Funnel is not enabled for this node; leaving Tailscale Serve unchanged."
    tailscale serve status
    return 0
  fi

  tailscale funnel --https=443 off
  tailscale funnel status
}

case "${1:-}" in
  init-env)
    shift
    init_env "${1:-}"
    ;;
  set-relay-repo)
    shift
    set_relay_repo "${1:-}"
    ;;
  set-public-url)
    shift
    set_public_url "${1:-}"
    ;;
  up)
    compose up -d --build postgres redis relay
    compose ps
    ;;
  down)
    compose down
    ;;
  restart)
    compose up -d --build postgres redis relay
    compose ps
    ;;
  status)
    compose ps
    ;;
  logs)
    shift
    compose logs -f "$@"
    ;;
  health)
    health
    ;;
  measure)
    measure
    ;;
  public-url)
    print_public_url
    ;;
  desktop-start)
    desktop_command start
    ;;
  desktop-pair)
    desktop_command pair
    ;;
  desktop-service-install)
    desktop_command service-install
    ;;
  desktop-service-stop)
    desktop_command service-stop
    ;;
  desktop-service-remove)
    desktop_command service-remove
    ;;
  desktop-status)
    desktop_command status
    ;;
  tailscale-serve)
    tailscale_serve
    ;;
  tailscale-serve-off)
    tailscale_serve_off
    ;;
  tailscale-funnel)
    tailscale_funnel
    ;;
  tailscale-funnel-off)
    tailscale_funnel_off
    ;;
  help|--help|-h)
    usage
    ;;
  *)
    usage
    exit 1
    ;;
esac
