#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
COMPOSE_FILE="${ROOT_DIR}/docker-compose.kodexlink-relay.yml"
CONFIG_DIR="${XDG_CONFIG_HOME:-${HOME}/.config}/kodexlink-tools"
ENV_FILE="${KODEXLINK_RELAY_ENV_FILE:-${CONFIG_DIR}/relay.env}"
NATIVE_SERVICE_LABEL="com.kodexlink.relay"
NATIVE_RUNNER="${CONFIG_DIR}/run-native-relay.sh"
NATIVE_LOG_DIR="${HOME}/Library/Logs/kodexlink-tools"
NATIVE_LAUNCH_AGENT="${HOME}/Library/LaunchAgents/${NATIVE_SERVICE_LABEL}.plist"
NATIVE_SYSTEMD_USER_DIR="${XDG_CONFIG_HOME:-${HOME}/.config}/systemd/user"
NATIVE_SYSTEMD_UNIT="${NATIVE_SYSTEMD_USER_DIR}/kodexlink-relay.service"
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
  native-install              Install dependencies, build, and install native service.
  native-build                Install pnpm deps and build the upstream relay.
  native-config-check         Validate native relay configuration.
  native-service-install      Install launchd/systemd service for native relay.
  native-service-start        Start and enable native relay service.
  native-service-stop         Stop native relay service.
  native-service-restart      Restart native relay service.
  native-service-remove       Remove native relay service.
  native-service-status       Show native relay service status.
  native-service-logs         Follow native relay service logs.
  native-measure              Print one-shot native relay CPU and memory stats.
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
  load_env_key KODEXLINK_RELAY_RUNTIME
  load_env_key KODEXLINK_NATIVE_DEPS
  load_env_key KODEXLINK_TOOLS_DIR
  load_env_key KODEXLINK_RELAY_REPO
  load_env_key KODEXLINK_RELAY_PUBLIC_BASE_URL
  load_env_key KODEXLINK_RELAY_HOST_PORT
  load_env_key KODEXLINK_POSTGRES_DB
  load_env_key KODEXLINK_POSTGRES_USER
  load_env_key KODEXLINK_POSTGRES_PASSWORD
  load_env_key DATABASE_URL
  load_env_key REDIS_URL
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
  elif [[ -n "${!key:-}" ]]; then
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

set_env_assignment() {
  local key="$1"
  local value="$2"

  [[ "${key}" =~ ^[A-Z0-9_]+$ ]] || fail "invalid env key: ${key}"
  ensure_env

  local tmp_file
  if ! tmp_file="$(mktemp "${ENV_FILE}.XXXXXX")"; then
    fail "failed to create temporary file"
  fi

  local found=0
  while IFS= read -r line || [[ -n "${line}" ]]; do
    case "${line}" in
      "${key}="*)
        write_env_assignment "${key}" "${value}"
        found=1
        ;;
      *)
        printf '%s\n' "${line}"
        ;;
    esac
  done < "${ENV_FILE}" > "${tmp_file}"

  if [[ "${found}" -eq 0 ]]; then
    write_env_assignment "${key}" "${value}" >> "${tmp_file}"
  fi

  mv "${tmp_file}" "${ENV_FILE}"
  chmod 0600 "${ENV_FILE}"
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

  [[ -n "${DEFAULT_RELAY_REPO}" ]] || fail "cannot locate kodexlink-mobile-relay beside this repository; set KODEXLINK_RELAY_REPO in ${ENV_FILE}"
  [[ -d "${DEFAULT_RELAY_REPO}" ]] || fail "relay source directory does not exist: ${DEFAULT_RELAY_REPO}"
  [[ -f "${DEFAULT_RELAY_REPO}/package.json" ]] || fail "relay source directory does not look like the upstream repository: ${DEFAULT_RELAY_REPO}"

  local postgres_password
  postgres_password="$(random_hex)"

  mkdir -p "${CONFIG_DIR}"
  umask 077
  {
    write_env_assignment COMPOSE_PROJECT_NAME kodexlink-relay
    write_env_assignment KODEXLINK_RELAY_RUNTIME docker
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

  set_env_assignment KODEXLINK_RELAY_PUBLIC_BASE_URL "${public_url}"
  set_env_assignment RELAY_PUBLIC_BASE_URL "${public_url}"
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

  set_env_assignment KODEXLINK_RELAY_REPO "${relay_repo}"
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

native_os() {
  case "$(uname -s)" in
    Darwin)
      printf 'macos\n'
      ;;
    Linux)
      printf 'linux\n'
      ;;
    *)
      fail "native relay runtime supports macOS and Linux only"
      ;;
  esac
}

