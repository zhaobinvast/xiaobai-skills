#!/usr/bin/env bash
# github-docker-build skill — 通过 GitHub CLI 触发 GitHub Actions 工作流(Docker 构建/代码打包)
# 用法: build.sh <子命令> [选项]

set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SKILL_DIR/.env"

# Load env config
if [[ -f "$ENV_FILE" ]]; then
  set -a; . "$ENV_FILE"; set +a
fi

# Export GITHUB_TOKEN as GH_TOKEN for gh CLI compatibility
if [[ -n "${GITHUB_TOKEN:-}" ]]; then
  export GH_TOKEN="$GITHUB_TOKEN"
fi

# ---------- helpers ----------

resolve_repo() {
  local repo="${REPO_OVERRIDE:-${GITHUB_REPO:-}}"
  if [[ -z "$repo" ]]; then
    echo "错误: 未指定仓库。请在 .env 中设置 GITHUB_REPO 或使用 -R 参数。" >&2
    exit 2
  fi
  echo "$repo"
}

gh_repo_args() {
  local repo; repo=$(resolve_repo)
  echo "-R" "$repo"
}

check_auth() {
  if gh auth status >/dev/null 2>&1; then
    return 0
  fi
  if [[ -n "${GITHUB_TOKEN:-}" ]] || [[ -n "${GH_TOKEN:-}" ]]; then
    return 0
  fi
  echo "未认证。请运行 gh auth login 或在 .env 中设置 GITHUB_TOKEN。" >&2
  exit 4
}

has_tty() {
  [[ -t 1 ]]
}

usage() {
  cat <<'EOF'
Usage:
  build.sh list|ls [options]                       列出可用工作流
  build.sh run <workflow-id|name> [options]         触发 workflow_dispatch
  build.sh status [run-id] [options]                查看运行状态
  build.sh watch <run-id> [options]                 实时监控运行进度
  build.sh logs <run-id> [options]                  查看运行日志
  build.sh cancel <run-id> [options]                取消运行
  build.sh download <run-id> [options]              下载构建产物
  build.sh generate-workflow [options]              生成示例 docker-build 工作流 YAML

Options:
  -R, --repo OWNER/REPO     覆盖默认仓库
  -r, --ref BRANCH/TAG      指定分支或标签(run 子命令)
  -f, --field key=value     传入 workflow 参数(run 子命令,可多次使用)
  -w, --wait                触发后等待完成(run 子命令)
  --failed                  仅显示失败步骤日志(logs 子命令)
  -j, --job JOB_ID          指定 job ID(logs 子命令)
  -n, --name NAME           指定产物名称(download 子命令)
  -D, --dir DIR             产物下载目录(download 子命令,默认 ./artifacts)
  -o, --output FILE         输出到文件(generate-workflow 子命令)
  -a, --all                 包括禁用的工作流(list 子命令)
  --json                    以 JSON 格式输出
  -h, --help                显示本帮助
EOF
}

# Parse shared options that modify global state
parse_shared_opts() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -R|--repo) REPO_OVERRIDE="$2"; shift 2 ;;
      *) break ;;
    esac
  done
  echo "$@"
}

# ---------- subcommands ----------

cmd_list() {
  local repo_args=() all_flag=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -R|--repo) repo_args=(-R "$2"); shift 2 ;;
      -a|--all) all_flag="-a"; shift ;;
      --json) JSON_OUT=1; shift ;;
      -h|--help) echo "Usage: build.sh list [-a] [-R owner/repo] [--json]"; return 0 ;;
      *) shift ;;
    esac
  done
  check_auth
  if [[ "${JSON_OUT:-0}" == "1" ]]; then
    gh workflow list ${all_flag:+"$all_flag"} "${repo_args[@]}" --json name,id,path,state
  else
    gh workflow list ${all_flag:+"$all_flag"} "${repo_args[@]}"
  fi
}

