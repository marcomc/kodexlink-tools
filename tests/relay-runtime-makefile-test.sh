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

printf 'relay runtime Makefile routing tests passed\n'
