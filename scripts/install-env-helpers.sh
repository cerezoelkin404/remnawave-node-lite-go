# shellcheck shell=bash
# Shared env/secret helpers for install-node.sh and install-node-alpine.sh
# Expects: NODE_ENV, SECRET_FILE, DRY_RUN

resolve_release_tag() {
  local repo="${1:?}"
  local fallback="${2:?}"
  local tag=""
  if command -v curl >/dev/null 2>&1; then
    tag="$(curl -fsSL -H "Accept: application/vnd.github+json" \
      "https://api.github.com/repos/${repo}/releases/latest" 2>/dev/null \
      | tr -d '\n' \
      | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
      | head -n1)" || true
    # Fork 上没有 GitHub Release（Actions 未启用）时退回最新 tag，
    # 这样仍然能命中仓库内自托管的 dist/ 资产。
    if [ -z "$tag" ]; then
      tag="$(curl -fsSL -H "Accept: application/vnd.github+json" \
        "https://api.github.com/repos/${repo}/tags" 2>/dev/null \
        | grep -o '"name"[[:space:]]*:[[:space:]]*"[^"]*"' \
        | head -n1 \
        | sed -e 's/.*"\([^"]*\)".*/\1/')" || true
    fi
  fi
  if [ -n "$tag" ]; then
    printf '%s' "$tag"
  else
    printf '%s' "$fallback"
  fi
}

# ---------------------------------------------------------------------------
# 二进制资产下载
#
# 候选顺序（任一命中即用）：
#   1. ${RNL_ASSET_BASE}/<file>                       显式自托管（内网镜像 / file:// 目录）
#   2. github.com/<repo>/releases/download/<tag>/<file>  GitHub Release 资产
#   3. raw.githubusercontent.com/<repo>/<tag>/dist/<file>  仓库内自托管 dist（tag）
#   4. raw.githubusercontent.com/<repo>/main/dist/<file>   仓库内自托管 dist（main 兜底）
#
# 第 3/4 项让 fork 在没有 Release、也没有启用 Actions 的情况下依然可以安装，
# 且全程不会回落到 ike-sh 上游仓库。
# ---------------------------------------------------------------------------

asset_url_candidates() {
  local repo="${1:?}"
  local tag="${2:?}"
  local file="${3:?}"
  if [ -n "${RNL_ASSET_BASE:-}" ]; then
    printf '%s\n' "${RNL_ASSET_BASE%/}/${file}"
  fi
  printf '%s\n' "https://github.com/${repo}/releases/download/${tag}/${file}"
  printf '%s\n' "https://raw.githubusercontent.com/${repo}/${tag}/dist/${file}"
  printf '%s\n' "https://raw.githubusercontent.com/${repo}/main/dist/${file}"
}

# 打印本次会尝试的下载地址（失败时给用户看，便于排查）
print_asset_candidates() {
  local repo="${1:?}"
  local tag="${2:?}"
  local file="${3:?}"
  echo "尝试过的下载地址：" >&2
  asset_url_candidates "$repo" "$tag" "$file" | sed 's/^/  - /' >&2
}

