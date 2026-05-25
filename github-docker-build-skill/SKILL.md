---
name: github-docker-build
description: Use when 用户需要通过 GitHub Actions 触发 Docker 构建、打包代码、触发 CI/CD 工作流、查看构建进度/日志/产物,或提到 GitHub Actions、workflow dispatch、gh workflow run、docker build CI、代码打包、构建镜像。Covers triggering workflow_dispatch events, monitoring run progress, viewing logs, downloading artifacts, and generating sample docker-build workflow YAML.
---

# github-docker-build

通过 `gh` CLI 触发 GitHub 仓库中的 GitHub Actions 工作流,支持 Docker 构建、代码打包等 CI/CD 场景。
凭据(`.env`)由使用者自行配置在 skill 目录下(`GITHUB_REPO` / `GITHUB_TOKEN`),优先推荐通过 `gh auth login` 认证,**不要把 token 回显到对话、commit、issue 或外部工具**。

## 何时用

- 触发仓库中的 workflow_dispatch 工作流(如 Docker Build and Push)
- 查看可用工作流列表
- 监控工作流运行进度(实时或轮询)
- 查看构建日志,定位失败原因
- 下载构建产物(artifacts)
- 取消正在运行的工作流
- 生成可复用的 docker-build 工作流 YAML 模板

不要用本 skill 做:创建/编辑仓库文件、管理 secrets、操作 Issues/PR、管理仓库设置 —— 那些不在本 skill 范围。

## 入口

只有一个脚本: `~/.claude/skills/github-docker-build/build.sh`。

```bash
# 列出仓库中的可用工作流
~/.claude/skills/github-docker-build/build.sh list

# 触发 docker-build 工作流,传入镜像名和 tag
~/.claude/skills/github-docker-build/build.sh run docker-build.yml \
  -f image_name=my-app -f tag=v1.2.3

# 触发指定分支的工作流,并等待完成
~/.claude/skills/github-docker-build/build.sh run docker-build.yml \
  -r main -f image_name=my-app -f tag=latest --wait

# 查看最近 5 次运行
~/.claude/skills/github-docker-build/build.sh status

# 查看某次运行的详细信息
~/.claude/skills/github-docker-build/build.sh status 12345678

# 实时监控运行进度
~/.claude/skills/github-docker-build/build.sh watch 12345678

# 查看失败步骤的日志
~/.claude/skills/github-docker-build/build.sh logs 12345678 --failed

# 下载构建产物
~/.claude/skills/github-docker-build/build.sh download 12345678 -n docker-image

# 生成示例 docker-build 工作流 YAML
~/.claude/skills/github-docker-build/build.sh generate-workflow

# 生成并保存到文件
~/.claude/skills/github-docker-build/build.sh generate-workflow -o .github/workflows/docker-build.yml
```

## 速查表

| 子命令 | 作用 | 关键选项 |
|---|---|---|
| `list` | 列出仓库可用工作流 | `-a` 含禁用, `--json` JSON 输出 |
| `run <workflow>` | 触发 workflow_dispatch | `-r ref`, `-f key=value`, `-w` 等待完成 |
| `status [run-id]` | 查看运行状态(无参=最近 5 次) | `--json` JSON 输出 |
| `watch <run-id>` | 实时监控进度,完成后返回退出码 | 无 TTY 时降级为轮询 |
| `logs <run-id>` | 查看运行日志 | `--failed` 只看失败步骤, `-j job_id` |
| `cancel <run-id>` | 取消正在运行的工作流 | — |
| `download <run-id>` | 下载构建产物 | `-n name`, `-D dir`(默认 ./artifacts) |
| `generate-workflow` | 输出 docker-build.yml 模板 | `-o file` 写入文件 |

公共选项:

| 选项 | 作用 | 例 |
|---|---|---|
| `-R, --repo OWNER/REPO` | 覆盖默认仓库 | `-R other-org/other-repo` |
| `-h, --help` | 显示帮助 | 每个子命令也支持 |

