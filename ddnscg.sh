#!/usr/bin/env bash

set -Eeuo pipefail

readonly DDNSCG_VERSION="0.1.0"
readonly DDNSCG_NAME="DDNScg"

CONFIG_FILE="${DDNSCG_CONFIG_FILE:-/etc/ddnscg/config}"
STATE_DIR="${DDNSCG_STATE_DIR:-/var/lib/ddnscg}"
CF_API_BASE="${DDNSCG_CF_API_BASE:-https://api.cloudflare.com/client/v4}"
CURL_BIN="${DDNSCG_CURL_BIN:-curl}"
JQ_BIN="${DDNSCG_JQ_BIN:-jq}"
IP_BIN="${DDNSCG_IP_BIN:-ip}"

CF_API_TOKEN=""
CF_ZONE_ID=""
CF_ZONE=""
RECORD_NAMES=""
RECORD_TYPES="auto"
IPV4_SOURCE="auto"
IPV6_SOURCE="auto"
INTERFACE="auto"
PROXIED="false"
TTL="1"

DRY_RUN="false"
FORCE_UPDATE="false"
UPDATED_COUNT=0
UNCHANGED_COUNT=0
CREATED_COUNT=0

timestamp() { date '+%Y-%m-%d %H:%M:%S%z'; }
log() { printf '%s [%s] %s\n' "$(timestamp)" "$1" "$2" >&2; }
info() { log INFO "$*"; }
warn() { log WARN "$*"; }
die() { log ERROR "$*"; exit 1; }

trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "缺少依赖：$1。请重新运行 install.sh 安装依赖。"
}

is_allowed_config_key() {
  case "$1" in
    CF_API_TOKEN | CF_ZONE_ID | CF_ZONE | RECORD_NAMES | RECORD_TYPES | IPV4_SOURCE | IPV6_SOURCE | INTERFACE | PROXIED | TTL) return 0 ;;
    *) return 1 ;;
  esac
}

load_config() {
  [[ -r "$CONFIG_FILE" ]] || die "找不到配置文件：$CONFIG_FILE。请先运行 ddnscg configure。"

  local raw line key value line_number=0
  while IFS= read -r raw || [[ -n "$raw" ]]; do
    line_number=$((line_number + 1))
    line="${raw%$'\r'}"
    line="$(trim "$line")"
    [[ -z "$line" || "${line:0:1}" == "#" ]] && continue

    if [[ ! "$line" =~ ^([A-Z0-9_]+)[[:space:]]*=(.*)$ ]]; then
      die "配置文件第 ${line_number} 行格式错误。"
    fi

    key="${BASH_REMATCH[1]}"
    value="$(trim "${BASH_REMATCH[2]}")"
    is_allowed_config_key "$key" || die "配置文件包含未知选项：$key"

    if [[ ${#value} -ge 2 ]]; then
      if [[ "${value:0:1}" == '"' && "${value: -1}" == '"' ]] ||
        [[ "${value:0:1}" == "'" && "${value: -1}" == "'" ]]; then
        value="${value:1:${#value}-2}"
      fi
    fi
    printf -v "$key" '%s' "$value"
  done <"$CONFIG_FILE"
}

normalize_record_types() {
  local normalized
  normalized="${RECORD_TYPES^^}"
  normalized="${normalized//[[:space:]]/}"
  case "$normalized" in
    AUTO) RECORD_TYPES="auto" ;;
    A) RECORD_TYPES="A" ;;
    AAAA) RECORD_TYPES="AAAA" ;;
    A,AAAA | AAAA,A) RECORD_TYPES="A,AAAA" ;;
    *) die "RECORD_TYPES 只能是 auto、A、AAAA 或 A,AAAA。" ;;
  esac
}

validate_source() {
  case "$2" in
    auto | external | interface) ;;
    *) die "$1 只能是 auto、external 或 interface。" ;;
  esac
}

