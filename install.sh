#!/usr/bin/env bash

set -Eeuo pipefail

readonly REPOSITORY="xinian5216/DDNScg"
REF="${DDNSCG_REF:-main}"
INSTALL_BIN="${DDNSCG_INSTALL_BIN:-/usr/local/bin/ddnscg}"
CONFIG_DIR="${DDNSCG_CONFIG_DIR:-/etc/ddnscg}"
STATE_DIR="${DDNSCG_STATE_DIR:-/var/lib/ddnscg}"
ACTION="install"
NO_CONFIG="false"
PURGE="false"

info() { printf '[DDNScg] %s\n' "$*"; }
warn() { printf '[DDNScg] 警告：%s\n' "$*" >&2; }
die() { printf '[DDNScg] 错误：%s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
用法:
  bash install.sh [--install|--update] [--no-config] [--ref 版本或分支]
  bash install.sh --uninstall [--purge]

选项:
  --install       安装（默认）
  --update        更新程序，保留配置
  --uninstall     卸载程序，默认保留配置与运行记录
  --purge         卸载时同时删除配置与运行记录
  --no-config     不进入交互配置
  --ref REF       从指定分支、标签或提交下载，默认 main
EOF
}

while (($#)); do
  case "$1" in
    --install) ACTION="install" ;;
    --update) ACTION="update"; NO_CONFIG="true" ;;
    --uninstall) ACTION="uninstall" ;;
    --purge) PURGE="true" ;;
    --no-config) NO_CONFIG="true" ;;
    --ref)
      shift
      [[ $# -gt 0 ]] || die "--ref 缺少值。"
      REF="$1"
      ;;
    -h | --help) usage; exit 0 ;;
    *) die "未知参数：$1" ;;
  esac
  shift
done

[[ "${EUID:-$(id -u)}" == "0" ]] || die "请使用 root 运行。"

remove_cron_entry() {
  command -v crontab >/dev/null 2>&1 || return 0
  local current
  current="$(crontab -l 2>/dev/null || true)"
  printf '%s\n' "$current" | sed '/# DDNScg$/d' | crontab -
}

uninstall_ddnscg() {
  if command -v systemctl >/dev/null 2>&1; then
    systemctl disable --now ddnscg.timer >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/ddnscg.service /etc/systemd/system/ddnscg.timer
    systemctl daemon-reload >/dev/null 2>&1 || true
  fi
  remove_cron_entry
  rm -f "$INSTALL_BIN"
  if [[ "$PURGE" == "true" ]]; then
    case "$CONFIG_DIR" in "" | / | /etc | /usr | /var | /root | /home | /tmp) die "拒绝删除范围过大的配置目录：$CONFIG_DIR" ;; esac
    case "$STATE_DIR" in "" | / | /etc | /usr | /var | /root | /home | /tmp) die "拒绝删除范围过大的状态目录：$STATE_DIR" ;; esac
    rm -rf -- "$CONFIG_DIR" "$STATE_DIR"
    info "程序、配置与运行记录已删除。"
  else
    info "程序已卸载；配置仍保留在 $CONFIG_DIR。"
  fi
}

if [[ "$ACTION" == "uninstall" ]]; then
  uninstall_ddnscg
  exit 0
fi