native_database_url() {
  printf 'postgres://%s:%s@127.0.0.1:5432/%s\n' \
    "${KODEXLINK_POSTGRES_USER:-kodexlink}" \
    "${KODEXLINK_POSTGRES_PASSWORD:?}" \
    "${KODEXLINK_POSTGRES_DB:-codex_mobile}"
}

native_deps_mode() {
  local mode="${KODEXLINK_NATIVE_DEPS:-external}"
  case "${mode}" in
    external|managed)
      printf '%s\n' "${mode}"
      ;;
    *)
      fail "KODEXLINK_NATIVE_DEPS must be external or managed"
      ;;
  esac
}

add_macos_brew_paths() {
  local os
  os="$(native_os)"
  if [[ "${os}" != "macos" ]]; then
    return
  fi
  if ! command -v brew >/dev/null 2>&1; then
    return
  fi

  local prefix
  local formula
  for formula in postgresql@17 node pnpm redis; do
    if prefix="$(brew --prefix "${formula}" 2>/dev/null)"; then
      PATH="${prefix}/bin:${PATH}"
    fi
  done
  export PATH
}

native_prepare_env() {
  load_env
  [[ -n "${KODEXLINK_RELAY_REPO:-}" ]] || fail "KODEXLINK_RELAY_REPO is missing from ${ENV_FILE}"
  [[ -d "${KODEXLINK_RELAY_REPO}" ]] || fail "relay source directory does not exist: ${KODEXLINK_RELAY_REPO}"
  [[ -f "${KODEXLINK_RELAY_REPO}/package.json" ]] || fail "relay source directory does not look like the upstream repository: ${KODEXLINK_RELAY_REPO}"
  [[ -n "${KODEXLINK_RELAY_PUBLIC_BASE_URL:-}" ]] || fail "KODEXLINK_RELAY_PUBLIC_BASE_URL is missing from ${ENV_FILE}"

  local deps_mode
  deps_mode="$(native_deps_mode)"
  set_env_assignment KODEXLINK_RELAY_RUNTIME native
  set_env_assignment KODEXLINK_NATIVE_DEPS "${deps_mode}"
  set_env_assignment NODE_ENV production
  set_env_assignment PORT "${KODEXLINK_RELAY_HOST_PORT:-8787}"
  set_env_assignment RELAY_BIND_HOST 127.0.0.1
  set_env_assignment RELAY_PUBLIC_BASE_URL "${KODEXLINK_RELAY_PUBLIC_BASE_URL}"
  if [[ "${deps_mode}" == "managed" ]]; then
    local database_url
    database_url="$(native_database_url)"
    set_env_assignment DATABASE_URL "${database_url}"
    set_env_assignment REDIS_URL redis://127.0.0.1:6379
  else
    [[ -n "${DATABASE_URL:-}" ]] || fail "DATABASE_URL is required when KODEXLINK_NATIVE_DEPS=external"
    [[ -n "${REDIS_URL:-}" ]] || fail "REDIS_URL is required when KODEXLINK_NATIVE_DEPS=external"
    set_env_assignment DATABASE_URL "${DATABASE_URL}"
    set_env_assignment REDIS_URL "${REDIS_URL}"
  fi
  set_env_assignment RELAY_ENABLE_DEV_RESET 0
  load_env
}

native_install_deps_macos() {
  require_command brew

  brew list node >/dev/null 2>&1 || brew install node
  brew list pnpm >/dev/null 2>&1 || brew install pnpm
  brew list postgresql@17 >/dev/null 2>&1 || brew install postgresql@17
  brew list redis >/dev/null 2>&1 || brew install redis

  add_macos_brew_paths
  brew services start postgresql@17
  brew services start redis
}