validate_config() {
  [[ -n "$CF_API_TOKEN" ]] || die "CF_API_TOKEN 不能为空。"
  [[ -n "$CF_ZONE_ID" || -n "$CF_ZONE" ]] || die "CF_ZONE_ID 与 CF_ZONE 至少填写一项。"
  [[ -n "$RECORD_NAMES" ]] || die "RECORD_NAMES 不能为空。"
  [[ "$TTL" =~ ^[0-9]+$ ]] || die "TTL 必须是整数。"
  if [[ "$TTL" != "1" ]] && ((TTL < 60 || TTL > 86400)); then
    die "TTL 必须为 1（自动）或 60–86400。"
  fi
  case "$PROXIED" in
    true | false) ;;
    *) die "PROXIED 只能是 true 或 false。" ;;
  esac
  validate_source IPV4_SOURCE "$IPV4_SOURCE"
  validate_source IPV6_SOURCE "$IPV6_SOURCE"
  normalize_record_types

  local record
  IFS=',' read -ra records <<<"$RECORD_NAMES"
  for record in "${records[@]}"; do
    record="$(trim "$record")"
    [[ "$record" =~ ^([A-Za-z0-9_*-]+\.)*[A-Za-z0-9_-]+\.?$ ]] || die "记录名格式不正确：$record"
  done
}

is_ipv4() {
  local value="$1" a b c d extra
  IFS='.' read -r a b c d extra <<<"$value"
  [[ -z "${extra:-}" && -n "${a:-}" && -n "${b:-}" && -n "${c:-}" && -n "${d:-}" ]] || return 1
  local octet
  for octet in "$a" "$b" "$c" "$d"; do
    [[ "$octet" =~ ^[0-9]{1,3}$ ]] || return 1
    ((10#$octet <= 255)) || return 1
  done
  [[ "$value" != "0.0.0.0" ]]
}

is_ipv6() {
  local value="${1,,}"
  [[ "$value" == *:* && "$value" =~ ^[0-9a-f:.]+$ ]] || return 1
  [[ "$value" != *:::* ]] || return 1
  [[ "$value" != "::" && "$value" != "::1" ]] || return 1
  [[ "$value" != fe8* && "$value" != fe9* && "$value" != fea* && "$value" != feb* ]] || return 1
  [[ "$value" != fc* && "$value" != fd* && "$value" != ff* ]] || return 1

  local left right compressed=false group
  local -a groups=()
  if [[ "$value" == *::* ]]; then
    compressed=true
    left="${value%%::*}"
    right="${value#*::}"
    [[ "$right" != *::* ]] || return 1
    [[ -z "$left" ]] || {
      IFS=':' read -ra groups <<<"$left"
    }
    if [[ -n "$right" ]]; then
      local -a right_groups=()
      IFS=':' read -ra right_groups <<<"$right"
      groups+=("${right_groups[@]}")
    fi
  else
    IFS=':' read -ra groups <<<"$value"
  fi
  for group in "${groups[@]}"; do
    [[ "$group" =~ ^[0-9a-f]{1,4}$ ]] || return 1
  done
  if [[ "$compressed" == "true" ]]; then
    ((${#groups[@]} < 8))
  else
    ((${#groups[@]} == 8))
  fi
}

external_ip() {
  local family="$1" flag candidate endpoint
  case "$family" in
    4) flag="-4" ;;
    6) flag="-6" ;;
    *) return 1 ;;
  esac

  local endpoints=(
    "https://speed.cloudflare.com/cdn-cgi/trace"
    "https://www.cloudflare.com/cdn-cgi/trace"
  )
  for endpoint in "${endpoints[@]}"; do
    candidate="$("$CURL_BIN" "$flag" --silent --show-error --location --noproxy '*' \
      --connect-timeout 5 --max-time 12 --retry 1 "$endpoint" 2>/dev/null |
      awk -F= '$1 == "ip" {gsub(/\r/, "", $2); print $2; exit}')" || true
    if [[ "$family" == "4" ]] && is_ipv4 "$candidate"; then
      printf '%s\n' "$candidate"
      return 0
    fi
    if [[ "$family" == "6" ]] && is_ipv6 "$candidate"; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

route_source_ip() {
  local family="$1" target output candidate
  case "$family" in
    4) target="1.1.1.1" ;;
    6) target="2606:4700:4700::1111" ;;
    *) return 1 ;;
  esac

  if [[ "$INTERFACE" == "auto" ]]; then
    output="$("$IP_BIN" "-$family" route get "$target" 2>/dev/null)" || return 1
    candidate="$(awk '{for (i=1; i<=NF; i++) if ($i == "src") {print $(i+1); exit}}' <<<"$output")"
  else
    output="$("$IP_BIN" -o "-$family" addr show dev "$INTERFACE" scope global 2>/dev/null)" || return 1
    candidate="$(awk '
      !/temporary|deprecated|tentative/ {split($4, a, "/"); print a[1]; found=1; exit}
      END {if (!found && NR) {split($4, a, "/"); print a[1]}}
    ' <<<"$output")"
  fi

  if [[ "$family" == "4" ]] && is_ipv4 "$candidate"; then
    printf '%s\n' "$candidate"
    return 0
  fi
  if [[ "$family" == "6" ]] && is_ipv6 "$candidate"; then
    printf '%s\n' "$candidate"
    return 0
  fi
  return 1
}

detect_ip() {
  local family="$1" source value=""
  if [[ "$family" == "4" ]]; then source="$IPV4_SOURCE"; else source="$IPV6_SOURCE"; fi

  case "$source" in
    external) value="$(external_ip "$family")" || return 1 ;;
    interface) value="$(route_source_ip "$family")" || return 1 ;;
    auto)
      if [[ "$family" == "4" ]]; then
        value="$(external_ip "$family")" || value="$(route_source_ip "$family")" || return 1
      else
        value="$(route_source_ip "$family")" || value="$(external_ip "$family")" || return 1
      fi
      ;;
  esac
  printf '%s\n' "$value"
}

