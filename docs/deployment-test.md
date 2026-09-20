# 测试服务器部署

`main` 分支 push 自动触发 `.github/workflows/deploy-test.yml`，也可手动运行。不使用 GitHub Environments。

1. **构建**：使用 Dockerfile 构建应用，将镜像推送至阿里云 ACR，标签为 `main` 和提交 SHA。
2. **部署**：通过 SSH 跳板机上传 Compose 配置，测试服务器从 ACR 拉取对应 SHA 的镜像并执行 `docker compose up -d --wait`。

## Actions 配置

组织 `SHTimeWander` 的 variables/secrets 使用 `selected` 可见范围，已授权 `TW-homepage`：

- Variables：`SSH_JUMP_HOST`、`SSH_JUMP_PORT`、`SSH_JUMP_USER`、`SSH_TEST_HOST`、`SSH_TEST_PORT`、`SSH_TEST_USER`、`SSH_KNOWN_HOSTS`。
- ACR Variables：`ALIYUN_REGISTRY`、`ALIYUN_NAME_SPACE`、`ALIYUN_REGISTRY_USER`。
- Secrets：`SSH_JUMP_PASSWORD`、`SSH_TEST_PASSWORD`、`ALIYUN_REGISTRY_PASSWORD`。
- `SSH_KNOWN_HOSTS` 包含两台服务器的主机公钥，SSH 使用 `StrictHostKeyChecking yes`。

仓库级配置：

| Variable                 | 值                                                |
| ------------------------ | ------------------------------------------------- |
| `APP_IMAGE`              | `tw-homepage`，ACR 镜像仓库名                     |
| `APP_NAME`               | `tw-homepage`                                     |
| `APP_DEPLOY_PATH`        | `/opt/tw-homepage`                                |
| `APP_PORT`               | `3000`                                            |
| `HOMEPAGE_ALLOWED_HOSTS` | `192.168.2.30:3000,localhost:3000,127.0.0.1:3000` |

完整镜像地址由组织配置和仓库配置组合：`${ALIYUN_REGISTRY}/${ALIYUN_NAME_SPACE}/${APP_IMAGE}`。当前为 `crpi-v2udntqq14auxm71.ap-southeast-1.personal.cr.aliyuncs.com/sgp_private/tw-homepage`。

可选仓库 Secret `APP_ENV_FILE` 保存应用环境变量，一行一个 `KEY=value`。未配置时使用空文件。ACR 密码通过标准输入传给 `docker login`；服务器登录凭据在部署结束后清理。

测试服务器需要启用 Docker Engine 和 Docker Compose，并能访问 ACR。应用配置保存在 `/opt/tw-homepage/config`，升级时保留。容器使用 UID/GID 1000，卷带 `:Z` 以支持 SELinux。

内网访问地址：`http://192.168.2.30:3000`。如使用域名，先更新 `HOMEPAGE_ALLOWED_HOSTS` 再重新部署。

```bash
# 修改应用变量
gh variable set APP_PORT --repo SHTimeWander/TW-homepage --body '3000'
# 可选：配置应用密钥
gh secret set APP_ENV_FILE --repo SHTimeWander/TW-homepage < /secure/path/app.env
# 手动部署 main
gh workflow run deploy-test.yml --ref main --repo SHTimeWander/TW-homepage
```