native_install_deps_linux() {
  if command -v apt-get >/dev/null 2>&1; then
    require_command sudo
    sudo apt-get update
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
      ca-certificates \
      curl \
      postgresql \
      postgresql-contrib \
      redis-server \
      redis-tools
    sudo systemctl enable --now postgresql
    sudo systemctl enable --now redis-server
  else
    require_command systemctl
    require_command psql
    require_command redis-server
    info "non-Debian Linux detected; assuming PostgreSQL and Redis are installed by the host package manager"
  fi

  require_command node
  if ! command -v pnpm >/dev/null 2>&1; then
    require_command corepack
    corepack enable
    corepack prepare pnpm@10.6.0 --activate
  fi
  require_command pnpm
}

native_install_deps() {
  local os
  os="$(native_os)"
  case "${os}" in
    macos)
      native_install_deps_macos
      ;;
    linux)
      native_install_deps_linux
      ;;
    *)
      fail "unsupported native relay OS: ${os}"
      ;;
  esac
}

postgres_admin_command() {
  add_macos_brew_paths
  local os
  os="$(native_os)"
  case "${os}" in
    macos)
      psql postgres "$@"
      ;;
    linux)
      require_command sudo
      sudo -u postgres psql postgres "$@"
      ;;
    *)
      fail "unsupported native relay OS: ${os}"
      ;;
  esac
}

postgres_createdb_command() {
  add_macos_brew_paths
  local os
  os="$(native_os)"
  case "${os}" in
    macos)
      createdb --owner="${KODEXLINK_POSTGRES_USER:-kodexlink}" "${KODEXLINK_POSTGRES_DB:-codex_mobile}"
      ;;
    linux)
      require_command sudo
      sudo -u postgres createdb --owner="${KODEXLINK_POSTGRES_USER:-kodexlink}" "${KODEXLINK_POSTGRES_DB:-codex_mobile}"
      ;;
    *)
      fail "unsupported native relay OS: ${os}"
      ;;
  esac
}

