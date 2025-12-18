## FastAPI + Caddy + Systemd 一键部署模板

一个**开箱即用**的 FastAPI 部署模板，包含：

- **一键部署脚本**：自动完成代码同步、虚拟环境、依赖安装、Systemd 服务与 Caddy 反向代理 / HTTPS 配置。
- **Systemd 模板**：将 FastAPI 进程以系统服务的方式长期稳定运行。
- **Caddy 模板**：支持域名 + HTTPS（自动申请证书）或纯 IP / HTTP 访问。

你可以：

- 把整个仓库克隆到本地，作为自己项目的 **部署工具仓库** 使用；
- 或者把 `tools/` 目录复制到任意 FastAPI 项目中，直接本地执行部署；
- 也可以通过 GitHub Raw 链接实现真正意义上的 **一条命令远程部署**。

---

## 仓库结构

- `tools/fastapi_deploy.sh`：主部署脚本（与业务无关，可复用）。
- `tools/FastAPIApp.service`：FastAPI 应用的 Systemd 服务模板。
- `tools/Caddyfile.fastapi`：Caddy 反向代理（域名模式）模板。
- `tools/README_fastapi_template.md`：脚本的技术说明文档（比本 README 更偏「参考手册」）。

部署完成后，这些文件会被复制到服务器上：

- 安装目录（默认）：`/opt/fastapi_app`
- 工具目录：`/opt/fastapi_app/tools`

---

## 运行环境要求

- 一台 Linux 服务器（常见的 Ubuntu / Debian / CentOS / Rocky / Alma 等均可）。
- 能以 `root` 或具备 `sudo` 权限的用户连接服务器。
- 已安装：
  - `python3`（>= 3.8）
  - 建议系统包：`python3-venv`
  - 脚本会按需尝试安装：`curl`、`git`（从 GitHub 拉代码时）、`unzip`（解压 zip 压缩包时）。

---

## 使用方式一：作为你自己项目的 `tools/` 目录

### 1. 复制到现有 FastAPI 项目

假设你的项目结构大致如下：

```bash
your-fastapi-project/
  app/
    main.py         # FastAPI 入口（建议为 app.main:app）
  requirements.txt
  tools/
    fastapi_deploy.sh
    FastAPIApp.service
    Caddyfile.fastapi
```

> 如果你当前只在 `tools/` 目录下工作，可以把这里的文件拷贝到你的项目根目录的 `tools/` 子目录中。

### 2. 检查入口模块与依赖

- 入口模块默认为：`app.main:app`  
  - 如你的入口不同（例如 `src.main:app`），请修改 `tools/fastapi_deploy.sh` 顶部的：
    - `APP_MODULE="app.main:app"`
- 请在项目根目录提供 `requirements.txt`：
  - 如果没有，脚本会自动安装最小依赖：`fastapi` 与 `uvicorn[standard]`。

### 3. 本地目录一键部署（IP / HTTP 模式）

在**项目根目录**执行：

```bash
bash tools/fastapi_deploy.sh install --from-local --ip
```

默认行为：

- 安装目录：`/opt/fastapi_app`
- 监听端口：`8000`
- 创建系统用户：`fastapi:fastapi`（不可登录）
- 使用 Caddy 在 `:80` 上做代理（仅 HTTP）

部署完成后，可以通过：

- `http://<服务器 IP>/` 访问你的 FastAPI 应用；
- `sudo systemctl status fastapi_app.service` 查看服务状态；
- `sudo journalctl -u fastapi_app.service -f` 查看运行日志。

---

## 使用方式二：用于远程一键部署（从 GitHub 拉代码）

当你把本仓库（及你的业务代码）上传到 GitHub 后，可以实现真正的「一条命令部署」：

### 1. 准备 GitHub 仓库

推荐结构（示例）：

```bash
your-repo/
  app/
    main.py
  requirements.txt
  tools/
    fastapi_deploy.sh
    FastAPIApp.service
    Caddyfile.fastapi
    README_fastapi_template.md
  README.md
```

在本地初始化并推送到 GitHub（示例）：

```bash
git init
git add .
git commit -m "Add FastAPI + Caddy + Systemd deploy template"
git branch -M main
git remote add origin https://github.com/<your-name>/<your-repo>.git
git push -u origin main
```

### 2. 远程一键安装命令示例

在服务器上执行（请根据你仓库的实际地址修改）：

```bash
curl -fsSL https://raw.githubusercontent.com/<your-name>/<your-repo>/main/tools/fastapi_deploy.sh | \
  bash -s -- install \
  --from-github https://github.com/<your-name>/<your-repo>.git \
  --branch main \
  --domain example.com
```

- `https://raw.githubusercontent.com/.../fastapi_deploy.sh`  
  - 用于获取并执行部署脚本本身。
- `--from-github https://github.com/<your-name>/<your-repo>.git`  
  - 告诉脚本：**实际要部署的应用代码** 来自哪个仓库。
- `--domain example.com`  
  - 使用域名 + HTTPS 模式，Caddy 会自动为 `example.com` 申请 TLS 证书。
  - 确保你的域名 DNS 已指向该服务器 IP。
- 如果没有域名，可以改成：

```bash
curl -fsSL https://raw.githubusercontent.com/<your-name>/<your-repo>/main/tools/fastapi_deploy.sh | \
  bash -s -- install \
  --from-github https://github.com/<your-name>/<your-repo>.git \
  --branch main \
  --ip
```