cf_api_request() {
  local method="$1" path="$2" payload="${3:-}"
  shift 3 || true
  local response_file http_code rc=0 error_text
  response_file="$(mktemp)"

  local args=(
    --silent --show-error --connect-timeout 8 --max-time 30 --retry 2
    --output "$response_file" --write-out '%{http_code}'
    --request "$method"
    --header "Authorization: Bearer $CF_API_TOKEN"
    --header 'Accept: application/json'
  )
  if [[ "$method" == "GET" ]]; then
    args+=(--get)
    local query
    for query in "$@"; do args+=(--data-urlencode "$query"); done
  else
    args+=(--header 'Content-Type: application/json' --data "$payload")
  fi

  http_code="$("$CURL_BIN" "${args[@]}" "${CF_API_BASE}${path}")" || rc=$?
  if ((rc != 0)); then
    rm -f "$response_file"
    die "连接 Cloudflare API 失败（curl $rc）。"
  fi

  if [[ ! "$http_code" =~ ^2[0-9][0-9]$ ]] || ! "$JQ_BIN" -e '.success == true' "$response_file" >/dev/null 2>&1; then
    error_text="$($JQ_BIN -r '[.errors[]? | ((.code // "?")|tostring) + ": " + (.message // "未知错误")] | join("; ")' "$response_file" 2>/dev/null || true)"
    rm -f "$response_file"
    [[ -n "$error_text" ]] || error_text="HTTP $http_code，响应格式异常"
    die "Cloudflare API 请求失败：$error_text"
  fi

  "$JQ_BIN" -c '.' "$response_file"
  rm -f "$response_file"
}

