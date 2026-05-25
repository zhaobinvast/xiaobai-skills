# github-docker-build skill

Claude Code skill，通过 GitHub CLI (`gh`) 触发 GitHub 仓库中的 Actions 工作流，支持 Docker 构建、代码打包等 CI/CD 场景。

仓库：`git@github.com:zhaobinvast/xiaobai-skills.git`（本 skill 位于子目录 `github-docker-build-skill/`）

## 安装

### 一键安装（推荐）

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/zhaobinvast/xiaobai-skills/main/github-docker-build-skill/install.sh)
```

脚本会：
1. 检查 `git` / `curl` / `gh` / `jq` 依赖；
2. 把 `xiaobai-skills` 仓库下的 `github-docker-build-skill/` 子目录内容拷贝到你指定的目录（默认 `~/.claude/skills/github-docker-build`）；
3. 交互式让你填 `GITHUB_REPO` / `GITHUB_TOKEN`，生成 `.env`（权限 600）；
4. 调一次 `build.sh list` 接口自检，通过就打印用法提示。

`GITHUB_TOKEN` 输入时不回显；如果已运行 `gh auth login` 则可留空。

### 手动安装

```bash
# 克隆整个 xiaobai-skills 仓库,再把 github-docker-build-skill/ 子目录拷贝出来
git clone git@github.com:zhaobinvast/xiaobai-skills.git /tmp/xiaobai-skills
cp -R /tmp/xiaobai-skills/github-docker-build-skill ~/.claude/skills/github-docker-build
cp ~/.claude/skills/github-docker-build/.env_example ~/.claude/skills/github-docker-build/.env
chmod 600 ~/.claude/skills/github-docker-build/.env
# 然后编辑 .env 填上 GITHUB_REPO 和可选的 GITHUB_TOKEN
```

`.env` 变量说明：

- `GITHUB_REPO`：默认仓库，格式 `owner/repo`（例如 `zhaobinvast/my-project`）。可通过 `-R` 参数临时覆盖。
- `GITHUB_TOKEN`：GitHub Personal Access Token（可选）。如果已通过 `gh auth login` 认证，可留空。Token 需要 `actions:write` + `actions:read` + `contents:read` 权限。

> 如果你想克隆到别的位置也行，脚本会从自己所在目录读取 `.env`；克隆后请把 SKILL.md 里所有 `~/.claude/skills/github-docker-build` 替换为你的实际路径，或者通过软链接对齐。

## 依赖

- `gh` — GitHub CLI (`brew install gh`)
- `jq` — JSON 处理器 (`brew install jq`)
- `curl`

## 前置配置

### GitHub CLI 认证

```bash
gh auth login
# 选择 GitHub.com → HTTPS → Login with a web browser (推荐)
```

或者使用 Fine-grained Personal Access Token（GitHub → Settings → Developer settings → Personal access tokens），需要：
- `actions:write` — 触发 workflow_dispatch
- `actions:read` — 查看运行状态/日志
- `contents:read` — 私有仓库需要

### 工作流要求

目标仓库中的工作流必须包含 `workflow_dispatch` 触发器：

```yaml
on:
  workflow_dispatch:
    inputs:
      image_name:
        description: 'Docker 镜像名称'
        required: true
        type: string
      # ... 更多参数
```

如果还没有，使用 `build.sh generate-workflow` 生成模板。

## 自查

```bash
~/.claude/skills/github-docker-build/build.sh list >/dev/null && echo OK
```

返回 `OK` 表示 GitHub API 可用。若你 clone 到了别的位置，把上面路径换成你的实际安装路径即可。

## 用法

在 Claude Code 中直接用自然语言提问，例如：

```
帮我触发 docker-build 工作流，构建 my-app 的 latest 镜像
查看最近一次构建状态
下载上次构建的产物
```

Claude 会自动调起本 skill 执行操作。命令行用法见 `SKILL.md` 或 `build.sh --help`。

### 命令行示例

```bash
# 列出可用工作流
build.sh list

# 触发构建
build.sh run docker-build.yml -f image_name=my-app -f tag=v1.2.3 --wait

# 查看状态
build.sh status

# 监控进度
build.sh watch 12345678

# 查看失败日志
build.sh logs 12345678 --failed

# 下载产物
build.sh download 12345678 -n docker-image

# 生成工作流 YAML 模板
build.sh generate-workflow
```

### 子命令速查

| 子命令 | 作用 |
|---|---|
| `list` | 列出可用工作流 |
| `run <workflow>` | 触发 workflow_dispatch |
| `status [run-id]` | 查看运行状态 |
| `watch <run-id>` | 实时监控进度 |
| `logs <run-id>` | 查看运行日志 |
| `cancel <run-id>` | 取消运行 |
| `download <run-id>` | 下载构建产物 |
| `generate-workflow` | 生成 docker-build.yml 模板 |

## 安全

- `.env` 里的 token 等同 GitHub 账号权限，**不要 commit 进任何仓库、不要贴到对话/issue/外部工具**。仓库已经把 `.env` 加入 `.gitignore`。
- 优先推荐 `gh auth login` 而非在 `.env` 中写 token。`gh` CLI 将凭据存在系统密钥链中，更安全。
- 脚本不会回显 token 值。
- 如怀疑 token 泄漏：立刻在 GitHub → Settings → Developer settings → Personal access tokens 撤销旧 token，重新生成一个填回本机 `.env`。