---

## 脚本功能总览（行为说明）

> 更详细的技术说明可参考 `tools/README_fastapi_template.md`。

**1. 依赖检查**

- 检查并要求：`python3 (>=3.8)`。
- 检测 `python3-venv` / `ensurepip`，必要时尝试通过 `apt / yum / dnf` 安装。
- 按需安装：
  - `curl`：用于下载 Caddy 和获取公网 IP。
  - `git`：仅在 `--from-github` 时需要。
  - `unzip`：仅在 `--from-archive` 且使用 `.zip` 包时需要。

**2. 系统用户与目录**

- 创建系统用户与用户组：`fastapi:fastapi`。
- 安装目录：`/opt/fastapi_app`（可在脚本顶部改 `PROJECT_NAME`）。

**3. 代码同步**

- 支持三种代码来源：
  - `--from-local`（默认）：使用当前目录作为项目根。
  - `--from-github <repo>`：从指定 Git 仓库克隆。
  - `--from-archive <file>`：从本地压缩包（`.tar.gz/.tgz/.tar/.zip`）解压。
- 同步时会排除：
  - `.git`、`__pycache__`、`*.pyc`、`venv` 等无关文件。

**4. 虚拟环境与依赖**

- 在安装目录下创建 `venv` 虚拟环境。
- 如果存在 `requirements.txt`：
  - 使用 `pip install -r requirements.txt` 安装项目依赖。
- 否则：
  - 安装最小运行环境：`fastapi` 与 `uvicorn[standard]`。

**5. `.env` 与访问 URL**

- 在安装目录创建 `.env`（若不存在）：
  - 自动生成 `SECRET_KEY`。
  - 设置 `APP_ENV=production`。
- 根据使用 `--domain` 或 `--ip` 更新：
  - `APP_BASE_URL`，方便你的业务代码读取。
  - 可选 `FASTAPI_DOMAIN`。

**6. 示例应用（可选）**

- 如果未检测到 `app/main.py`：
  - 自动生成一个简单的 FastAPI 示例应用，包含：
    - `/` 欢迎页
    - `/health` 健康检查
- 若你已经提供了 `app/main.py`，脚本不会覆盖。

**7. Systemd 服务**

- 以 `tools/FastAPIApp.service` 为模板生成：
  - `/etc/systemd/system/fastapi_app.service`
- 默认启动命令类似：
  - `/opt/fastapi_app/venv/bin/uvicorn app.main:app --host 0.0.0.0 --port 8000`
- 提供：
  - `install`：安装并启用服务。
  - `uninstall`：停止 / 禁用服务，并清理安装目录。

**8. Caddy + 反向代理**

- Caddy 二进制安装目录：`/opt/fastapi_app/caddy`。
- Systemd 服务：`caddy.service`。
- 配置文件：`/etc/caddy/Caddyfile`。
- IP 模式：
  - 监听 `:80`，反向代理到 `127.0.0.1:8000`，仅 HTTP。
- 域名模式：
  - 使用 `tools/Caddyfile.fastapi` 模板生成配置。
  - 由 Caddy 自动申请与续签 TLS 证书。

**9. Bash 快捷命令**

- 安装完成后，会在当前用户 `~/.bashrc` 添加：

  ```bash
  alias fastapi_deploy="bash /opt/fastapi_app/tools/fastapi_deploy.sh"
  ```

- 之后可以直接：

  ```bash
  fastapi_deploy menu
  ```

  来打开脚本的交互式管理菜单。

---

## 常用运维操作

- **查看服务状态：**

  ```bash
  sudo systemctl status fastapi_app.service
  ```

- **实时查看应用日志：**

  ```bash
  sudo journalctl -u fastapi_app.service -f
  ```

- **查看 Caddy 状态 / 日志：**

  ```bash
  sudo systemctl status caddy
  sudo journalctl -u caddy -f
  ```

- **使用交互式菜单管理部署：**

  ```bash
  bash /opt/fastapi_app/tools/fastapi_deploy.sh menu
  ```

---

## 卸载与清理

在服务器上执行（默认需要确认，`--force` 跳过确认）：

```bash
sudo bash /opt/fastapi_app/tools/fastapi_deploy.sh uninstall --force
```

卸载行为：

- 停止并禁用 `fastapi_app.service`；
- 删除 `/etc/systemd/system/fastapi_app.service` 并 `systemctl daemon-reload`；
- 删除安装目录 `/opt/fastapi_app`。

> 注意：脚本**不会强制删除全局 Caddy 服务与配置**。如果你只为这个项目安装了 Caddy，可以根据需要手动清理 `/etc/systemd/system/caddy.service` 与 `/etc/caddy/` 等目录。

---

## 下一步：上传到 GitHub

在本目录（包含 `tools/` 与本 `README.md`）执行：

```bash
git init
git add .
git commit -m "Initial commit: FastAPI + Caddy + Systemd deploy template"
git branch -M main
git remote add origin https://github.com/<your-name>/<your-repo>.git
git push -u origin main
```

推送完成后，将上文中所有 `https://github.com/<your-name>/<your-repo>` 与 `raw.githubusercontent.com` 的占位符替换为你的真实仓库地址，即可在任意服务器上直接一键部署。


