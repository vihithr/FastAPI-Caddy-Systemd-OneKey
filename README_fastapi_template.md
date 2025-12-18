## FastAPI + Caddy + Systemd 一键部署模板

本模板基于现有 `deploy.sh` 的部署经验，提炼出一个**与业务无关的通用部署脚本**，用于在主流 Linux 服务器上快速部署 FastAPI 应用，并通过 Caddy 提供反向代理与 HTTPS。

### 目录结构

- `tools/fastapi_deploy.sh`：通用一键部署脚本。
- `tools/FastAPIApp.service`：Systemd 服务模板。
- `tools/Caddyfile.fastapi`：Caddyfile 域名模式模板。

这些文件在代码同步后会被复制到 `/opt/fastapi_app/tools`（默认 `PROJECT_NAME=fastapi_app`）。

### 快速开始

#### 1. 准备你的 FastAPI 项目

- 入口模块建议为 `app.main:app`（可在脚本顶部修改 `APP_MODULE`）。
- 如果项目有依赖，请在项目根目录提供 `requirements.txt`。
  - 若不存在，脚本会自动安装最小依赖：`fastapi` 与 `uvicorn[standard]`。

#### 2. 一键安装（本地目录）

在项目根目录运行：

```bash
bash tools/fastapi_deploy.sh install --from-local --ip
```

- 默认安装目录：`/opt/fastapi_app`
- 默认端口：`8000`
- 默认会创建系统用户：`fastapi`（不可登录）

#### 3. 从 GitHub 部署

```bash
curl -fsSL <YOUR_RAW_URL>/tools/fastapi_deploy.sh | \
  bash -s -- install \
  --from-github https://github.com/your/repo.git \
  --branch main \
  --domain example.com
```

参数说明：

- `--from-github <repo>`：指定 Git 仓库地址。
- `--branch <branch>`：指定分支，默认 `main`。
- `--domain <domain>`：使用域名 + HTTPS 模式（Caddy 自动签发证书）。
- `--ip`：使用 IP/HTTP 模式（无需域名与证书）。

### 脚本行为概览

1. **依赖检查**
   - 检查并要求：`python3 (>=3.8)`、`python3-venv`、`curl`。
   - 按需安装：`git`（从 GitHub 部署时）、`unzip`（解压 zip 时）。

2. **系统用户与目录**
   - 创建系统用户/组：`fastapi:fastapi`。
   - 安装目录：`/opt/fastapi_app`。

3. **代码同步**
   - 支持三种来源：`local / github / archive`。
   - 排除：`.git`、`__pycache__`、`*.pyc`、`venv`。

4. **虚拟环境与依赖**
   - 在安装目录下创建 `venv`。
   - 优先使用 `requirements.txt` 安装依赖。
   - 否则安装 FastAPI 最小依赖集。

5. **.env 配置**
   - 在安装目录下创建 `.env`（如不存在）。
   - 自动生成 `SECRET_KEY`，并设置 `APP_ENV=production`。

6. **Systemd 服务**

   - 使用 `tools/FastAPIApp.service` 模板生成：
     - `/etc/systemd/system/fastapi_app.service`
   - 默认启动命令：
     - `/opt/fastapi_app/venv/bin/uvicorn app.main:app --host 0.0.0.0 --port 8000`

7. **Caddy + 反向代理**

   - Caddy 二进制集中安装到：`/opt/fastapi_app/caddy`。
   - Systemd 服务：`caddy.service`。
   - 配置文件：`/etc/caddy/Caddyfile`。
   - IP 模式：
     - 监听 `:80`，反向代理到 `127.0.0.1:8000`。
   - 域名模式：
     - 使用 `tools/Caddyfile.fastapi` 模板，站点为 `your-domain`，由 Caddy 自动签发证书。

8. **Bash 别名**

   - 安装完成后，会在当前用户的 `~/.bashrc` 中添加：
     - `alias fastapi_deploy="bash /opt/fastapi_app/tools/fastapi_deploy.sh"`
   - 重新登录或执行 `source ~/.bashrc` 以生效。

### 常用命令

- 查看服务状态：

```bash
sudo systemctl status fastapi_app.service
```

- 实时查看日志：

```bash
sudo journalctl -u fastapi_app.service -f
```

- 管理 Caddy：

```bash
sudo systemctl status caddy
sudo journalctl -u caddy -f
```

### 卸载

```bash
sudo bash tools/fastapi_deploy.sh uninstall --force
```

卸载行为：

- 停止并禁用 `fastapi_app.service`。
- 删除 `/etc/systemd/system/fastapi_app.service`。
- 删除安装目录 `/opt/fastapi_app`。
- 不强制删除全局 Caddy 服务与配置（如需，可手动清理）。


