#!/usr/bin/env bash
# github-docker-build skill 一键安装脚本
# 用法:
#   bash <(curl -fsSL https://raw.githubusercontent.com/zhaobinvast/xiaobai-skills/main/github-docker-build-skill/install.sh)
# 或本地:
#   ./install.sh
#
# 行为:
#   1. 检查依赖 (git / curl / gh / jq)
#   2. 克隆 xiaobai-skills 仓库到临时目录,把 github-docker-build-skill/ 子目录拷贝到目标(默认 ~/.claude/skills/github-docker-build)
#   3. 交互式让你填 GITHUB_REPO / GITHUB_TOKEN,生成 .env(chmod 600)
#   4. 调一次 build.sh list 自检,通过则打印用法提示

set -euo pipefail

REPO_URL="git@github.com:zhaobinvast/xiaobai-skills.git"
REPO_URL_HTTPS="https://github.com/zhaobinvast/xiaobai-skills.git"
SKILL_SUBDIR="github-docker-build-skill"
DEFAULT_DIR="$HOME/.claude/skills/github-docker-build"

c_red()   { printf '\033[31m%s\033[0m' "$*"; }
c_green() { printf '\033[32m%s\033[0m' "$*"; }
c_yellow(){ printf '\033[33m%s\033[0m' "$*"; }
c_bold()  { printf '\033[1m%s\033[0m' "$*"; }

info() { echo "$(c_bold "[github-docker-build]") $*"; }
warn() { echo "$(c_yellow "[!]") $*" >&2; }
die()  { echo "$(c_red "[x]") $*" >&2; exit 1; }

# ---------- 依赖检查 ----------
check_deps() {
  local missing=()
  for bin in git curl gh jq; do
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
  local dir="$1" repo="$2" token="$3"
  local env_file="$dir/.env"
  if [[ -f "$env_file" ]]; then
    printf '%s 已存在,覆盖? [y/N]: ' "$env_file" >&2
    local ans; IFS= read -r ans
    [[ "$ans" =~ ^[yY]$ ]] || { info "保留原 .env,跳过写入"; return 0; }
  fi
  umask 077
  cat > "$env_file" <<EOF
# 由 install.sh 生成于 $(date '+%Y-%m-%d %H:%M:%S')
GITHUB_REPO=$repo
GITHUB_TOKEN=$token
EOF
  chmod 600 "$env_file"
  info "已写入 $env_file (权限 600)"
}

# ---------- 自检 ----------
self_check() {
  local dir="$1"

  # 先检查认证
  info "检查 GitHub 认证状态 ..."
  if gh auth status >/dev/null 2>&1; then
    echo "$(c_green '[✓]') gh CLI 已认证"
  elif [[ -n "${GITHUB_TOKEN:-}" ]]; then
    echo "$(c_green '[✓]') 使用 GITHUB_TOKEN 认证"
  else
    warn "gh CLI 未认证,且未设置 GITHUB_TOKEN"
    echo "  请运行 gh auth login 或在 .env 中配置 GITHUB_TOKEN"
    return 1
  fi

  info "列出工作流自检 ..."
  if "$dir/build.sh" list >/dev/null 2>&1; then
    echo "$(c_green '[✓]') GitHub Actions API 可用"
    return 0
  else
    warn "自检失败,下面是详细错误:"
    "$dir/build.sh" list || true
    warn "请确认 GITHUB_REPO 正确、认证有效、网络能访问 GitHub"
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
  # 列出可用工作流
  $dir/build.sh list

  # 触发 docker-build 工作流
  $dir/build.sh run docker-build.yml -f image_name=my-app -f tag=latest --wait

  # 查看最近运行状态
  $dir/build.sh status

  # 生成 docker-build 工作流 YAML 模板
  $dir/build.sh generate-workflow

在 Claude Code 里,直接自然语言提问即可,Claude 会自动调起本 skill:
  "帮我触发 docker-build 工作流,构建 my-app 的 latest 镜像"
  "查看最近一次构建状态"
  "下载上次构建的产物"

详细用法见: $dir/SKILL.md
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
  target_dir="${target_dir/#\~/$HOME}"

  fetch_skill "$target_dir"

  echo
  info "请填写 GitHub 配置(回车用默认值):"
  local repo token

  # 检查是否已认证
  if gh auth status >/dev/null 2>&1; then
    echo "  $(c_green '[✓]') 检测到 gh CLI 已认证,GITHUB_TOKEN 可留空"
  fi

  prompt repo  "GITHUB_REPO (格式: owner/repo)" "" 0
  echo "  GITHUB_TOKEN 可留空(如果已运行 gh auth login);输入时不回显"
  prompt token "GITHUB_TOKEN (输入不回显)"         "" 1

  write_env "$target_dir" "$repo" "$token"

  echo
  if self_check "$target_dir"; then
    print_usage "$target_dir"
  else
    warn "可以修改 $target_dir/.env 后重新跑: $target_dir/build.sh list"
    exit 1
  fi
}

main "$@"