native_configure_postgres() {
  native_prepare_env
  add_macos_brew_paths
  require_command psql
  require_command createdb

  local db_name="${KODEXLINK_POSTGRES_DB:-codex_mobile}"
  local db_user="${KODEXLINK_POSTGRES_USER:-kodexlink}"
  local db_password="${KODEXLINK_POSTGRES_PASSWORD:?}"
  [[ "${db_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || fail "invalid PostgreSQL database name: ${db_name}"
  [[ "${db_user}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || fail "invalid PostgreSQL user name: ${db_user}"

  local escaped_password
  escaped_password="${db_password//\'/\'\'}"

  postgres_admin_command <<SQL
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '${db_user}') THEN
    CREATE ROLE ${db_user} LOGIN PASSWORD '${escaped_password}';
  ELSE
    ALTER ROLE ${db_user} WITH LOGIN PASSWORD '${escaped_password}';
  END IF;
END
\$\$;
SQL

  local db_exists
  db_exists="$(postgres_admin_command -tAc "SELECT 1 FROM pg_database WHERE datname = '${db_name}'")"
  if [[ "${db_exists}" != "1" ]]; then
    postgres_createdb_command
  fi
}

native_build() {
  native_prepare_env
  add_macos_brew_paths
  require_command pnpm

  (
    cd "${KODEXLINK_RELAY_REPO}"
    if command -v corepack >/dev/null 2>&1; then
      corepack enable >/dev/null 2>&1 || true
    fi
    pnpm install --frozen-lockfile
    pnpm --filter @kodexlink/protocol build
    pnpm --filter @kodexlink/shared build
    pnpm --filter @kodexlink/schemas build
    pnpm --filter @kodexlink/relay-server build
  )
}

write_native_runner() {
  native_prepare_env
  mkdir -p "${CONFIG_DIR}"
  umask 077
  cat > "${NATIVE_RUNNER}" <<EOF
#!/usr/bin/env bash
set -euo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:\${PATH:-}"
set -a
. "${ENV_FILE}"
set +a

cd "\${KODEXLINK_RELAY_REPO:?}"
node runtime-apps/relay-server/dist/server.js migrate
exec node runtime-apps/relay-server/dist/server.js serve
EOF
  chmod 0755 "${NATIVE_RUNNER}"
}

xml_escape() {
  local value="$1"
  value="${value//&/&amp;}"
  value="${value//</&lt;}"
  value="${value//>/&gt;}"
  value="${value//\"/&quot;}"
  value="${value//\'/&apos;}"
  printf '%s\n' "${value}"
}

native_write_launch_agent() {
  write_native_runner
  mkdir -p "$(dirname "${NATIVE_LAUNCH_AGENT}")" "${NATIVE_LOG_DIR}"

  local runner
  local stdout_log
  local stderr_log
  local working_dir
  runner="$(xml_escape "${NATIVE_RUNNER}")"
  stdout_log="$(xml_escape "${NATIVE_LOG_DIR}/relay.out.log")"
  stderr_log="$(xml_escape "${NATIVE_LOG_DIR}/relay.err.log")"
  working_dir="$(xml_escape "${KODEXLINK_RELAY_REPO}")"

  cat > "${NATIVE_LAUNCH_AGENT}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${NATIVE_SERVICE_LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>${runner}</string>
  </array>
  <key>WorkingDirectory</key>
  <string>${working_dir}</string>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>${stdout_log}</string>
  <key>StandardErrorPath</key>
  <string>${stderr_log}</string>
</dict>
</plist>
EOF
  chmod 0644 "${NATIVE_LAUNCH_AGENT}"
  info "installed LaunchAgent: ${NATIVE_LAUNCH_AGENT}"
}

native_write_systemd_user_unit() {
  write_native_runner
  mkdir -p "${NATIVE_SYSTEMD_USER_DIR}"

  cat > "${NATIVE_SYSTEMD_UNIT}" <<EOF
[Unit]
Description=KodexLink Native Relay
After=network-online.target postgresql.service redis-server.service
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=${KODEXLINK_RELAY_REPO}
ExecStart=/bin/bash ${NATIVE_RUNNER}
Restart=always
RestartSec=3
LimitNOFILE=65535

[Install]
WantedBy=default.target
EOF
  chmod 0644 "${NATIVE_SYSTEMD_UNIT}"
  systemctl --user daemon-reload
  info "installed systemd user unit: ${NATIVE_SYSTEMD_UNIT}"
}

native_service_install() {
  native_prepare_env
  local os
  os="$(native_os)"
  case "${os}" in
    macos)
      native_write_launch_agent
      ;;
    linux)
      require_command systemctl
      native_write_systemd_user_unit
      ;;
    *)
      fail "unsupported native relay OS: ${os}"
      ;;
  esac
}

native_install() {
  local deps_mode
  deps_mode="$(native_deps_mode)"
  if [[ "${deps_mode}" == "managed" ]]; then
    native_install_deps
    native_configure_postgres
  else
    require_command node
    require_command pnpm
    native_prepare_env
  fi
  native_build
  native_service_install
}

native_service_start() {
  native_service_install
  local os
  os="$(native_os)"
  case "${os}" in
    macos)
      local uid
      uid="$(id -u)"
      launchctl bootout "gui/${uid}" "${NATIVE_LAUNCH_AGENT}" >/dev/null 2>&1 || true
      launchctl bootstrap "gui/${uid}" "${NATIVE_LAUNCH_AGENT}"
      launchctl enable "gui/${uid}/${NATIVE_SERVICE_LABEL}"
      launchctl kickstart -k "gui/${uid}/${NATIVE_SERVICE_LABEL}"
      ;;
    linux)
      systemctl --user enable --now kodexlink-relay.service
      if command -v loginctl >/dev/null 2>&1 && command -v sudo >/dev/null 2>&1; then
        sudo loginctl enable-linger "${USER}" || true
      fi
      ;;
    *)
      fail "unsupported native relay OS: ${os}"
      ;;
  esac
}

