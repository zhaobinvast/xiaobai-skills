#!/usr/bin/env bash
# grafana-loki skill 一键安装脚本
# 用法:
#   bash <(curl -fsSL https://raw.githubusercontent.com/zhaobinvast/xiaobai-skills/main/grafana-loki/install.sh)
# 或本地:
#   ./install.sh
#
# 行为:
#   1. 检查依赖 (git / curl / jq)
#   2. 克隆 xiaobai-skills 仓库到临时目录,把 grafana-loki/ 子目录拷贝到目标(默认 ~/.claude/skills/grafana-loki)
#   3. 交互式让你填 GRAFANA_URL / GRAFANA_TOKEN / LOKI_DS_UID,生成 .env(chmod 600)
#   4. 调一次 labels 接口自检,通过则打印用法提示

set -euo pipefail

REPO_URL="git@github.com:zhaobinvast/xiaobai-skills.git"
REPO_URL_HTTPS="https://github.com/zhaobinvast/xiaobai-skills.git"
SKILL_SUBDIR="grafana-loki"
DEFAULT_DIR="$HOME/.claude/skills/grafana-loki"
DEFAULT_GRAFANA_URL="https://grafana.tripo3d.ai"

c_red()   { printf '\033[31m%s\033[0m' "$*"; }
c_green() { printf '\033[32m%s\033[0m' "$*"; }
c_yellow(){ printf '\033[33m%s\033[0m' "$*"; }
c_bold()  { printf '\033[1m%s\033[0m' "$*"; }

info() { echo "$(c_bold "[grafana-loki]") $*"; }
warn() { echo "$(c_yellow "[!]") $*" >&2; }
die()  { echo "$(c_red "[x]") $*" >&2; exit 1; }

# ---------- 依赖检查 ----------
check_deps() {
  local missing=()
  for bin in git curl jq; do
    command -v "$bin" >/dev/null 2>&1 || missing+=("$bin")
  done
  if (( ${#missing[@]} )); then
    warn "缺少依赖: ${missing[*]}"
    echo "  macOS: brew install ${missing[*]}"
    echo "  Debian/Ubuntu: sudo apt install ${missing[*]}"
    die "请安装后重试"
  fi
}

# ---------- 拉取 skill ----------
fetch_skill() {
  local target="$1"
  if [[ -e "$target" && -n "$(ls -A "$target" 2>/dev/null)" ]]; then
    printf '目标目录已存在且非空: %s,覆盖里面的 skill 文件? [y/N]: ' "$target" >&2
    local ans; IFS= read -r ans
    [[ "$ans" =~ ^[yY]$ ]] || die "已取消"
  fi
  mkdir -p "$target"

  local tmp
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT

  info "正在 clone xiaobai-skills 到临时目录 ..."
  if ! git clone --depth=1 "$REPO_URL" "$tmp/repo" 2>/dev/null; then
    warn "SSH 克隆失败,改用 HTTPS 重试"
    git clone --depth=1 "$REPO_URL_HTTPS" "$tmp/repo"
  fi

  if [[ ! -d "$tmp/repo/$SKILL_SUBDIR" ]]; then
    die "仓库里没找到子目录: $SKILL_SUBDIR"
  fi

  info "把 $SKILL_SUBDIR/ 拷贝到 $target ..."
  # 用 cp -R 而不是 mv,保留可重复执行
  cp -R "$tmp/repo/$SKILL_SUBDIR/." "$target/"

  rm -rf "$tmp"
  trap - EXIT
}

# ---------- 交互式收集 .env ----------
prompt() {
  # prompt VAR_NAME "提示语" "默认值" "是否隐藏输入(1/0)"
  local var="$1" label="$2" def="${3:-}" secret="${4:-0}" val=""
  while true; do
    if [[ -n "$def" ]]; then
      printf '%s [%s]: ' "$label" "$def" >&2
    else
      printf '%s: ' "$label" >&2
    fi
    if [[ "$secret" == "1" ]]; then
      stty -echo 2>/dev/null || true
      IFS= read -r val
      stty echo 2>/dev/null || true
      echo >&2
    else
      IFS= read -r val
    fi
    val="${val:-$def}"
    if [[ -z "$val" ]]; then
      warn "不能为空,请再输入一次"
      continue
    fi
    printf -v "$var" '%s' "$val"
    return 0
  done
}

write_env() {
  local dir="$1" url="$2" token="$3" uid="$4"
  local env_file="$dir/.env"
  if [[ -f "$env_file" ]]; then
    printf '%s 已存在,覆盖? [y/N]: ' "$env_file" >&2
    local ans; IFS= read -r ans
    [[ "$ans" =~ ^[yY]$ ]] || { info "保留原 .env,跳过写入"; return 0; }
  fi
  umask 077
  cat > "$env_file" <<EOF
# 由 install.sh 生成于 $(date '+%Y-%m-%d %H:%M:%S')
GRAFANA_URL=$url
GRAFANA_TOKEN=$token
LOKI_DS_UID=$uid
EOF
  chmod 600 "$env_file"
  info "已写入 $env_file (权限 600)"
}

# ---------- 自检 ----------
self_check() {
  local dir="$1"
  info "调用 labels 接口自检 ..."
  if "$dir/query.sh" labels >/dev/null 2>&1; then
    echo "$(c_green '[✓]') 数据源代理可用"
    return 0
  else
    warn "自检失败,下面是详细错误:"
    "$dir/query.sh" labels || true
    warn "请确认 GRAFANA_URL / GRAFANA_TOKEN / LOKI_DS_UID 是否正确,以及网络能访问 Grafana"
    return 1
  fi
}

# ---------- 收尾提示 ----------
print_usage() {
  local dir="$1"
  cat <<EOF

$(c_bold '安装完成 🎉')

skill 目录: $dir

常用命令:
  # 查 staging 某个 app 最近 1 小时日志
  $dir/query.sh '{namespace="staging", app="vast.tripo.cistern"}'

  # 查最近 30 分钟带 error 的 staging 日志,只输出原文
  $dir/query.sh -s 30m --raw '{namespace="staging"} |= "error"'

  # 列出可用的 label / app
  $dir/query.sh labels
  $dir/query.sh values app

  # 伪 tail(每 5 秒拉一次)
  $dir/query.sh tail '{namespace="staging", app="..."}'

在 Claude Code 里,直接自然语言提问即可,Claude 会自动调起本 skill:
  "查一下 staging 最近 30 分钟的 error 日志"

详细 LogQL 用法见: $dir/SKILL.md
EOF
}

# ---------- main ----------
main() {
  check_deps

  local target_dir="${1:-}"
  if [[ -z "$target_dir" ]]; then
    printf '安装到哪个目录 [%s]: ' "$DEFAULT_DIR" >&2
    IFS= read -r target_dir
    target_dir="${target_dir:-$DEFAULT_DIR}"
  fi
  # 展开 ~
  target_dir="${target_dir/#\~/$HOME}"

  fetch_skill "$target_dir"

  echo
  info "请填写 Grafana / Loki 配置(回车用默认值):"
  local url token uid
  prompt url   "GRAFANA_URL"   "$DEFAULT_GRAFANA_URL" 0
  prompt token "GRAFANA_TOKEN (输入不回显)" ""        1
  prompt uid   "LOKI_DS_UID"   ""                     0

  write_env "$target_dir" "$url" "$token" "$uid"

  echo
  if self_check "$target_dir"; then
    print_usage "$target_dir"
  else
    warn "可以修改 $target_dir/.env 后重新跑: $target_dir/query.sh labels"
    exit 1
  fi
}

main "$@"