resolve_zone_id() {
  if [[ -n "$CF_ZONE_ID" ]]; then
    printf '%s\n' "$CF_ZONE_ID"
    return 0
  fi

  local response count zone_id
  response="$(cf_api_request GET /zones '' "name=$CF_ZONE" 'status=active' 'per_page=50')"
  count="$($JQ_BIN -r '.result | length' <<<"$response")"
  [[ "$count" == "1" ]] || die "无法唯一确定区域 $CF_ZONE（找到 $count 个）。可直接填写 CF_ZONE_ID。"
  zone_id="$($JQ_BIN -r '.result[0].id' <<<"$response")"
  [[ -n "$zone_id" && "$zone_id" != "null" ]] || die "Cloudflare 未返回 Zone ID。"
  printf '%s\n' "$zone_id"
}

sync_record() {
  local zone_id="$1" record_type="$2" record_name="$3" address="$4"
  local response count record_id current_content current_ttl current_proxied payload
  response="$(cf_api_request GET "/zones/${zone_id}/dns_records" '' \
    "type=$record_type" "name=$record_name" 'per_page=100')"
  count="$($JQ_BIN -r '.result | length' <<<"$response")"

  # shellcheck disable=SC2016 # $type 等变量由 jq --arg 提供，不由 Bash 展开。
  payload="$($JQ_BIN -cn \
    --arg type "$record_type" --arg name "$record_name" --arg content "$address" \
    --argjson ttl "$TTL" --argjson proxied "$PROXIED" \
    '{type:$type,name:$name,content:$content,ttl:$ttl,proxied:$proxied}')"

  if [[ "$count" == "0" ]]; then
    if [[ "$DRY_RUN" == "true" ]]; then
      info "[预演] 将创建 $record_type $record_name -> $address"
    else
      cf_api_request POST "/zones/${zone_id}/dns_records" "$payload" >/dev/null
      info "已创建 $record_type $record_name -> $address"
    fi
    CREATED_COUNT=$((CREATED_COUNT + 1))
    return 0
  fi
  [[ "$count" == "1" ]] || die "$record_name 存在 $count 条重复的 $record_type 记录，请先在 Cloudflare 中清理。"

  record_id="$($JQ_BIN -r '.result[0].id' <<<"$response")"
  current_content="$($JQ_BIN -r '.result[0].content' <<<"$response")"
  current_ttl="$($JQ_BIN -r '.result[0].ttl' <<<"$response")"
  current_proxied="$($JQ_BIN -r '.result[0].proxied' <<<"$response")"

  if [[ "$FORCE_UPDATE" != "true" && "$current_content" == "$address" && "$current_ttl" == "$TTL" && "$current_proxied" == "$PROXIED" ]]; then
    info "无需更新 $record_type $record_name（$address）"
    UNCHANGED_COUNT=$((UNCHANGED_COUNT + 1))
    return 0
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    info "[预演] 将更新 $record_type $record_name：$current_content -> $address"
  else
    cf_api_request PATCH "/zones/${zone_id}/dns_records/${record_id}" "$payload" >/dev/null
    info "已更新 $record_type $record_name：$current_content -> $address"
  fi
  UPDATED_COUNT=$((UPDATED_COUNT + 1))
}

write_last_run() {
  local ipv4="$1" ipv6="$2" tmp
  mkdir -p "$STATE_DIR"
  tmp="$(mktemp "${STATE_DIR}/last-run.XXXXXX")"
  {
    printf 'timestamp=%s\n' "$(timestamp)"
    printf 'ipv4=%s\n' "$ipv4"
    printf 'ipv6=%s\n' "$ipv6"
    printf 'created=%s\n' "$CREATED_COUNT"
    printf 'updated=%s\n' "$UPDATED_COUNT"
    printf 'unchanged=%s\n' "$UNCHANGED_COUNT"
  } >"$tmp"
  chmod 600 "$tmp"
  mv -f "$tmp" "${STATE_DIR}/last-run"
}

