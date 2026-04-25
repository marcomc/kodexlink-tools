#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

assert_contains() {
  local haystack="$1"
  local needle="$2"

  if [[ "${haystack}" != *"${needle}"* ]]; then
    printf 'Expected output to contain: %s\n' "${needle}" >&2
    printf 'Actual output:\n%s\n' "${haystack}" >&2
    exit 1
  fi
}

assert_not_contains() {
  local haystack="$1"
  local needle="$2"

  if [[ "${haystack}" == *"${needle}"* ]]; then
    printf 'Expected output not to contain: %s\n' "${needle}" >&2
    printf 'Actual output:\n%s\n' "${haystack}" >&2
    exit 1
  fi
}

assert_file_contains() {
  local file="$1"
  local needle="$2"
  local contents

  contents="$(<"${file}")"
  assert_contains "${contents}" "${needle}"
}

assert_file_not_contains() {
  local file="$1"
  local needle="$2"
  local contents

  contents="$(<"${file}")"
  assert_not_contains "${contents}" "${needle}"
}

run_make_dry() {
  make -n -C "${ROOT_DIR}" "$@"
}

default_start="$(run_make_dry start)"
assert_contains "${default_start}" "docker-start"
assert_contains "${default_start}" "./scripts/kodexlink-relay.sh up"

native_start="$(run_make_dry start RELAY_RUNTIME=native)"
assert_contains "${native_start}" "native-start"
assert_not_contains "${native_start}" "docker-start"
assert_not_contains "${native_start}" "./scripts/kodexlink-relay.sh up"

native_install="$(run_make_dry install RELAY_RUNTIME=native PUBLIC_URL=https://machine-name.tailnet-name.ts.net)"
assert_contains "${native_install}" "install-relay-native"
assert_contains "${native_install}" "KODEXLINK_NATIVE_DEPS=\"external\""
assert_not_contains "${native_install}" "docker-start"

managed_native_install="$(run_make_dry install RELAY_RUNTIME=native NATIVE_DEPS=managed PUBLIC_URL=https://machine-name.tailnet-name.ts.net)"
assert_contains "${managed_native_install}" "KODEXLINK_NATIVE_DEPS=\"managed\""

fixture_dir="$(mktemp -d)"
cleanup() {
  rm -rf "${fixture_dir}"
}
trap cleanup EXIT

native_home="${fixture_dir}/home"
native_config="${fixture_dir}/config"
fake_bin="${fixture_dir}/bin"
fake_repo="${fixture_dir}/relay repo %encoded"
env_file="${fixture_dir}/relay.env"
dollar='$'
malicious_database_url="postgres://user:pa${dollar}(touch ${fixture_dir}/owned)@127.0.0.1:5432/codex_mobile"

mkdir -p "${native_home}" "${native_config}" "${fake_bin}" "${fake_repo}"
printf '{}\n' > "${fake_repo}/package.json"
cat > "${fake_bin}/systemctl" <<'EOF_SYSTEMCTL'
#!/usr/bin/env sh
exit 0
EOF_SYSTEMCTL
chmod 0755 "${fake_bin}/systemctl"
cat > "${fake_bin}/systemd-analyze" <<'EOF_SYSTEMD_ANALYZE'
#!/usr/bin/env sh
exit 0
EOF_SYSTEMD_ANALYZE
chmod 0755 "${fake_bin}/systemd-analyze"
{
  printf 'COMPOSE_PROJECT_NAME=kodexlink-relay\n'
  printf 'KODEXLINK_RELAY_RUNTIME=native\n'
  printf 'KODEXLINK_NATIVE_DEPS=external\n'
  printf 'KODEXLINK_TOOLS_DIR=%s\n' "${ROOT_DIR}"
  printf 'KODEXLINK_RELAY_REPO=%s\n' "${fake_repo}"
  printf 'KODEXLINK_RELAY_PUBLIC_BASE_URL=https://machine-name.tailnet-name.ts.net\n'
  printf 'KODEXLINK_RELAY_HOST_PORT=8787\n'
  printf 'DATABASE_URL=%s\n' "${malicious_database_url}"
  printf 'REDIS_URL=redis://127.0.0.1:6379\n'
} > "${env_file}"

HOME="${native_home}" \
  XDG_CONFIG_HOME="${native_config}" \
  KODEXLINK_RELAY_ENV_FILE="${env_file}" \
  PATH="${fake_bin}:${PATH}" \
  "${ROOT_DIR}/scripts/kodexlink-relay.sh" native-service-install

runner="${native_config}/kodexlink-tools/run-native-relay.sh"
assert_file_contains "${runner}" "load_env_file"
assert_file_not_contains "${runner}" ". \"${env_file}\""
bash -n "${runner}"
if [[ -e "${fixture_dir}/owned" ]]; then
  printf 'Generated native service evaluated relay.env as shell code.\n' >&2
  exit 1
fi

env_before="$(shasum "${env_file}")"
HOME="${native_home}" \
  XDG_CONFIG_HOME="${native_config}" \
  KODEXLINK_RELAY_ENV_FILE="${env_file}" \
  PATH="${fake_bin}:${PATH}" \
  "${ROOT_DIR}/scripts/kodexlink-relay.sh" native-config-check
env_after="$(shasum "${env_file}")"
if [[ "${env_before}" != "${env_after}" ]]; then
  printf 'native-config-check rewrote relay.env.\n' >&2
  exit 1
fi

case "$(uname -s)" in
  Darwin)
    assert_file_contains "${native_home}/Library/LaunchAgents/com.kodexlink.relay.plist" "${fake_repo}"
    ;;
  Linux)
    escaped_repo="${fake_repo//%/%%}"
    assert_file_contains "${native_config}/systemd/user/kodexlink-relay.service" "WorkingDirectory=\"${escaped_repo}\""
    assert_file_contains "${native_config}/systemd/user/kodexlink-relay.service" "ExecStart=/bin/bash \"${runner}\""
    ;;
  *)
    printf 'Skipping native service file assertion for unsupported test OS.\n'
    ;;
esac

printf 'relay runtime Makefile routing tests passed\n'
