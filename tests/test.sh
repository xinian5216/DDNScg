#!/usr/bin/env bash

set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=/dev/null
source "${ROOT_DIR}/ddnscg.sh"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*"; }

is_ipv4 203.0.113.7 || fail "合法 IPv4 被拒绝"
! is_ipv4 999.0.0.1 || fail "非法 IPv4 被接受"
is_ipv6 2001:db8:1::42 || fail "压缩 IPv6 被拒绝"
is_ipv6 2001:db8:0:1:2:3:4:5 || fail "完整 IPv6 被拒绝"
! is_ipv6 2001:::42 || fail "非法 IPv6 被接受"
! is_ipv6 :::1 || fail "三冒号 IPv6 被接受"
! is_ipv6 fe80::1 || fail "链路本地 IPv6 被接受"
pass "IP 地址校验"

run_case() {
  local stack="$1" record_types="$2" expected_patches="$3"
  local work config log
  work="$(mktemp -d)"
  config="${work}/config"
  log="${work}/curl.log"
  : >"$log"
  cat >"$config" <<EOF
CF_API_TOKEN=test-token
CF_ZONE_ID=zone-id
CF_ZONE=example.com
RECORD_NAMES=vps.example.com
RECORD_TYPES=${record_types}
IPV4_SOURCE=external
IPV6_SOURCE=external
INTERFACE=auto
PROXIED=false
TTL=1
EOF

  MOCK_STACK="$stack" MOCK_LOG="$log" \
    DDNSCG_CONFIG_FILE="$config" \
    DDNSCG_STATE_DIR="${work}/state" \
    DDNSCG_CURL_BIN="${ROOT_DIR}/tests/fixtures/mock-curl.sh" \
    bash "${ROOT_DIR}/ddnscg.sh" run >/dev/null

  local patch_count
  patch_count="$(grep -c '^PATCH ' "$log" || true)"
  [[ "$patch_count" == "$expected_patches" ]] || fail "$stack 应写入 $expected_patches 条记录，实际 $patch_count"
  if [[ "$stack" == "v6" ]]; then
    ! grep -q '"type":"A"' "$log" || fail "纯 IPv6 模式不应写入 A 记录"
    grep -q '"type":"AAAA"' "$log" || fail "纯 IPv6 模式没有写入 AAAA 记录"
  fi
  rm -rf -- "$work"
}

run_case dual A,AAAA 2
pass "双栈更新 A 与 AAAA"
run_case v6 auto 1
pass "纯 IPv6 的 auto 模式仅更新 AAAA"

printf 'All tests passed.\n'
