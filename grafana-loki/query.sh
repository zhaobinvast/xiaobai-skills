#!/usr/bin/env bash
# grafana-loki query helper
# 通过 Grafana 数据源代理调用 Loki query_range / labels / values / series 等 API。

set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SKILL_DIR/.env"

# Load env config
if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  set -a; . "$ENV_FILE"; set +a
fi

GRAFANA_URL="${GRAFANA_URL:-}"
GRAFANA_TOKEN="${GRAFANA_TOKEN:-}"
LOKI_DS_UID="${LOKI_DS_UID:-}"

usage() {
  cat <<'EOF'
Usage:
  query.sh [options] '<logql>'                       # query_range (默认)
  query.sh labels [options]                          # 列出所有 label 名
  query.sh values <label> [options]                  # 列出某个 label 的取值
  query.sh series [options] '<matcher>'              # 列出匹配 matcher 的 series
  query.sh tail [options] '<logql>'                  # 持续轮询新日志(伪 tail)

Options:
  -s, --start TIME     起始时间;支持 unix 秒/纳秒、RFC3339,或相对值 30s/15m/2h/3d (默认 1h)
  -e, --end TIME       结束时间(默认 now)
  -l, --limit N        最多返回多少行(默认 100,最大 5000)
  -d, --direction DIR  forward 或 backward(默认 backward,即最新在前)
      --raw            只输出原始日志行(去掉时间戳与标签元数据)
      --jsonl          以 JSONL 输出 {ts, labels, line}(便于管道处理)
      --json           输出 Loki 原始 JSON 响应(默认是格式化的精简文本)
      --tail-interval N tail 模式的轮询间隔秒数(默认 5)
  -h, --help           显示本帮助

环境变量(也可以写在 ~/.claude/skills/grafana-loki/.env):
  GRAFANA_URL    例如 https://grafana.tripo3d.ai
  GRAFANA_TOKEN  Grafana service account token(glsa_...)
  LOKI_DS_UID    Loki 数据源 UID(在 Grafana 中 Connections->Data sources 查看)

示例:
  query.sh '{namespace="staging", app="vast.tripo.cistern"}'
  query.sh -s 30m -l 50 '{namespace="staging"} |= "error"'
  query.sh --raw -s 2h '{namespace="staging", app="vast.tripo.cistern"} | json | level="error"'
  query.sh labels
  query.sh values app
  query.sh tail '{namespace="staging", app="vast.tripo.cistern"}'
EOF
}

# ---------- helpers ----------

# 把人类时间(30m/2h/3d/RFC3339/秒/纳秒)转成 Loki 需要的纳秒 unix 时间戳。
to_ns() {
  local v="$1" now_ns
  now_ns=$(date +%s)000000000
  if [[ "$v" == "now" || -z "$v" ]]; then
    echo "$now_ns"; return
  fi
  # 纯数字: 10 位当秒,13 位当毫秒,19 位当纳秒
  if [[ "$v" =~ ^[0-9]+$ ]]; then
    case ${#v} in
      10) echo "${v}000000000" ;;
      13) echo "${v}000000" ;;
      16) echo "${v}000" ;;
      19) echo "$v" ;;
      *)  echo "$v" ;;
    esac
    return
  fi
  # 相对值: 30s / 15m / 2h / 3d / 1w
  if [[ "$v" =~ ^([0-9]+)([smhdw])$ ]]; then
    local n=${BASH_REMATCH[1]} u=${BASH_REMATCH[2]} mult
    case "$u" in
      s) mult=1 ;;
      m) mult=60 ;;
      h) mult=3600 ;;
      d) mult=86400 ;;
      w) mult=604800 ;;
    esac
    echo $(( now_ns - n * mult * 1000000000 ))
    return
  fi
  # RFC3339 / ISO8601
  local epoch
  if epoch=$(date -j -f "%Y-%m-%dT%H:%M:%S%z" "$v" +%s 2>/dev/null); then
    echo "${epoch}000000000"; return
  fi
  if epoch=$(date -d "$v" +%s 2>/dev/null); then
    echo "${epoch}000000000"; return
  fi
  echo "无法解析时间: $v" >&2; exit 2
}