cmd_run() {
  local repo_args=() ref="" fields=() wait_flag=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -R|--repo) repo_args=(-R "$2"); shift 2 ;;
      -r|--ref) ref="$2"; shift 2 ;;
      -f|--field) fields+=(-f "$2"); shift 2 ;;
      -w|--wait) wait_flag=1; shift ;;
      --json) JSON_OUT=1; shift ;;
      -h|--help) echo "Usage: build.sh run <workflow> [-r ref] [-f key=value ...] [-w] [-R owner/repo]"; return 0 ;;
      *) break ;;
    esac
  done
  local workflow="${1:-}"
  if [[ -z "$workflow" ]]; then
    echo "错误: 请指定要触发的工作流名称或 ID。" >&2
    echo "用法: build.sh run <workflow-id|name> [-r ref] [-f key=value ...] [-w]" >&2
    return 2
  fi
  shift

  check_auth

  local ref_args=()
  [[ -n "$ref" ]] && ref_args=(--ref "$ref")

  echo "正在触发工作流: $workflow ..."
  gh workflow run "$workflow" "${repo_args[@]}" "${ref_args[@]}" "${fields[@]}"

  if [[ "$wait_flag" == "1" ]]; then
    echo "等待新 run 出现 ..."
    local before_ts; before_ts=$(date -u +%s)
    local run_id="" elapsed=0
    while true; do
      sleep 3
      elapsed=$(( $(date -u +%s) - before_ts ))
      # Find the newest run for this workflow created after dispatch time
      run_id=$(gh run list --workflow "$workflow" "${repo_args[@]}" --limit 1 --json databaseId,createdAt,status \
        --jq '.[] | select(.createdAt | fromdateiso8601 >= '"$before_ts"') | .databaseId' 2>/dev/null || echo "")
      if [[ -n "$run_id" ]]; then
        echo "Run ID: $run_id"
        break
      fi
      if [[ $elapsed -gt 60 ]]; then
        echo "超时: 60 秒内未检测到新 run。请手动检查。" >&2
        return 5
      fi
    done
    cmd_watch "$run_id" "${repo_args[@]}"
  fi
}

cmd_status() {
  local repo_args=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -R|--repo) repo_args=(-R "$2"); shift 2 ;;
      --json) JSON_OUT=1; shift ;;
      -h|--help) echo "Usage: build.sh status [run-id] [-R owner/repo] [--json]"; return 0 ;;
      *) break ;;
    esac
  done
  check_auth
  local run_id="${1:-}"
  shift || true

  if [[ "${JSON_OUT:-0}" == "1" ]]; then
    if [[ -n "$run_id" ]]; then
      gh run view "$run_id" "${repo_args[@]}" --json name,status,conclusion,databaseId,createdAt,url,headBranch
    else
      gh run list "${repo_args[@]}" --limit 5 --json name,status,conclusion,databaseId,createdAt,url,headBranch
    fi
  else
    if [[ -n "$run_id" ]]; then
      gh run view "$run_id" "${repo_args[@]}"
    else
      gh run list "${repo_args[@]}" --limit 5
    fi
  fi
}

cmd_watch() {
  local repo_args=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -R|--repo) repo_args=(-R "$2"); shift 2 ;;
      -h|--help) echo "Usage: build.sh watch <run-id> [-R owner/repo]"; return 0 ;;
      *) break ;;
    esac
  done
  local run_id="${1:-}"
  if [[ -z "$run_id" ]]; then
    echo "错误: 请指定 run ID。" >&2
    return 2
  fi
  check_auth

  if has_tty; then
    gh run watch "$run_id" "${repo_args[@]}" --exit-status
  else
    # Non-TTY fallback: poll status every 5s
    local prev_status=""
    while true; do
      local status; status=$(gh run view "$run_id" "${repo_args[@]}" --json status,conclusion 2>/dev/null || echo '{"status":"unknown"}')
      local cur_status; cur_status=$(echo "$status" | jq -r '"\(.status) \(.conclusion // "")"' 2>/dev/null || echo "unknown")
      if [[ "$cur_status" != "$prev_status" ]]; then
        echo "[$(date '+%H:%M:%S')] $cur_status"
        prev_status="$cur_status"
      fi
      local st; st=$(echo "$status" | jq -r '.status' 2>/dev/null || echo "")
      if [[ "$st" == "completed" ]]; then
        local conclusion; conclusion=$(echo "$status" | jq -r '.conclusion' 2>/dev/null || echo "")
        if [[ "$conclusion" == "success" ]]; then
          return 0
        else
          return 1
        fi
      fi
      sleep 5
    done
  fi
}

cmd_logs() {
  local repo_args=() failed_flag="" job_id=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -R|--repo) repo_args=(-R "$2"); shift 2 ;;
      --failed) failed_flag="--log-failed"; shift ;;
      -j|--job) job_id="$2"; shift 2 ;;
      -h|--help) echo "Usage: build.sh logs <run-id> [--failed] [-j job-id] [-R owner/repo]"; return 0 ;;
      *) break ;;
    esac
  done
  local run_id="${1:-}"
  if [[ -z "$run_id" ]]; then
    echo "错误: 请指定 run ID。" >&2
    return 2
  fi
  check_auth

  local job_args=()
  [[ -n "$job_id" ]] && job_args=(--job "$job_id")

  if [[ -n "$failed_flag" ]]; then
    gh run view "$run_id" "${repo_args[@]}" --log-failed
  else
    gh run view "$run_id" "${repo_args[@]}" --log "${job_args[@]}"
  fi
}