_asset_fetch_one() {
  local url="$1"
  local out="$2"
  case "$url" in
    file://*) cp "${url#file://}" "$out" 2>/dev/null ;;
    /*) cp "$url" "$out" 2>/dev/null ;;
    *) curl -fsSL --connect-timeout 10 --retry 2 --retry-delay 1 "$url" -o "$out" 2>/dev/null ;;
  esac
}

# 下载 dist/ 或 Release 资产到 <out>。额外 URL（例如旧二进制自报的地址）优先尝试。
# 成功时把命中的 URL 打到 stdout。
fetch_asset() {
  local repo="${1:?}"
  local tag="${2:?}"
  local file="${3:?}"
  local out="${4:?}"
  shift 4
  local -a urls=("$@")
  local url
  while IFS= read -r url; do
    urls+=("$url")
  done < <(asset_url_candidates "$repo" "$tag" "$file")

  for url in "${urls[@]}"; do
    [ -n "$url" ] || continue
    if _asset_fetch_one "$url" "$out"; then
      printf '%s' "$url"
      return 0
    fi
  done
  return 1
}

# 若同目录存在 SHA256SUMS 则校验；缺失时静默跳过（老版本资产没有校验文件）。
verify_asset_checksum() {
  local url="$1"
  local path="$2"
  local file="$3"
  local base sums want got
  base="${url%/*}"
  case "$base" in
    /*|file://*) sums="$(cat "${base#file://}/SHA256SUMS" 2>/dev/null || true)" ;;
    *) sums="$(curl -fsSL --connect-timeout 10 "${base}/SHA256SUMS" 2>/dev/null || true)" ;;
  esac
  [ -n "$sums" ] || return 0
  want="$(printf '%s\n' "$sums" | awk -v f="$file" '$2 == f || $2 == "*" f { print $1; exit }')"
  [ -n "$want" ] || return 0
  got="$(sha256sum "$path" | awk '{ print $1 }')"
  if [ "$want" != "$got" ]; then
    echo "SHA256 校验失败：${file}（期望 ${want}，实际 ${got}）" >&2
    return 1
  fi
  echo "SHA256 校验通过：${file}"
}

resolve_install_tag() {
  local repo="${1:?}"
  local fallback="${2:?}"
  if [ -n "${RNL_TAG:-}" ]; then
    printf '%s' "$RNL_TAG"
  else
    resolve_release_tag "$repo" "$fallback"
  fi
}

secret_from_env_file() {
  if [ ! -f "$NODE_ENV" ]; then
    return 1
  fi
  local line val
  line="$(grep -E '^[[:space:]]*SECRET_KEY=' "$NODE_ENV" 2>/dev/null | head -n 1 || true)"
  [ -n "$line" ] || return 1
  val="${line#SECRET_KEY=}"
  val="$(printf '%s' "$val" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//")"
  [ -n "$val" ]
}

secret_configured() {
  if secret_from_env_file; then
    return 0
  fi
  [ -f "$SECRET_FILE" ] && [ -s "$SECRET_FILE" ]
}

write_secret_to_env() {
  local value="$1"
  if [ -z "$value" ]; then
    return 0
  fi
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "[dry-run] 写入 ${NODE_ENV} SECRET_KEY=..."
    return 0
  fi
  if [ ! -f "$NODE_ENV" ]; then
    echo "找不到 ${NODE_ENV}，请先创建环境配置。" >&2
    exit 1
  fi
  local tmp
  tmp="$(mktemp)"
  grep -v '^SECRET_KEY=' "$NODE_ENV" | grep -v '^SECRET_KEY_FILE=' >"$tmp" || true
  {
    cat "$tmp"
    printf 'SECRET_KEY="%s"\n' "$value"
  } >"$NODE_ENV"
  rm -f "$tmp"
  chmod 600 "$NODE_ENV"
  echo "已写入 SECRET_KEY 到 ${NODE_ENV}"
}

enable_secret_key_file() {
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "[dry-run] 启用 ${NODE_ENV} SECRET_KEY_FILE=${SECRET_FILE}"
    return 0
  fi
  if [ ! -f "$NODE_ENV" ]; then
    return 0
  fi
  local tmp
  tmp="$(mktemp)"
  grep -v '^SECRET_KEY=' "$NODE_ENV" | grep -v '^SECRET_KEY_FILE=' | grep -v '^# SECRET_KEY_FILE=' >"$tmp" || true
  {
    cat "$tmp"
    echo "SECRET_KEY="
    echo "SECRET_KEY_FILE=${SECRET_FILE}"
  } >"$NODE_ENV"
  rm -f "$tmp"
  chmod 600 "$NODE_ENV"
}

write_secret_from_source() {
  local src="$1"
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "[dry-run] 写入 ${SECRET_FILE} <- ${src}"
    return 0
  fi
  install -m 0600 -D /dev/null "$SECRET_FILE"
  if [ "$src" = "-" ]; then
    cat >"$SECRET_FILE"
  else
    install -m 0600 "$src" "$SECRET_FILE"
  fi
  enable_secret_key_file
}

write_secret_from_env() {
  local value="${SECRET_KEY:-}"
  if [ -z "$value" ]; then
    return 0
  fi
  write_secret_to_env "$value"
}

ensure_internal_socket_in_env() {
  if [ ! -f "$NODE_ENV" ] || [ "$DRY_RUN" -eq 1 ]; then
    return 0
  fi
  if grep -q '^INTERNAL_SOCKET_PATH=.' "$NODE_ENV" 2>/dev/null; then
    return 0
  fi
  if grep -q '^INTERNAL_SOCKET_PATH=' "$NODE_ENV" 2>/dev/null; then
    sed -i 's|^INTERNAL_SOCKET_PATH=.*|INTERNAL_SOCKET_PATH=/run/remnanode/internal.sock|' "$NODE_ENV"
  else
    echo 'INTERNAL_SOCKET_PATH=/run/remnanode/internal.sock' >>"$NODE_ENV"
  fi
}

prompt_secret_key() {
  if secret_configured; then
    return 0
  fi

  write_secret_from_env
  if secret_configured; then
    return 0
  fi

  if [ -n "$SECRET_FILE_ARG" ]; then
    return 0
  fi

  if [ "$YES" -eq 1 ] || [ "$DRY_RUN" -eq 1 ]; then
    return 0
  fi

  echo
  echo "请粘贴 Panel 节点页下发的 Secret Key（整段 base64，粘贴后按 Enter）："
  echo "（节点已启用时，装完后约 10s 内 Panel 将自动上线）"
  local secret=""
  if [ -t 0 ]; then
    read -r secret
  elif [ -r /dev/tty ]; then
    read -r secret </dev/tty
  fi

  if [ -n "$secret" ]; then
    write_secret_to_env "$secret"
    return 0
  fi

  print_env_config_hint "${RESTART_CMD:-systemctl restart remnawave-node}"
}

cleanup_runtime() {
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "[dry-run] cleanup runtime sockets and rw-core"
    return 0
  fi
  pkill -x rw-core 2>/dev/null || pkill -f '/usr/local/bin/rw-core' 2>/dev/null || true
  rm -rf /run/remnanode 2>/dev/null || true
  rm -f /run/remnawave-internal-*.sock 2>/dev/null || true
}

print_pre_install_panel_hint() {
  echo
  echo "━━━━━━━━ Panel 接入提示 ━━━━━━━━"
  echo "  推荐顺序："
  echo "    1) Panel 创建节点，复制 Secret Key"
  echo "    2) 完成本脚本安装并粘贴 Secret Key"
  echo "    3) 看到 OK: TCP 已监听 后，在 Panel 启用节点"
  echo
  echo "  节点已启用时：装完后 Panel 每 10s 健康检查，约 10s 内自动上线。"
  echo "  若超过 30s 仍离线：检查防火墙，或 Panel 禁用→启用一次。"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

print_panel_address_hint() {
  local port="$1"
  local pub_ip=""
  pub_ip="$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1 || true)"

  echo
  echo "━━━━━━━━ Panel 对接（必读）━━━━━━━━"
  echo "  节点端口: ${port}"
  if [ -n "$pub_ip" ]; then
    echo "  本机公网 IP（参考）: ${pub_ip}"
  fi
  echo "  Panel 在其它服务器：地址填 Panel 能 ping/tcp 通的本机 IP"
  echo "  Panel 服务器上自测:"
  echo "    nc -zv -w 5 <节点IP> ${port}"
  echo
  echo "  节点已就绪。Panel 通常 10s 内自动上线。"
  echo "  若仍离线：检查防火墙 / Secret Key，或 Panel 禁用→启用一次。"
  echo "  首次成功启用后，服务器 reboot 将自动恢复。"
}

wait_for_service_stable() {
  local port="$1"
  local max_wait="${2:-30}"
  local i=0

  if [ "$DRY_RUN" -eq 1 ]; then
    return 0
  fi

  while [ "$i" -lt "$max_wait" ]; do
    if ss -tln 2>/dev/null | grep -q ":${port} "; then
      if command -v systemctl >/dev/null 2>&1; then
        if systemctl is-active --quiet remnawave-node.service 2>/dev/null; then
          return 0
        fi
      elif command -v rc-service >/dev/null 2>&1; then
        if rc-service remnawave-node status 2>/dev/null | grep -qi 'started'; then
          return 0
        fi
      else
        return 0
      fi
    fi
    sleep 1
    i=$((i + 1))
  done
  return 1
}

verify_service_listening() {
  local port="$1"
  if [ "$DRY_RUN" -eq 1 ]; then
    return 0
  fi
  if ! wait_for_service_stable "$port" 30; then
    echo "错误: :${port} 在 30s 内未就绪，请检查服务状态（systemctl/rc-service remnawave-node）" >&2
    return 1
  fi
  if ss -tln 2>/dev/null | grep -q ":${port} "; then
    echo "OK: TCP :${port} 已监听"
    ss -tlnp 2>/dev/null | grep ":${port} " | head -n1 || true
    return 0
  fi
  echo "错误: :${port} 未监听，请检查服务状态（systemctl/rc-service remnawave-node）" >&2
  return 1
}

print_env_config_hint() {
  local restart_cmd="$1"
  echo
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo " 配置节点（编辑 node.env，变量名同官方 environment）"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo
  echo "编辑 ${NODE_ENV}，修改两项即可："
  echo "  NODE_PORT=2222          # 与 Panel 添加节点时的端口一致"
  echo '  SECRET_KEY="eyJ..."     # Panel 下发的 Secret Key（整段粘贴）'
  echo
  echo "完成后执行：${restart_cmd}"
  echo
  echo "也可安装时传入："
  echo "  SECRET_KEY='eyJ...' NODE_PORT=8443 bash install-*.sh --yes"
}

read_env_value() {
  local key="$1" file="$2"
  local line val
  [ -f "$file" ] || return 0
  line="$(grep -E "^[[:space:]]*${key}=" "$file" 2>/dev/null | head -n 1 || true)"
  [ -n "$line" ] || return 0
  val="${line#*=}"
  val="$(printf '%s' "$val" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//")"
  [ -n "$val" ] || return 0
  printf '%s' "$val"
}

install_geo_extra_files() {
  local geo_dir="${GEO_DIR:-/usr/local/share/xray}"
  local env_file="${NODE_ENV:-/etc/remnanode/node.env}"
  local geo_zapret ip_zapret
  if [ -z "${GEO_ZAPRET_FILE:-}" ]; then
    geo_zapret="$(read_env_value GEO_ZAPRET_FILE "$env_file")"
  else
    geo_zapret="$GEO_ZAPRET_FILE"
  fi
  if [ -z "${IP_ZAPRET_FILE:-}" ]; then
    ip_zapret="$(read_env_value IP_ZAPRET_FILE "$env_file")"
  else
    ip_zapret="$IP_ZAPRET_FILE"
  fi

  local copied=0
  install_one_geo_extra() {
    local src="$1" dest_name="$2"
    [ -n "$src" ] || return 0
    [ -f "$src" ] || { echo "警告：找不到 ${src}（跳过 ${dest_name}）" >&2; return 0; }
    if [ "$DRY_RUN" -eq 1 ]; then
      echo "[dry-run] 复制 ${src} -> ${geo_dir}/${dest_name}"
      return 0
    fi
    mkdir -p "$geo_dir"
    cp -f "$src" "${geo_dir}/${dest_name}"
    chmod 0644 "${geo_dir}/${dest_name}"
    echo "已安装 ${dest_name} -> ${geo_dir}/${dest_name}"
    copied=1
  }

  install_one_geo_extra "$geo_zapret" "geo-zapret.dat"
  install_one_geo_extra "$ip_zapret" "ip-zapret.dat"

  if [ "$copied" -eq 0 ]; then
    return 0
  fi
  echo "提示：Xray 路由使用 ext:geo-zapret.dat:zapret / ext:ip-zapret.dat:zapret 引用上述文件。"
}

render_env_template() {
  local port="$1"
  local low_mem="$2"
  local installer="$3"
  cat <<EOF
# Remnawave Node Lite — 由 ${installer} 生成
# 借鉴官方 environment 变量名，仅需修改下面两项：

NODE_PORT=${port}
SECRET_KEY=

# 可选：密钥极长时可改用独立文件（取消下行注释并清空 SECRET_KEY）
# SECRET_KEY_FILE=${SECRET_FILE}

XRAY_BIN=/usr/local/bin/rw-core
GEO_DIR=/usr/local/share/xray
LOG_DIR=${LOG_DIR}
INTERNAL_SOCKET_PATH=/run/remnanode/internal.sock
INTERNAL_REST_TOKEN=
LOW_MEMORY=${low_mem}
BODY_LIMIT_MB=

# 可选：自定义 rw-core 下载 URL（对齐官方 CUSTOM_CORE_URL）
# CUSTOM_CORE_URL=https://example.com/xray-custom

# 可选：zapret 规则文件（复制到 GEO_DIR，供 ext:geo-zapret.dat 引用）
# GEO_ZAPRET_FILE=/path/to/geo-zapret.dat
# IP_ZAPRET_FILE=/path/to/ip-zapret.dat
EOF
}
