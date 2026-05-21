# grafana-loki skill

Claude Code skill，通过 Grafana 数据源代理查询 `grafana.tripo3d.ai` 上 Loki 的容器日志。

仓库：`git@github.com:zhaobinvast/xiaobai-skills.git`（本 skill 位于子目录 `grafana-loki/`）

## 安装

### 一键安装（推荐）

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/zhaobinvast/xiaobai-skills/main/grafana-loki/install.sh)
```

脚本会：
1. 检查 `git` / `curl` / `jq` 依赖；
2. 把 `xiaobai-skills` 仓库下的 `grafana-loki/` 子目录内容拷贝到你指定的目录（默认 `~/.claude/skills/grafana-loki`）；
3. 交互式让你填 `GRAFANA_URL` / `GRAFANA_TOKEN` / `LOKI_DS_UID`，生成 `.env`（权限 600）；
4. 调一次 labels 接口自检，通过就打印用法提示。

`GRAFANA_TOKEN` 输入时不回显；其他字段回车走默认值。

### 手动安装

```bash
# 克隆整个 xiaobai-skills 仓库,再把 grafana-loki/ 子目录链接/拷贝出来
git clone git@github.com:zhaobinvast/xiaobai-skills.git /tmp/xiaobai-skills
cp -R /tmp/xiaobai-skills/grafana-loki ~/.claude/skills/grafana-loki
cp ~/.claude/skills/grafana-loki/.env_example ~/.claude/skills/grafana-loki/.env
chmod 600 ~/.claude/skills/grafana-loki/.env
# 然后编辑 .env 填上三个字段
```

`.env` 三个变量来源：

- `GRAFANA_URL`：Grafana 实例地址，例如 `https://grafana.tripo3d.ai`。
- `GRAFANA_TOKEN`：Grafana → Administration → Service accounts 新建 service account，赋予 Loki 数据源查询权限，生成 `glsa_...` token。
- `LOKI_DS_UID`：Grafana → Connections → Data sources 打开对应 Loki 源，URL 里 `/datasources/edit/<UID>` 那一段。

三个变量也可以直接 export 到 shell，`query.sh` 会优先用 `.env`，没有就读环境变量。

> 如果你想克隆到别的位置也行，脚本会从自己所在目录读取 `.env`；克隆后请把 SKILL.md 里所有 `~/.claude/skills/grafana-loki` 替换为你的实际路径，或者通过软链接对齐。

## 依赖

- `jq` — `brew install jq`
- `curl`

## 自查

```bash
~/.claude/skills/grafana-loki/query.sh labels >/dev/null && echo OK
```

返回 `OK` 表示数据源代理可用。若你 clone 到了别的位置，把上面路径换成你的实际安装路径即可。

## 用法

在 Claude Code 中直接用自然语言提问，例如：

```
查一下 staging 最近 30 分钟的 error 日志
```

Claude 会自动调起本 skill 执行 LogQL。命令行用法见 `SKILL.md` 或 `query.sh --help`。

## 安全

- `.env` 里的 token 等同于一把可读全部日志的钥匙，**不要 commit 进任何仓库、不要贴到对话/issue/外部工具**。仓库已经把 `.env` 加入 `.gitignore`（如果没有，请自行加上）。
- 脚本本身不会回显 token；查询时也请避免 `--json` 把 header 类信息打到日志里。
- 如怀疑 token 泄漏：立刻在 Grafana → Administration → Service accounts 撤销旧 token，重新生成一个填回本机 `.env`。