run_sync() {
  require_command "$CURL_BIN"
  require_command "$JQ_BIN"
  require_command "$IP_BIN"
  load_config
  validate_config
  mkdir -p "$STATE_DIR"

  if command -v flock >/dev/null 2>&1; then
    exec 9>"${STATE_DIR}/ddnscg.lock"
    flock -n 9 || die "已有一个 DDNScg 任务正在运行。"
  fi

  local ipv4="" ipv6="" zone_id record
  case "$RECORD_TYPES" in
    auto)
      ipv4="$(detect_ip 4)" || true
      ipv6="$(detect_ip 6)" || true
      [[ -n "$ipv4" || -n "$ipv6" ]] || die "未检测到可用的公网 IPv4 或 IPv6。"
      ;;
    A) ipv4="$(detect_ip 4)" || die "需要更新 A 记录，但未检测到 IPv4。" ;;
    AAAA) ipv6="$(detect_ip 6)" || die "需要更新 AAAA 记录，但未检测到 IPv6。" ;;
    A,AAAA)
      ipv4="$(detect_ip 4)" || die "需要更新 A 记录，但未检测到 IPv4。"
      ipv6="$(detect_ip 6)" || die "需要更新 AAAA 记录，但未检测到 IPv6。"
      ;;
  esac

  [[ -z "$ipv4" ]] || info "检测到 IPv4：$ipv4"
  [[ -z "$ipv6" ]] || info "检测到 IPv6：$ipv6"
  zone_id="$(resolve_zone_id)"

  IFS=',' read -ra records <<<"$RECORD_NAMES"
  for record in "${records[@]}"; do
    record="$(trim "$record")"
    record="${record%.}"
    if [[ -n "$ipv4" ]]; then sync_record "$zone_id" A "$record" "$ipv4"; fi
    if [[ -n "$ipv6" ]]; then sync_record "$zone_id" AAAA "$record" "$ipv6"; fi
  done

  if [[ "$DRY_RUN" != "true" ]]; then write_last_run "$ipv4" "$ipv6"; fi
  info "完成：创建 $CREATED_COUNT，更新 $UPDATED_COUNT，无变化 $UNCHANGED_COUNT。"
}

prompt_value() {
  local prompt="$1" default="$2" secret="${3:-false}" value=""
  if [[ "$secret" == "true" ]]; then
    read -r -s -p "$prompt${default:+ [直接回车保留原值]}: " value
    printf '\n' >&2
  else
    read -r -p "$prompt${default:+ [$default]}: " value
  fi
  [[ -n "$value" ]] || value="$default"
  printf '%s' "$value"
}

configure() {
  [[ "${EUID:-$(id -u)}" == "0" ]] || die "写入 $CONFIG_FILE 需要 root 权限。"
  [[ -t 0 ]] || die "当前不是交互终端。请手动编辑 $CONFIG_FILE。"

  if [[ -r "$CONFIG_FILE" ]]; then load_config; fi
  printf '\n%s 交互配置（Token 不会显示）\n\n' "$DDNSCG_NAME"

  CF_API_TOKEN="$(prompt_value 'Cloudflare API Token' "$CF_API_TOKEN" true)"
  CF_ZONE="$(prompt_value '根域名，例如 example.com' "$CF_ZONE")"
  CF_ZONE_ID="$(prompt_value 'Zone ID（可留空自动查询）' "$CF_ZONE_ID")"
  RECORD_NAMES="$(prompt_value '记录名，多个用逗号分隔' "$RECORD_NAMES")"
  RECORD_TYPES="$(prompt_value '记录类型：auto / A / AAAA / A,AAAA' "$RECORD_TYPES")"
  IPV4_SOURCE="$(prompt_value 'IPv4 来源：auto / external / interface' "$IPV4_SOURCE")"
  IPV6_SOURCE="$(prompt_value 'IPv6 来源：auto / external / interface' "$IPV6_SOURCE")"
  INTERFACE="$(prompt_value '网卡名，auto 表示按默认路由选择' "$INTERFACE")"
  PROXIED="$(prompt_value 'Cloudflare 代理：true / false' "$PROXIED")"
  TTL="$(prompt_value 'TTL：1 为自动' "$TTL")"
  validate_config

  local config_dir tmp
  config_dir="$(dirname "$CONFIG_FILE")"
  install -d -m 700 "$config_dir"
  tmp="$(mktemp "${config_dir}/config.XXXXXX")"
  umask 077
  {
    printf '# DDNScg 配置。此文件包含密钥，权限应保持为 600。\n'
    printf 'CF_API_TOKEN=%s\n' "$CF_API_TOKEN"
    printf 'CF_ZONE_ID=%s\n' "$CF_ZONE_ID"
    printf 'CF_ZONE=%s\n' "$CF_ZONE"
    printf 'RECORD_NAMES=%s\n' "$RECORD_NAMES"
    printf 'RECORD_TYPES=%s\n' "$RECORD_TYPES"
    printf 'IPV4_SOURCE=%s\n' "$IPV4_SOURCE"
    printf 'IPV6_SOURCE=%s\n' "$IPV6_SOURCE"
    printf 'INTERFACE=%s\n' "$INTERFACE"
    printf 'PROXIED=%s\n' "$PROXIED"
    printf 'TTL=%s\n' "$TTL"
  } >"$tmp"
  chmod 600 "$tmp"
  mv -f "$tmp" "$CONFIG_FILE"
  info "配置已保存到 $CONFIG_FILE"

  local answer
  read -r -p '现在执行一次预演测试？[Y/n]: ' answer
  case "${answer,,}" in
    n | no) ;;
    *) DRY_RUN=true; run_sync ;;
  esac
}