install_dependencies() {
  local missing=()
  command -v curl >/dev/null 2>&1 || missing+=(curl)
  command -v jq >/dev/null 2>&1 || missing+=(jq)
  command -v ip >/dev/null 2>&1 || missing+=(ip)
  command -v flock >/dev/null 2>&1 || missing+=(flock)
  ((${#missing[@]} == 0)) && return 0

  info "正在安装依赖：${missing[*]}"
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends curl ca-certificates jq iproute2 util-linux
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y curl ca-certificates jq iproute util-linux
  elif command -v yum >/dev/null 2>&1; then
    yum install -y curl ca-certificates jq iproute util-linux
  elif command -v apk >/dev/null 2>&1; then
    apk add --no-cache bash curl ca-certificates jq iproute2 util-linux
  elif command -v zypper >/dev/null 2>&1; then
    zypper --non-interactive install curl ca-certificates jq iproute2 util-linux
  else
    die "无法识别包管理器，请先安装 curl、ca-certificates、jq、iproute2、flock。"
  fi
}

download_program() {
  local destination="$1" script_dir local_source url family
  script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P || true)"
  local_source="${script_dir}/ddnscg.sh"
  if [[ -r "$local_source" ]]; then
    cp "$local_source" "$destination"
    return 0
  fi

  local bases=()
  [[ -z "${DDNSCG_DOWNLOAD_BASE:-}" ]] || bases+=("${DDNSCG_DOWNLOAD_BASE%/}")
  # raw.githubusercontent.com 原生提供 IPv6；不经过 github.com 或 api.github.com。
  bases+=(
    "https://raw.githubusercontent.com/${REPOSITORY}/${REF}"
    "https://cdn.jsdelivr.net/gh/${REPOSITORY}@${REF}"
  )

  for url in "${bases[@]}"; do
    for family in auto 6 4; do
      local args=(--fail --silent --show-error --location --connect-timeout 8 --max-time 45 --retry 2)
      [[ "$family" == "auto" ]] || args+=("-$family")
      info "尝试下载 ${url}/ddnscg.sh（网络栈：$family）"
      if curl "${args[@]}" "${url}/ddnscg.sh" --output "$destination"; then
        [[ -s "$destination" ]] && bash -n "$destination" && return 0
      fi
    done
  done
  return 1
}

write_default_config() {
  [[ -e "${CONFIG_DIR}/config" ]] && return 0
  install -d -m 700 "$CONFIG_DIR"
  local tmp
  tmp="$(mktemp "${CONFIG_DIR}/config.XXXXXX")"
  cat >"$tmp" <<'EOF'
# Cloudflare API Token，需要 Zone:DNS:Edit；自动查询 Zone ID 时还需 Zone:Zone:Read。
CF_API_TOKEN=

# 二选一：已知 Zone ID 可只填 CF_ZONE_ID，否则填写根域名 CF_ZONE。
CF_ZONE_ID=
CF_ZONE=example.com

# 完整记录名；多个记录共用同一组地址时用逗号分隔。
RECORD_NAMES=vps.example.com

# auto 会按实际网络栈更新可用记录；也可指定 A、AAAA 或 A,AAAA。
RECORD_TYPES=auto

# auto / external / interface。IPv4 默认优先外部检测，IPv6 默认优先本机路由源地址。
IPV4_SOURCE=auto
IPV6_SOURCE=auto
INTERFACE=auto

# 非 HTTP 服务或非 Cloudflare 支持端口建议保持 false。
PROXIED=false
TTL=1
EOF
  chmod 600 "$tmp"
  mv -f "$tmp" "${CONFIG_DIR}/config"
}

install_systemd_scheduler() {
  cat >/etc/systemd/system/ddnscg.service <<EOF
[Unit]
Description=DDNScg Cloudflare Dynamic DNS updater
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=${INSTALL_BIN} run
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
ReadWritePaths=${STATE_DIR}
LockPersonality=true
RestrictSUIDSGID=true
RestrictNamespaces=true
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX

[Install]
WantedBy=multi-user.target
EOF

  cat >/etc/systemd/system/ddnscg.timer <<'EOF'
[Unit]
Description=Run DDNScg every 5 minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
RandomizedDelaySec=20s
Persistent=true
Unit=ddnscg.service

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
}

install_cron_scheduler() {
  if ! command -v crontab >/dev/null 2>&1; then
    if command -v apt-get >/dev/null 2>&1; then
      DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends cron
    elif command -v dnf >/dev/null 2>&1; then
      dnf install -y cronie
    elif command -v yum >/dev/null 2>&1; then
      yum install -y cronie
    elif command -v apk >/dev/null 2>&1; then
      apk add --no-cache dcron
    fi
  fi
  command -v crontab >/dev/null 2>&1 || die "系统没有 systemd 或 crontab，无法创建定时任务。"
  remove_cron_entry
  (crontab -l 2>/dev/null || true; printf '*/5 * * * * %s run >/dev/null 2>&1 # DDNScg\n' "$INSTALL_BIN") | crontab -
  if command -v rc-service >/dev/null 2>&1; then rc-service crond start >/dev/null 2>&1 || true; fi
  if command -v rc-update >/dev/null 2>&1; then rc-update add crond default >/dev/null 2>&1 || true; fi
}

config_is_ready() {
  [[ -s "${CONFIG_DIR}/config" ]] || return 1
  grep -Eq '^CF_API_TOKEN=.+$' "${CONFIG_DIR}/config" && grep -Eq '^RECORD_NAMES=.+$' "${CONFIG_DIR}/config"
}

install_dependencies
tmp_program="$(mktemp)"
trap 'rm -f "${tmp_program:-}"' EXIT
download_program "$tmp_program" || die "下载失败。纯 IPv6 主机请确认能访问 raw.githubusercontent.com，或用 DDNSCG_DOWNLOAD_BASE 指定自有镜像。"
install -d -m 755 "$(dirname "$INSTALL_BIN")" "$STATE_DIR"
install -m 755 "$tmp_program" "$INSTALL_BIN"
write_default_config

if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
  install_systemd_scheduler
  scheduler="systemd"
else
  scheduler="cron"
fi

if [[ "$NO_CONFIG" != "true" && -t 0 ]]; then
  "$INSTALL_BIN" configure
fi

if config_is_ready; then
  if [[ "$scheduler" == "systemd" ]]; then
    systemctl enable --now ddnscg.timer
  else
    install_cron_scheduler
  fi
  info "安装完成，定时任务已启用。"
else
  [[ "$scheduler" != "cron" ]] || remove_cron_entry
  warn "程序已安装，但配置尚未完成，定时任务未启用。"
  info "请编辑 ${CONFIG_DIR}/config，随后运行：ddnscg run --dry-run"
  [[ "$scheduler" != "systemd" ]] || info "验证后启用：systemctl enable --now ddnscg.timer"
fi

info "版本：$($INSTALL_BIN version)"
