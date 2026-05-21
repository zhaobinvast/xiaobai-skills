---
name: grafana-loki
description: Use when 用户需要查询 Grafana 日志、Loki 日志、staging/prod 服务日志、查报错、查请求、tail 实时日志、列举 namespace/app/label,或提到 grafana.tripo3d.ai、LogQL、{namespace=...}、loki query。Covers querying logs by namespace/app/pod, filtering by keyword or LogQL pipeline, listing labels and label values, and pseudo-tailing recent logs.
---

# grafana-loki

通过 Grafana 数据源代理调用 Loki HTTP API 查询 `grafana.tripo3d.ai` 上的容器日志。
凭据(`.env`)由使用者自行配置在 skill 目录下(`GRAFANA_URL` / `GRAFANA_TOKEN` / `LOKI_DS_UID`,具体见 README),**不要把 token 回显到对话、commit、issue 或外部工具**。

## 何时用

- 查看某个 namespace / app / pod 的最近日志(`{namespace="staging", app="..."}`)
- 按关键字过滤(`|= "error"` / `!= "..."` / `|~ "regex"`)
- 解析 JSON 日志后再过滤字段(`| json | level="error"`)
- 列出 Loki 里有哪些 label,以及某个 label 的所有取值
- 持续观察最近写入的日志(伪 tail)

不要用本 skill 做:画图表、设告警、查 Prometheus / Mimir / Tempo —— 那些数据源不在本 skill 范围。

## 入口

只有一个脚本: `~/.claude/skills/grafana-loki/query.sh`。
**默认时间窗 1h、limit 100、direction backward(最新在前)。**

```bash
# 用户给的示范查询
~/.claude/skills/grafana-loki/query.sh '{namespace="staging", app="xx.studio"}'

# 查最近 30 分钟带 error 关键字的 staging 日志,只显示原始日志行
~/.claude/skills/grafana-loki/query.sh -s 30m --raw \
  '{namespace="staging"} |= "error"'

# 取 JSON 解析后 level=error 的日志,JSONL 输出方便管道处理
~/.claude/skills/grafana-loki/query.sh -s 2h --jsonl \
  '{namespace="staging", app="vast.tripo.studio.message"} | json | level="error"'

# 列出可用 label 和某个 label 的取值
~/.claude/skills/grafana-loki/query.sh labels
~/.claude/skills/grafana-loki/query.sh values app
~/.claude/skills/grafana-loki/query.sh values namespace

# 伪 tail(每 5 秒拉一次,从上次最新时间往后)
~/.claude/skills/grafana-loki/query.sh tail '{namespace="staging", app="..."}'
```

## 速查表

| 选项 | 作用 | 例 |
|---|---|---|
| `-s, --start` | 起始时间,支持 `30s/15m/2h/3d/1w`、unix 秒/毫秒/微秒/纳秒、RFC3339 | `-s 1h` |
| `-e, --end` | 结束时间(默认 `now`) | `-e 2026-05-13T20:00:00Z` |
| `-l, --limit` | 行数,最大 5000 | `-l 500` |
| `-d, --direction` | `backward`(默认,最新在前) 或 `forward` | `-d forward` |
| `--raw` | 只输出日志行 | 适合 `\| grep`、`\| jq` |
| `--jsonl` | 每行 `{ts, labels, line}` | 适合二次处理 |
| `--json` | Loki 原始响应 | 调试 / metric 查询必须用 |
| `--tail-interval` | 仅 `tail` 子命令,轮询间隔秒数,默认 5 | `--tail-interval 2` |

子命令:
- `labels` / `values <label>` — 列出 label 名或某个 label 的取值,支持 `-s/-e`
- `series '<matcher>'` — 列出匹配 matcher 的 series(返回 label 组合 JSON),支持 `-s/-e`
- `tail '<logql>'` — 伪 tail:从当前时刻起每 `--tail-interval` 秒拉一次新行(内部强制 `direction=forward`,`-s/-e/-d` 在此模式不可用,只接受 `-l` 和 `--tail-interval`)

## LogQL 速查(最常用的部分)

```
{namespace="staging", app="vast.tripo.cistern"}                  # 选择器:必须用 = != =~ !~
{namespace="staging"} |= "error" != "healthz"                    # 文本过滤,逐级管道
{namespace="staging"} |~ "(?i)timeout|deadline"                  # 正则,前缀 (?i) 忽略大小写
{namespace="staging", app="..."} | json | level="error"          # 解析 JSON,再按字段过滤
{namespace="staging"} | logfmt | duration > 1s                   # logfmt 解析 + 比较
sum by (app) (rate({namespace="staging"} |= "error" [5m]))       # 指标查询(查询条数/秒等),必须配 --json,默认格式化只认 streams
```

注意:
- 选择器**至少要有一个 `=` 或 `=~` 比较**;只用 `!=` 会被 Loki 拒绝。
- 时间窗越长越慢,优先缩到刚够用的范围。
- 指标查询(`rate` / `sum` / `count_over_time` 等)返回的是 matrix/vector,不是 streams,默认 / `--raw` / `--jsonl` 都拿不到结果,**加 `--json` 看原始响应**。

## 常见错误

| 现象 | 原因 / 处置 |
|---|---|
| `parse error ... at least one matcher must contain a non-empty matcher value` | 选择器全用 `!=`,加一个具体的 `namespace=` 或 `app=` |
| 命中行数为 0 | 时间窗太短;或者 label 名称写错,用 `query.sh values app` 先确认值 |
| `maximum of series ... reached` | 查询太宽,加 `namespace=` `app=` 之类的精确选择器 |
| `context deadline exceeded` | 时间窗过大;按需缩短 `-s`,或加更窄的 label |
| 没装 `jq` | 本机需要 `brew install jq`,脚本依赖 jq 做格式化 |
| 想用 token 但不想露在命令行 | 已读取 `.env`,不要再 `--token` 或 `echo $GRAFANA_TOKEN` |

## 安全

- `.env` 里的 token 等同于一把可读全部日志的钥匙,**不要 commit、不要贴到对话/issue/外部工具**。仓库不再附带 `.env`,需要使用者本机自行维护。
- 脚本本身不会回显 token;查询时尽量别带 `--json` 把 header 类信息打到外部日志里。
- 如怀疑 token 泄漏:立刻去 Grafana → Administration → Service accounts 撤销旧 token,重新生成一个填回本机 `.env`。

## 调试

- 想看原始响应: 加 `--json`,直接拿到 Loki 返回。
- 不确定 label/值: 先 `labels` 再 `values <label>` 找正确写法。
- 想知道接口怎么拼: `query.sh --help`,或直接读 `~/.claude/skills/grafana-loki/query.sh`。