require_config() {
  local missing=()
  [[ -z "$GRAFANA_URL" ]]   && missing+=("GRAFANA_URL")
  [[ -z "$GRAFANA_TOKEN" ]] && missing+=("GRAFANA_TOKEN")
  [[ -z "$LOKI_DS_UID" ]]   && missing+=("LOKI_DS_UID")
  if (( ${#missing[@]} )); then
    echo "缺少配置: ${missing[*]}" >&2
    echo "请编辑 $ENV_FILE 或导出对应环境变量。" >&2
    exit 2
  fi
}

api() {
  # $1 = path under /loki/api/v1, 其余参数透传给 curl
  local path="$1"; shift
  curl -sS --fail-with-body \
    -H "Authorization: Bearer $GRAFANA_TOKEN" \
    "$@" \
    "$GRAFANA_URL/api/datasources/proxy/uid/$LOKI_DS_UID/loki/api/v1/$path"
}

# 把 query_range 的 streams 结果格式化为 "时间 [labels] 日志行"
format_streams() {
  jq -r '
    def dash(x): if x == null or x == "" then "-" else x end;
    .data.result[]?
    | . as $s
    | .values[]
    | (.[0] | tonumber / 1000000000 | strftime("%Y-%m-%dT%H:%M:%SZ")) as $t
    | ($s.stream) as $l
    | $t
      + " [ns=" + dash($l.namespace)
      + " app=" + dash($l.app)
      + " pod=" + dash($l.pod)
      + " level=" + dash($l.detected_level // $l.level)
      + "] " + (.[1] | rtrimstr("\n"))
  '
}

format_streams_jsonl() {
  jq -c '
    .data.result[]?
    | . as $s
    | .values[]
    | {ts: (.[0] | tonumber / 1000000000), labels: $s.stream, line: (.[1] | rtrimstr("\n"))}
  '
}

format_streams_raw() {
  jq -r '.data.result[]?.values[]?[1] | rtrimstr("\n")'
}

# ---------- subcommands ----------

cmd_query() {
  local query="" start="1h" end="now" limit=100 direction="backward" out="pretty"
  while (( $# )); do
    case "$1" in
      -s|--start) start=$2; shift 2 ;;
      -e|--end) end=$2; shift 2 ;;
      -l|--limit) limit=$2; shift 2 ;;
      -d|--direction) direction=$2; shift 2 ;;
      --raw) out=raw; shift ;;
      --jsonl) out=jsonl; shift ;;
      --json) out=json; shift ;;
      -h|--help) usage; exit 0 ;;
      --) shift; query=${1:-}; shift || true ;;
      -*) echo "未知选项: $1" >&2; exit 2 ;;
      *)  query=$1; shift ;;
    esac
  done
  [[ -z "$query" ]] && { echo "缺少 LogQL 查询表达式" >&2; usage; exit 2; }
  require_config

  local s e resp
  s=$(to_ns "$start")
  e=$(to_ns "$end")

  resp=$(api query_range \
    --data-urlencode "query=$query" \
    --data-urlencode "start=$s" \
    --data-urlencode "end=$e" \
    --data-urlencode "limit=$limit" \
    --data-urlencode "direction=$direction" \
    -G)

  case "$out" in
    json)  echo "$resp" | jq . ;;
    raw)   echo "$resp" | format_streams_raw ;;
    jsonl) echo "$resp" | format_streams_jsonl ;;
    *)     echo "$resp" | format_streams ;;
  esac
}

cmd_labels() {
  local start="1h" end="now"
  while (( $# )); do
    case "$1" in
      -s|--start) start=$2; shift 2 ;;
      -e|--end) end=$2; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) echo "未知选项: $1" >&2; exit 2 ;;
    esac
  done
  require_config
  local s e
  s=$(to_ns "$start"); e=$(to_ns "$end")
  api labels -G --data-urlencode "start=$s" --data-urlencode "end=$e" | jq -r '.data[]?'
}

cmd_values() {
  local label="" start="1h" end="now"
  while (( $# )); do
    case "$1" in
      -s|--start) start=$2; shift 2 ;;
      -e|--end) end=$2; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      -*) echo "未知选项: $1" >&2; exit 2 ;;
      *) label=$1; shift ;;
    esac
  done
  [[ -z "$label" ]] && { echo "缺少 label 名称" >&2; exit 2; }
  require_config
  local s e
  s=$(to_ns "$start"); e=$(to_ns "$end")
  api "label/$label/values" -G --data-urlencode "start=$s" --data-urlencode "end=$e" | jq -r '.data[]?'
}

cmd_series() {
  local matcher="" start="1h" end="now"
  while (( $# )); do
    case "$1" in
      -s|--start) start=$2; shift 2 ;;
      -e|--end) end=$2; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      -*) echo "未知选项: $1" >&2; exit 2 ;;
      *) matcher=$1; shift ;;
    esac
  done
  [[ -z "$matcher" ]] && { echo "缺少 series matcher" >&2; exit 2; }
  require_config
  local s e
  s=$(to_ns "$start"); e=$(to_ns "$end")
  api series -G \
    --data-urlencode "match[]=$matcher" \
    --data-urlencode "start=$s" \
    --data-urlencode "end=$e" \
    | jq .
}

cmd_tail() {
  local query="" limit=100 interval=5
  while (( $# )); do
    case "$1" in
      -l|--limit) limit=$2; shift 2 ;;
      --tail-interval) interval=$2; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      -*) echo "未知选项: $1" >&2; exit 2 ;;
      *) query=$1; shift ;;
    esac
  done
  [[ -z "$query" ]] && { echo "缺少 LogQL 查询表达式" >&2; exit 2; }
  require_config
  local last_ns
  last_ns=$(date +%s)000000000
  echo "tail: $query (interval=${interval}s, Ctrl-C 退出)" >&2
  while true; do
    local now_ns resp newest
    now_ns=$(date +%s)000000000
    resp=$(api query_range \
      --data-urlencode "query=$query" \
      --data-urlencode "start=$last_ns" \
      --data-urlencode "end=$now_ns" \
      --data-urlencode "limit=$limit" \
      --data-urlencode "direction=forward" \
      -G || true)
    echo "$resp" | format_streams || true
    newest=$(echo "$resp" | jq -r '[.data.result[]?.values[]?[0] | tonumber] | (max // 0)')
    if [[ -n "$newest" && "$newest" != "0" ]]; then
      last_ns=$(( newest + 1 ))
    else
      last_ns=$now_ns
    fi
    sleep "$interval"
  done
}

# ---------- dispatch ----------

if [[ $# -eq 0 ]]; then usage; exit 0; fi
case "$1" in
  -h|--help) usage ;;
  labels) shift; cmd_labels "$@" ;;
  values) shift; cmd_values "$@" ;;
  series) shift; cmd_series "$@" ;;
  tail)   shift; cmd_tail   "$@" ;;
  *)      cmd_query "$@" ;;
esac