## 前置条件

1. **安装 GitHub CLI**: `brew install gh` (macOS) 或 `apt install gh` (Linux)
2. **认证**: 运行 `gh auth login`,或在 `.env` 中设置 `GITHUB_TOKEN`
3. **仓库配置**: 在 `.env` 中设置 `GITHUB_REPO=owner/repo`,或每次通过 `-R` 指定
4. **工作流要求**: 目标工作流必须包含 `workflow_dispatch` 触发器,否则无法通过本 skill 触发

## gh auth login 简要指引

```bash
gh auth login
# 选择 GitHub.com
# 选择 HTTPS
# 选择 Login with a web browser (推荐) 或 Paste an authentication token
```

Fine-grained token 最小权限:
- `actions:write` — 触发 workflow_dispatch
- `actions:read` — 查看运行状态/日志
- `contents:read` — 私有仓库需要

## 常见错误

| 现象 | 原因 / 处置 |
|---|---|
| `未认证` | 运行 `gh auth login` 或在 `.env` 中填入 `GITHUB_TOKEN` |
| `未指定仓库` | 在 `.env` 中设置 `GITHUB_REPO` 或用 `-R` 参数 |
| `could not find workflow` | 工作流名称/ID 写错,先用 `build.sh list` 确认 |
| `workflow does not have a workflow_dispatch event trigger` | 目标工作流缺少 `on: workflow_dispatch`,不能手动触发 |
| `denied` / `resource not accessible` | token 权限不足或仓库为私有,token 需要 `actions` + `contents` 权限 |
| `gh: command not found` | 未安装 GitHub CLI:`brew install gh` |
| `--wait` 超时 | 工作流可能未正确触发或延迟超过 60 秒,用 `build.sh status` 手动检查 |
| `watch` 输出乱码 | 非 TTY 环境,脚本已自动降级为轮询模式 |

## 需要生成工作流 YAML?

如果目标仓库还没有 `workflow_dispatch` 类型的 Docker 构建工作流,使用:

```bash
~/.claude/skills/github-docker-build/build.sh generate-workflow -o docker-build.yml
```

生成的 YAML 包含:
- `workflow_dispatch` 触发器(支持 image_name, tag, dockerfile, context, push, platforms 参数)
- `docker/build-push-action` 多平台构建
- `docker/login-action` 登录 Docker Hub / GHCR
- GHA 缓存加速

将生成的文件放到目标仓库的 `.github/workflows/` 目录下并推送即可。使用前需要在仓库 Settings → Secrets and variables → Actions 中配置 `DOCKER_USERNAME` 和 `DOCKER_PASSWORD`(推送到 Docker Hub 时需要)。

## 安全

- `.env` 里的 token 等同 GitHub 账号权限,**不要 commit、不要贴到对话/issue/外部工具**。仓库已经把 `.env` 加入 `.gitignore`。
- 优先推荐 `gh auth login` 而非在 `.env` 中写 token。`gh` CLI 将凭据存在系统密钥链中,更安全。
- 脚本不会回显 token 值;如果使用 `GITHUB_TOKEN` 环境变量,会被导出为 `GH_TOKEN` 供 `gh` CLI 内部使用。
- 如怀疑 token 泄漏:立刻去 GitHub → Settings → Developer settings → Personal access tokens 撤销旧 token,重新生成。

## 调试

- 不确定工作流名称: `build.sh list` 列出所有可用工作流
- 不确定 workflow 接受哪些参数: 在 GitHub 仓库的 Actions 页面手动点开工作流,查看 `workflow_dispatch` 的 inputs 定义
- 想看原始 JSON: 大部分子命令支持 `--json` 输出
- 想知道具体调了什么: `build.sh` 脚本直接调用 `gh` CLI,可单独执行对应 gh 命令调试