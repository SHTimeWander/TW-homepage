# 测试服务器自动部署

`.github/workflows/deploy-test.yml` 在 `main` 分支 push 后自动执行，也可在 Actions 页面手动运行（仅允许 `main`）。不使用 GitHub Environments。

工作流使用 Node.js 22、pnpm 10 和锁文件构建 Next.js standalone，再使用现有 Dockerfile 生成 `linux/amd64` 镜像。镜像通过 SSH ProxyJump 上传到测试服务器，由 Docker 启动；服务器不需要访问 GitHub 或镜像仓库，也不需要安装 Node.js。

## GitHub Actions 配置

服务器公共配置放在 **SHTimeWander Organization variables/secrets**，可见范围设为 `selected`，包含 `TW-homepage`。IP、用户名和主机公钥使用 variables，密码使用 secrets。

| 组织 Variable     | 含义                                            |
| ----------------- | ----------------------------------------------- |
| `SSH_JUMP_HOST`   | 跳板机地址                                      |
| `SSH_JUMP_PORT`   | 跳板机 SSH 端口                                 |
| `SSH_JUMP_USER`   | 跳板机 SSH 用户                                 |
| `SSH_TEST_HOST`   | 测试服务器地址                                  |
| `SSH_TEST_PORT`   | 测试服务器 SSH 端口                             |
| `SSH_TEST_USER`   | 测试服务器 SSH 用户                             |
| `SSH_KNOWN_HOSTS` | 两台服务器的 OpenSSH known_hosts 记录，支持多行 |

| 组织 Secret         | 含义                |
| ------------------- | ------------------- |
| `SSH_JUMP_PASSWORD` | 跳板机 SSH 密码     |
| `SSH_TEST_PASSWORD` | 测试服务器 SSH 密码 |

| 仓库 Variable            | 配置值                                                                                              |
| ------------------------ | --------------------------------------------------------------------------------------------------- |
| `APP_NAME`               | `tw-homepage`，容器名和本地镜像名前缀                                                               |
| `APP_DEPLOY_PATH`        | `/opt/tw-homepage`                                                                                  |
| `APP_PORT`               | `3000`，映射到容器的 3000 端口                                                                      |
| `HOMEPAGE_ALLOWED_HOSTS` | 允许访问的主机名及端口，逗号分隔；当前为测试服务器地址的 3000 端口、`localhost:3000,127.0.0.1:3000` |

可选仓库 Secret `APP_ENV_FILE` 可存放 Docker env-file 格式的应用变量（一行一个 `KEY=value`，值不加引号），如 `HOMEPAGE_AUTH_*`、OIDC 或服务 API 密钥。当前应用不需要额外密钥，因此无需创建空 secret。`HOMEPAGE_ALLOWED_HOSTS` 始终由同名仓库 variable 控制；PUID/PGID 固定为 1000。

通过 gh 管理配置（组织级配置需要 `admin:org` 权限）：

```bash
gh auth refresh --scopes admin:org,workflow
gh variable set SSH_JUMP_HOST --org SHTimeWander --visibility selected --repos TW-homepage --body '<跳板机地址>'
gh variable set SSH_KNOWN_HOSTS --org SHTimeWander --visibility selected --repos TW-homepage < known_hosts
# 不传 --body 时交互输入密码，避免密码进入命令历史。
gh secret set SSH_JUMP_PASSWORD --org SHTimeWander --visibility selected --repos TW-homepage
gh secret set SSH_TEST_PASSWORD --org SHTimeWander --visibility selected --repos TW-homepage
gh variable set APP_PORT --repo SHTimeWander/TW-homepage --body '3000'
gh secret set APP_ENV_FILE --repo SHTimeWander/TW-homepage < /secure/path/app.env
```

SSH 严格校验两台服务器的主机公钥。更换服务器/端口时需验证并更新 `SSH_KNOWN_HOSTS`；非 22 端口的条目使用 `[host]:port`。密码只传给 SSH askpass，不写入仓库、SSH 配置或服务器部署包。

## 服务器与运行方式

测试服务器需要 Docker Engine、Bash、gzip、flock，且 SSH 用户有 Docker 和部署目录权限。Docker 服务须启用：

```bash
systemctl enable --now docker
```

默认访问 `http://<测试服务器地址>:3000`，需处于可以访问该内网的网络。允许域名访问时，同时修改 `HOMEPAGE_ALLOWED_HOSTS`，然后重新运行工作流。

应用配置保存在 `/opt/tw-homepage/config`，更新时保留，容器内使用 UID/GID 1000。卷挂载带 `:Z`，兼容 CentOS SELinux enforcing。

同一时间只执行一个部署，服务器还通过 `flock` 防止其他部署进程冲突。新镜像完整上传并加载后，旧容器改名为 `tw-homepage-rollback` 并停止，新容器开始监听原端口，因此更新期间会有短暂中断。120 秒内健康检查通过才删除旧容器及其旧镜像；启动失败、健康检查失败或脚本收到 INT/TERM 时恢复旧容器，工作流仍标记失败。

若服务器断电或进程被强制杀死，可能留下 `tw-homepage-rollback`；脚本会拒绝继续覆盖。确认容器状态后可手动恢复（下述命令会删除失败的新容器）：

```bash
docker ps -a --filter name=tw-homepage
docker rm -f tw-homepage
docker rename tw-homepage-rollback tw-homepage
docker start tw-homepage
```

回滚恢复容器及原环境变量，不恢复持久化配置目录；应用配置需要单独备份。上传的镜像、临时应用环境文件和脚本在部署结束后清理。工作流不会自动打印容器日志，避免应用日志中的密钥进入公开 Actions 日志。

手动触发及查看运行结果：

```bash
gh workflow run deploy-test.yml --ref main --repo SHTimeWander/TW-homepage
gh run list --workflow deploy-test.yml --repo SHTimeWander/TW-homepage
```