native_service_stop() {
  local os
  os="$(native_os)"
  case "${os}" in
    macos)
      local uid
      uid="$(id -u)"
      launchctl bootout "gui/${uid}" "${NATIVE_LAUNCH_AGENT}" >/dev/null 2>&1 || true
      ;;
    linux)
      systemctl --user stop kodexlink-relay.service
      ;;
    *)
      fail "unsupported native relay OS: ${os}"
      ;;
  esac
}

native_service_restart() {
  local os
  os="$(native_os)"
  case "${os}" in
    macos)
      native_service_start
      ;;
    linux)
      native_service_install
      systemctl --user restart kodexlink-relay.service
      ;;
    *)
      fail "unsupported native relay OS: ${os}"
      ;;
  esac
}

native_service_remove() {
  set +e
  native_service_stop
  set -e
  local os
  os="$(native_os)"
  case "${os}" in
    macos)
      rm -f "${NATIVE_LAUNCH_AGENT}"
      ;;
    linux)
      systemctl --user disable kodexlink-relay.service >/dev/null 2>&1 || true
      rm -f "${NATIVE_SYSTEMD_UNIT}"
      systemctl --user daemon-reload
      ;;
    *)
      fail "unsupported native relay OS: ${os}"
      ;;
  esac
}

native_service_status() {
  local os
  os="$(native_os)"
  case "${os}" in
    macos)
      local uid
      uid="$(id -u)"
      launchctl print "gui/${uid}/${NATIVE_SERVICE_LABEL}"
      ;;
    linux)
      systemctl --user status kodexlink-relay.service
      ;;
    *)
      fail "unsupported native relay OS: ${os}"
      ;;
  esac
}

native_service_logs() {
  local os
  os="$(native_os)"
  case "${os}" in
    macos)
      mkdir -p "${NATIVE_LOG_DIR}"
      touch "${NATIVE_LOG_DIR}/relay.out.log" "${NATIVE_LOG_DIR}/relay.err.log"
      tail -f "${NATIVE_LOG_DIR}/relay.out.log" "${NATIVE_LOG_DIR}/relay.err.log"
      ;;
    linux)
      journalctl --user -u kodexlink-relay.service -f
      ;;
    *)
      fail "unsupported native relay OS: ${os}"
      ;;
  esac
}

native_config_check() {
  native_prepare_env
  [[ -x "${NATIVE_RUNNER}" ]] || fail "missing native runner; run: make install RELAY_RUNTIME=native"
  local os
  os="$(native_os)"
  case "${os}" in
    macos)
      [[ -f "${NATIVE_LAUNCH_AGENT}" ]] || fail "missing LaunchAgent; run: make install RELAY_RUNTIME=native"
      plutil -lint "${NATIVE_LAUNCH_AGENT}" >/dev/null
      ;;
    linux)
      [[ -f "${NATIVE_SYSTEMD_UNIT}" ]] || fail "missing systemd user unit; run: make install RELAY_RUNTIME=native"
      systemctl --user daemon-reload
      ;;
    *)
      fail "unsupported native relay OS: ${os}"
      ;;
  esac
}

native_measure() {
  local pids
  pids="$(pgrep -f 'runtime-apps/relay-server/dist/server.js serve' || true)"
  if [[ -z "${pids}" ]]; then
    fail "native relay process is not running"
  fi
  # shellcheck disable=SC2086
  ps -o pid,pcpu,pmem,rss,command -p ${pids}
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
  native-install)
    native_install
    ;;
  native-build)
    native_build
    ;;
  native-config-check)
    native_config_check
    ;;
  native-service-install)
    native_service_install
    ;;
  native-service-start)
    native_service_start
    ;;
  native-service-stop)
    native_service_stop
    ;;
  native-service-restart)
    native_service_restart
    ;;
  native-service-remove)
    native_service_remove
    ;;
  native-service-status)
    native_service_status
    ;;
  native-service-logs)
    native_service_logs
    ;;
  native-measure)
    native_measure
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