cmd_cancel() {
  local repo_args=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -R|--repo) repo_args=(-R "$2"); shift 2 ;;
      -h|--help) echo "Usage: build.sh cancel <run-id> [-R owner/repo]"; return 0 ;;
      *) break ;;
    esac
  done
  local run_id="${1:-}"
  if [[ -z "$run_id" ]]; then
    echo "错误: 请指定 run ID。" >&2
    return 2
  fi
  check_auth
  gh run cancel "$run_id" "${repo_args[@]}"
}

cmd_download() {
  local repo_args=() name="" dir="./artifacts"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -R|--repo) repo_args=(-R "$2"); shift 2 ;;
      -n|--name) name="$2"; shift 2 ;;
      -D|--dir) dir="$2"; shift 2 ;;
      -h|--help) echo "Usage: build.sh download <run-id> [-n name] [-D dir] [-R owner/repo]"; return 0 ;;
      *) break ;;
    esac
  done
  local run_id="${1:-}"
  if [[ -z "$run_id" ]]; then
    echo "错误: 请指定 run ID。" >&2
    return 2
  fi
  check_auth

  local name_args=()
  [[ -n "$name" ]] && name_args=(-n "$name")

  mkdir -p "$dir"
  gh run download "$run_id" "${repo_args[@]}" "${name_args[@]}" -D "$dir"
}

cmd_generate_workflow() {
  local output_file=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -o|--output) output_file="$2"; shift 2 ;;
      -h|--help) echo "Usage: build.sh generate-workflow [-o output.yml]"; return 0 ;;
      *) shift ;;
    esac
  done

  local yaml
  yaml=$(cat <<'YAML_EOF'
# Docker Build and Push — 由 github-docker-build skill 生成
# 将此文件放到仓库的 .github/workflows/docker-build.yml 即可使用。
#
# 使用方式:
#   build.sh run docker-build.yml -f image_name=my-app -f tag=v1.2.3 --wait
#
# 或直接在 GitHub Actions 页面手动触发,填写参数即可。

name: Docker Build and Push

on:
  workflow_dispatch:
    inputs:
      image_name:
        description: 'Docker 镜像名称(不含 registry)'
        required: true
        type: string
      tag:
        description: '镜像 tag'
        required: true
        default: 'latest'
        type: string
      dockerfile:
        description: 'Dockerfile 路径'
        required: false
        default: './Dockerfile'
        type: string
      context:
        description: '构建上下文路径'
        required: false
        default: '.'
        type: string
      push:
        description: '构建后推送镜像到仓库'
        required: false
        default: true
        type: boolean
      platforms:
        description: '目标平台(逗号分隔,例如 linux/amd64,linux/arm64)'
        required: false
        default: 'linux/amd64'
        type: string

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Set up QEMU
        uses: docker/setup-qemu-action@v3

      - name: Set up Docker Buildx
        uses: docker/setup-buildx-action@v3

      - name: Login to Docker Hub
        if: inputs.push
        uses: docker/login-action@v3
        with:
          username: ${{ secrets.DOCKER_USERNAME }}
          password: ${{ secrets.DOCKER_PASSWORD }}

      # 如需推送到 GitHub Container Registry,取消下面注释:
      # - name: Login to GHCR
      #   if: inputs.push
      #   uses: docker/login-action@v3
      #   with:
      #     registry: ghcr.io
      #     username: ${{ github.actor }}
      #     password: ${{ secrets.GITHUB_TOKEN }}

      - name: Build and Push
        uses: docker/build-push-action@v5
        with:
          context: ${{ inputs.context }}
          file: ${{ inputs.dockerfile }}
          platforms: ${{ inputs.platforms }}
          push: ${{ inputs.push }}
          tags: ${{ inputs.image_name }}:${{ inputs.tag }}
          cache-from: type=gha
          cache-to: type=gha,mode=max
YAML_EOF
)

  if [[ -n "$output_file" ]]; then
    echo "$yaml" > "$output_file"
    echo "已写入: $output_file"
  else
    echo "$yaml"
  fi
}

# ---------- main ----------

if [[ $# -eq 0 ]]; then
  usage
  exit 0
fi

case "${1:-}" in
  -h|--help) usage ;;
  list|ls)    shift; cmd_list "$@" ;;
  run)        shift; cmd_run "$@" ;;
  status)     shift; cmd_status "$@" ;;
  watch)      shift; cmd_watch "$@" ;;
  logs)       shift; cmd_logs "$@" ;;
  cancel)     shift; cmd_cancel "$@" ;;
  download)   shift; cmd_download "$@" ;;
  generate-workflow) shift; cmd_generate_workflow "$@" ;;
  *)          echo "未知子命令: $1" >&2; usage; exit 2 ;;
esac