show_ip() {
  require_command "$CURL_BIN"
  require_command "$IP_BIN"
  if [[ -r "$CONFIG_FILE" ]]; then load_config; fi
  local ipv4="" ipv6=""
  ipv4="$(detect_ip 4)" || true
  ipv6="$(detect_ip 6)" || true
  printf 'IPv4: %s\n' "${ipv4:-不可用}"
  printf 'IPv6: %s\n' "${ipv6:-不可用}"
}

status() {
  printf '%s %s\n' "$DDNSCG_NAME" "$DDNSCG_VERSION"
  printf '配置文件: %s\n' "$CONFIG_FILE"
  if [[ -r "$CONFIG_FILE" ]]; then
    load_config
    printf '区域: %s\n' "${CF_ZONE:-${CF_ZONE_ID:-未配置}}"
    printf '记录: %s (%s)\n' "${RECORD_NAMES:-未配置}" "$RECORD_TYPES"
    printf '代理/TTL: %s / %s\n' "$PROXIED" "$TTL"
  else
    printf '状态: 尚未配置\n'
  fi
  if [[ -r "${STATE_DIR}/last-run" ]]; then
    printf '\n最近一次成功运行:\n'
    sed 's/^/  /' "${STATE_DIR}/last-run"
  fi
  if command -v systemctl >/dev/null 2>&1; then
    printf '\n定时器:\n'
    systemctl --no-pager list-timers ddnscg.timer 2>/dev/null || true
  fi
}

usage() {
  cat <<'EOF'
DDNScg - Cloudflare DDNS for IPv4 / IPv6 / dual-stack VPS

用法:
  ddnscg run [--dry-run] [--force]  检测地址并同步 DNS
  ddnscg configure                  交互生成配置
  ddnscg ip                         显示检测到的公网地址
  ddnscg status                     显示配置摘要与最近结果
  ddnscg version                    显示版本
  ddnscg help                       显示帮助
EOF
}

main() {
  local command="${1:-help}"
  shift || true
  case "$command" in
    run)
      while (($#)); do
        case "$1" in
          --dry-run) DRY_RUN=true ;;
          --force) FORCE_UPDATE=true ;;
          *) die "未知参数：$1" ;;
        esac
        shift
      done
      run_sync
      ;;
    configure) configure ;;
    ip) show_ip ;;
    status) status ;;
    version | --version | -v) printf '%s %s\n' "$DDNSCG_NAME" "$DDNSCG_VERSION" ;;
    help | --help | -h) usage ;;
    *) usage; die "未知命令：$command" ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
