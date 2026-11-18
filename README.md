## FastAPI + Caddy + Systemd 一键部署模板

一个**开箱即用**的 FastAPI 部署模板，包含：

- **一键部署脚本**：自动完成代码同步、虚拟环境、依赖安装、Systemd 服务与 Caddy 反向代理 / HTTPS 配置。
- **Systemd 模板**：将 FastAPI 进程以系统服务的方式长期稳定运行。
- **Caddy 模板**：支持域名 + HTTPS（自动申请证书）或纯 IP / HTTP 访问。

你可以：

- 把整个仓库克隆到本地，作为自己项目的 **部署工具仓库** 使用；
- 或者把 `tools/` 目录复制到任意 FastAPI 项目中，直接本地执行部署；
- 也可以通过 GitHub Raw 链接实现真正意义上的 **一条命令远程部署**。

想看实际运行效果？请参考 [FastAPI-Game-Rating-Lite](https://github.com/vihithr/FastAPI-Game-Rating-Lite)。

---

## Quick Start：一条命令远程一键部署（推荐）

在目标服务器上（Debian / Ubuntu 等），直接执行：

### 无域名（HTTP，适合测试环境）

```bash
curl -fsSL https://raw.githubusercontent.com/vihithr/FastAPI-Caddy-Systemd-OneKey/main/fastapi_deploy.sh | \
  bash -s -- install \
  --from-github https://github.com/vihithr/FastAPI-Caddy-Systemd-OneKey.git \
  --branch main \
  --ip
```

### 有域名（HTTPS，自动证书）

```bash
curl -fsSL https://raw.githubusercontent.com/vihithr/FastAPI-Caddy-Systemd-OneKey/main/fastapi_deploy.sh | \
  bash -s -- install \
  --from-github https://github.com/vihithr/FastAPI-Caddy-Systemd-OneKey.git \
  --branch main \
  --domain your-domain.com
```

- 部署完成后：
  - 应用服务：`fastapi_app.service`（监听 `0.0.0.0:8000`）
  - 反向代理：`caddy`（IP 模式监听 `:80`，域名模式自动 HTTPS）

---

## Quick Start：从备份复制部署

如果你已有备份文件，可以快速在新服务器上恢复部署：

### 快速恢复步骤

**1. 传输备份文件到新服务器：**

```bash
# 从本地或其他服务器传输备份文件
scp fastapi_app_backup_*.tar.gz user@new-server:/tmp/
```

**2. 解压并部署：**

```bash
# 在新服务器上
cd /tmp
tar -xzf fastapi_app_backup_*.tar.gz
cd fastapi_app  # 进入解压后的目录

# 一键部署（IP 模式）
sudo bash tools/fastapi_deploy.sh install --from-local --ip

# 或使用域名模式
sudo bash tools/fastapi_deploy.sh install --from-local --domain your-domain.com
```

**3. 恢复环境变量（如需要）：**

```bash
# 如果有备份的 .env 文件
sudo cp /path/to/.env.backup /opt/fastapi_app/.env
sudo chown fastapi:fastapi /opt/fastapi_app/.env
sudo chmod 600 /opt/fastapi_app/.env
sudo systemctl restart fastapi_app.service
```

**4. 验证部署：**

```bash
# 检查服务状态
sudo systemctl status fastapi_app.service

# 测试访问
curl http://your-domain.com/health  # 或 http://server-ip/health
```

> 💡 **提示**：备份文件会自动排除虚拟环境、日志等环境相关文件，只包含业务代码和配置，因此恢复时会自动重建运行环境。

---

## 实测资源占用（Debian 12 小内存实例）

在一台仅约 **512 MB 内存、无 Swap 的 Debian 12** 小机型上测试本模板，部署完成并启动 `fastapi_app` 与 `caddy` 后：

- `fastapi_app.service`（Uvicorn + FastAPI）：
  - 常驻内存约 **40–45 MB**（`RES`≈44 MB 左右）。
- Caddy 进程：
  - 常驻内存约 **25–30 MB**（多个 worker 进程合计）。
- 整机占用示例（`free -m`）：
  - 总内存：约 **451 MB**
  - 已用：约 **180 MB**
  - 可用：约 **270 MB**

**结论**：在极小内存的 VPS（如 512 MB 级别）上，本模板依旧可以较为轻量地运行 FastAPI + Caddy + Systemd 的完整栈，适合作为低成本的 API / Demo 环境。

---

## 轻量级架构设计

- **进程模型简单**：
  - 仅包含一个由 Systemd 管理的 `uvicorn` 进程（FastAPI 应用）和一个 `caddy` 进程树（反向代理 / TLS）。
  - 无 `docker`、`supervisor` 等额外守护进程，减少资源开销与排障复杂度。
- **就地虚拟环境**：
  - 在 `/opt/fastapi_app/venv` 下创建独立虚拟环境，不污染系统 Python。
  - 所有依赖只对当前应用生效，卸载时可一次性删除整个目录。
- **最小依赖栈**：
  - 核心仅依赖：Python + Uvicorn + FastAPI + Caddy。
  - 可选按需增加数据库、缓存等服务，但模板本身不强制绑定任何重型中间件。
- **可复用工具目录**：
  - 所有部署逻辑集中在 `tools/` 中，与业务代码解耦，可在多个项目间拷贝复用。

整体设计目标是：**在极小资源下提供「够用且可维护」的生产级服务形态**，而不是追求堆栈复杂度。

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

## 数据备份与迁移

### 数据备份

#### 方法一：使用脚本自动备份（推荐）

脚本提供了便捷的备份功能，会自动排除环境相关文件（如 `venv`、`caddy`、`.env`、日志等），只备份业务代码和配置文件。

**使用交互式菜单备份：**

```bash
bash /opt/fastapi_app/tools/fastapi_deploy.sh menu
# 然后选择 "5) 备份"
```

备份功能会提示你输入备份文件保存路径，直接回车使用默认路径（`/opt/fastapi_app_backup_YYYYMMDD_HHMMSS.tar.gz`），或输入自定义路径。

**备份内容包括：**
- ✅ 应用代码（`app/` 目录）
- ✅ 配置文件（`requirements.txt`、`tools/` 等）
- ✅ 业务数据文件（如果存储在应用目录中）
- ❌ 排除：虚拟环境（`venv/`）
- ❌ 排除：Caddy 二进制文件（`caddy/`）
- ❌ 排除：环境变量文件（`.env`）
- ❌ 排除：日志文件（`*.log`）
- ❌ 排除：缓存和临时文件

#### 方法二：手动备份

如果需要完整备份（包括数据库、配置文件等），可以手动执行：

**1. 备份应用目录：**

```bash
# 创建备份目录
sudo mkdir -p /backup/fastapi_app
sudo chown $USER:$USER /backup/fastapi_app

# 备份应用代码（排除环境文件）
cd /opt
sudo tar -czf /backup/fastapi_app/app_backup_$(date +%Y%m%d_%H%M%S).tar.gz \
  --exclude=fastapi_app/venv \
  --exclude=fastapi_app/caddy \
  --exclude=fastapi_app/.env \
  --exclude=fastapi_app/*.log \
  --exclude=fastapi_app/__pycache__ \
  fastapi_app
```

**2. 备份环境变量（重要）：**

```bash
# 备份 .env 文件（包含敏感信息，请妥善保管）
sudo cp /opt/fastapi_app/.env /backup/fastapi_app/.env.backup
```

**3. 备份数据库（如果使用 SQLite）：**

```bash
# 如果应用使用 SQLite 数据库
sudo cp /opt/fastapi_app/*.db /backup/fastapi_app/ 2>/dev/null || true
sudo cp /opt/fastapi_app/*.sqlite* /backup/fastapi_app/ 2>/dev/null || true
```

**4. 备份 Systemd 服务配置：**

```bash
sudo cp /etc/systemd/system/fastapi_app.service /backup/fastapi_app/
```

**5. 备份 Caddy 配置（如果使用域名模式）：**

```bash
sudo cp /etc/caddy/Caddyfile /backup/fastapi_app/Caddyfile.backup
```

#### 数据库备份（PostgreSQL / MySQL）

如果你的应用使用外部数据库（PostgreSQL、MySQL 等），需要单独备份：

**PostgreSQL：**

```bash
# 备份整个数据库
sudo -u postgres pg_dump -U postgres your_database_name > /backup/fastapi_app/db_backup_$(date +%Y%m%d_%H%M%S).sql

# 或备份为压缩格式
sudo -u postgres pg_dump -U postgres -Fc your_database_name > /backup/fastapi_app/db_backup_$(date +%Y%m%d_%H%M%S).dump
```

**MySQL：**

```bash
# 备份整个数据库
mysqldump -u root -p your_database_name > /backup/fastapi_app/db_backup_$(date +%Y%m%d_%H%M%S).sql

# 或备份为压缩格式
mysqldump -u root -p your_database_name | gzip > /backup/fastapi_app/db_backup_$(date +%Y%m%d_%H%M%S).sql.gz
```

#### 备份文件传输

备份完成后，建议将备份文件传输到安全位置（如本地电脑、云存储等）：

```bash
# 使用 SCP 传输到本地
scp /backup/fastapi_app/*.tar.gz user@your-local-ip:/local/backup/path/

# 或使用 rsync
rsync -avz /backup/fastapi_app/ user@your-local-ip:/local/backup/path/
```

---

### 数据迁移

#### 从备份恢复应用

**1. 传输备份文件到新服务器：**

```bash
# 在新服务器上，从本地传输备份文件
scp fastapi_app_backup_*.tar.gz user@new-server:/tmp/
```

**2. 解压备份文件：**

```bash
# 在新服务器上
cd /tmp
tar -xzf fastapi_app_backup_*.tar.gz
```

**3. 进入解压后的目录并部署：**

```bash
cd fastapi_app  # 或解压后的目录名
sudo bash tools/fastapi_deploy.sh install --from-local --ip
# 或使用域名模式
sudo bash tools/fastapi_deploy.sh install --from-local --domain your-domain.com
```

**4. 恢复环境变量（如果需要）：**

```bash
# 如果有备份的 .env 文件，复制到安装目录
sudo cp /backup/fastapi_app/.env.backup /opt/fastapi_app/.env
sudo chown fastapi:fastapi /opt/fastapi_app/.env
sudo chmod 600 /opt/fastapi_app/.env
```

**5. 恢复数据库（如果使用外部数据库）：**

**PostgreSQL：**

```bash
# 恢复数据库
sudo -u postgres psql -U postgres -d your_database_name < /backup/fastapi_app/db_backup_*.sql

# 或从压缩格式恢复
sudo -u postgres pg_restore -U postgres -d your_database_name /backup/fastapi_app/db_backup_*.dump
```

**MySQL：**

```bash
# 恢复数据库
mysql -u root -p your_database_name < /backup/fastapi_app/db_backup_*.sql

# 或从压缩格式恢复
gunzip < /backup/fastapi_app/db_backup_*.sql.gz | mysql -u root -p your_database_name
```

**6. 重启服务：**

```bash
sudo systemctl restart fastapi_app.service
sudo systemctl restart caddy
```

#### 迁移到新服务器（完整流程）

**步骤 1：在旧服务器上备份**

```bash
# 使用脚本备份
bash /opt/fastapi_app/tools/fastapi_deploy.sh menu
# 选择备份选项

# 或手动完整备份
sudo mkdir -p /backup/migration
sudo bash /opt/fastapi_app/tools/fastapi_deploy.sh menu  # 选择备份
# 备份数据库（如果使用）
# 备份 .env 文件
```

**步骤 2：准备新服务器**

- 确保新服务器满足运行环境要求（Python 3.8+、系统权限等）
- 如果使用域名，确保 DNS 已指向新服务器 IP

**步骤 3：传输备份文件**

```bash
# 从旧服务器传输到新服务器
scp /opt/fastapi_app_backup_*.tar.gz user@new-server:/tmp/
# 如果有数据库备份，也一并传输
scp /backup/migration/*.sql user@new-server:/tmp/
```

**步骤 4：在新服务器上恢复**

按照上面的"从备份恢复应用"步骤执行。

**步骤 5：验证迁移**

```bash
# 检查服务状态
sudo systemctl status fastapi_app.service
sudo systemctl status caddy

# 检查应用日志
sudo journalctl -u fastapi_app.service -n 50

# 测试访问
curl http://your-domain.com/health  # 或 http://new-server-ip/health
```

#### 迁移注意事项

⚠️ **重要提示：**

1. **环境变量**：`.env` 文件包含敏感信息（如 `SECRET_KEY`），迁移时需要单独备份和恢复，不要丢失。

2. **数据库连接**：如果应用使用外部数据库，迁移后需要更新数据库连接配置（在新服务器的 `.env` 文件中）。

3. **文件权限**：确保恢复后的文件权限正确：
   ```bash
   sudo chown -R fastapi:fastapi /opt/fastapi_app
   ```

4. **端口冲突**：确保新服务器的 8000 端口（应用端口）和 80/443 端口（Caddy）未被占用。

5. **域名 DNS**：如果使用域名模式，迁移前确保 DNS 已指向新服务器，避免证书申请失败。

6. **依赖版本**：如果新服务器的 Python 版本或系统环境不同，可能需要重新安装依赖：
   ```bash
   cd /opt/fastapi_app
   source venv/bin/activate
   pip install -r requirements.txt --upgrade
   ```

7. **定期备份**：建议设置定时任务（cron）自动备份：
   ```bash
   # 编辑 crontab
   sudo crontab -e
   
   # 添加每日备份（每天凌晨 2 点）
   0 2 * * * bash /opt/fastapi_app/tools/fastapi_deploy.sh menu <<< "5"
   ```

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

在本地初始化并推送到 GitHub（示例，本仓库已对应为 [`vihithr/FastAPI-Caddy-Systemd-OneKey`](https://github.com/vihithr/FastAPI-Caddy-Systemd-OneKey)）：

```bash
git init
git add .
git commit -m "Add FastAPI + Caddy + Systemd deploy template"
git branch -M main
git remote add origin https://github.com/vihithr/FastAPI-Caddy-Systemd-OneKey.git
git push -u origin main
```

### 2. 远程一键安装命令示例

在服务器上执行（本仓库一键部署示例）：

```bash
curl -fsSL https://raw.githubusercontent.com/vihithr/FastAPI-Caddy-Systemd-OneKey/main/fastapi_deploy.sh | \
  bash -s -- install \
  --from-github https://github.com/vihithr/FastAPI-Caddy-Systemd-OneKey.git \
  --branch main \
  --domain example.com
```

- `https://raw.githubusercontent.com/vihithr/FastAPI-Caddy-Systemd-OneKey/main/fastapi_deploy.sh`  
  - 用于获取并执行部署脚本本身。
- `--from-github https://github.com/vihithr/FastAPI-Caddy-Systemd-OneKey.git`  
  - 告诉脚本：**实际要部署的应用代码** 来自哪个仓库。
- `--domain example.com`  
  - 使用域名 + HTTPS 模式，Caddy 会自动为 `example.com` 申请 TLS 证书。
  - 确保你的域名 DNS 已指向该服务器 IP。
- 如果没有域名，可以改成：

```bash
curl -fsSL https://raw.githubusercontent.com/vihithr/FastAPI-Caddy-Systemd-OneKey/main/fastapi_deploy.sh | \
  bash -s -- install \
  --from-github https://github.com/vihithr/FastAPI-Caddy-Systemd-OneKey.git \
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

在本目录（包含 `tools/` 与本 `README.md`）执行（本仓库已示范为 `vihithr/FastAPI-Caddy-Systemd-OneKey`）：

```bash
git init
git add .
git commit -m "Initial commit: FastAPI + Caddy + Systemd deploy template"
git branch -M main
git remote add origin https://github.com/vihithr/FastAPI-Caddy-Systemd-OneKey.git
git push -u origin main
```

推送完成后，你可以直接使用上文中以 `vihithr/FastAPI-Caddy-Systemd-OneKey` 为例的一键部署命令，在任意服务器上完成部署。
---

## English

A one-command deployment template for FastAPI on Debian/Ubuntu, built around **Caddy** and **systemd**.

- `fastapi_deploy.sh` syncs the app, creates a virtualenv, installs dependencies, writes a systemd unit and configures Caddy (HTTP for an IP, automatic HTTPS for a domain).
- Install directly on a server:

  ```bash
  curl -fsSL https://raw.githubusercontent.com/vihithr/FastAPI-Caddy-Systemd-OneKey/main/fastapi_deploy.sh | \
    bash -s -- install --from-github https://github.com/vihithr/FastAPI-Caddy-Systemd-OneKey.git --branch main --domain example.com
  ```

- Use `--ip` instead of `--domain` for HTTP-only testing.
- The script also supports update, backup, restore and uninstall; the Chinese sections above contain the complete walkthrough.
- Real-world deployment example: [FastAPI-Game-Rating-Lite](https://github.com/vihithr/FastAPI-Game-Rating-Lite).