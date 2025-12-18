#!/bin/bash
set -e

# -------------------------
# 基本配置（可根据需要调整）
# -------------------------

PROJECT_NAME="fastapi_app"
INSTALL_DIR="/opt/${PROJECT_NAME}"
CADDY_DIR="${INSTALL_DIR}/caddy"
SERVICE_USER="fastapi"
SERVICE_GROUP="fastapi"
APP_MODULE="app.main:app"
APP_PORT=8000
SYSTEMD_SERVICE_TEMPLATE_NAME="FastAPIApp.service"
CADDYFILE_TEMPLATE_NAME="Caddyfile.fastapi"

PYTHON_MIN_VERSION="3.8"

# 部署源
CODE_SOURCE="local"        # local | github | archive
GITHUB_REPO=""
GITHUB_BRANCH="main"
ARCHIVE_PATH=""

# 访问模式
DOMAIN="${FASTAPI_DOMAIN:-}"
USE_IP_MODE=false
PUBLIC_IP=""

FORCE=false

# -------------------------
# 输出辅助函数（中文）
# -------------------------

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_info()  { echo -e "${GREEN}[信息]${NC} $1"; }
print_warn()  { echo -e "${YELLOW}[警告]${NC} $1"; }
print_error() { echo -e "${RED}[错误]${NC} $1"; }
print_step()  { echo -e "${BLUE}[步骤]${NC} $1"; }

print_usage() {
    cat << EOF
用法: $0 [menu|install|uninstall] [选项]

子命令:
  menu                  交互式菜单（默认）
  install               安装 / 更新 FastAPI 应用
  uninstall             卸载

常用选项:
  --domain <域名>       使用域名 + HTTPS（由 Caddy 管理证书）
  --ip                  使用 IP / HTTP 模式（无需证书）
  --from-github <repo>  从 GitHub 仓库拉取代码
  --branch <branch>     搭配 --from-github 指定分支，默认 main
  --from-local          使用当前目录作为代码源（默认）
  --from-archive <file> 使用本地压缩包（.tar.gz/.tgz/.tar/.zip）
  --force               跳过危险操作确认（卸载等）
  -h, --help            显示本帮助

示例:
  # GitHub 一键部署（HTTPS）
  curl -fsSL <YOUR_RAW_URL>/fastapi_deploy.sh | \\
    bash -s -- install --from-github https://github.com/your/repo.git --domain example.com

  # 本地目录部署（HTTP）
  ./tools/fastapi_deploy.sh install --from-local --ip
EOF
}

parse_args() {
    COMMAND="menu"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            install|uninstall|menu)
                COMMAND="$1"
                shift
                ;;
            --domain)
                DOMAIN="$2"
                export FASTAPI_DOMAIN="$2"
                USE_IP_MODE=false
                shift 2
                ;;
            --ip)
                USE_IP_MODE=true
                DOMAIN=""
                export FASTAPI_DOMAIN=""
                shift
                ;;
            --from-github)
                CODE_SOURCE="github"
                if [[ -n "${2:-}" && ! "$2" =~ ^- ]]; then
                    GITHUB_REPO="$2"
                    shift 2
                else
                    shift
                fi
                ;;
            --branch)
                GITHUB_BRANCH="$2"
                shift 2
                ;;
            --from-local)
                CODE_SOURCE="local"
                shift
                ;;
            --from-archive)
                CODE_SOURCE="archive"
                ARCHIVE_PATH="$2"
                shift 2
                ;;
            --force|--yes)
                FORCE=true
                shift
                ;;
            -h|--help)
                print_usage
                exit 0
                ;;
            *)
                print_warn "Unknown option: $1"
                shift
                ;;
        esac
    done
}

check_root_or_sudo() {
    if [ "$EUID" -ne 0 ] && ! command -v sudo &> /dev/null; then
        print_error "请使用 root 或 sudo 运行此脚本。"
        exit 1
    fi
}

install_system_package() {
    local package="$1"
    local label="${2:-$1}"

    if command -v apt-get &> /dev/null; then
        if dpkg-query -W -f='${Status}' "$package" 2>/dev/null | grep -q "install ok installed"; then
            print_info "$label 已安装，跳过 ✓"
            return 0
        fi
        print_info "使用 apt 安装 $label..."
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -y
        apt-get install -y "$package"
    elif command -v yum &> /dev/null; then
        if yum list installed "$package" &> /dev/null; then
            print_info "$label 已安装，跳过 ✓"
            return 0
        fi
        print_info "使用 yum 安装 $label..."
        yum install -y "$package"
    elif command -v dnf &> /dev/null; then
        if dnf list installed "$package" &> /dev/null; then
            print_info "$label 已安装，跳过 ✓"
            return 0
        fi
        print_info "使用 dnf 安装 $label..."
        dnf install -y "$package"
    else
        print_warn "未检测到支持的包管理器，无法自动安装 $label"
        return 1
    fi
}

check_dependencies() {
    print_step "检查系统依赖..."

    # Python3
    if ! command -v python3 &> /dev/null; then
        print_error "未检测到 Python 3，请先安装 Python >= ${PYTHON_MIN_VERSION}。"
        exit 1
    fi

    PY_VER=$(python3 -c 'import sys; print(".".join(map(str, sys.version_info[:2])))')
    if [ "$(printf '%s\n' "$PYTHON_MIN_VERSION" "$PY_VER" | sort -V | head -n1)" != "$PYTHON_MIN_VERSION" ]; then
        print_error "Python 版本必须 >= $PYTHON_MIN_VERSION，当前: $PY_VER"
        exit 1
    fi
    print_info "Python 版本: $PY_VER ✓"

    # 确保 python3-venv / ensurepip 可用
    if ! python3 -c "import ensurepip" 2>/dev/null; then
        print_warn "检测到缺少 ensurepip，将尝试安装 python3-venv..."
        local PY_MM
        PY_MM=$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')
        if command -v apt-get &> /dev/null; then
            install_system_package "python${PY_MM}-venv" "python3-venv" || install_system_package "python3-venv" "python3-venv"
        elif command -v yum &> /dev/null || command -v dnf &> /dev/null; then
            install_system_package "python${PY_MM}-venv" "python3-venv" || install_system_package "python3-venv" "python3-venv"
        else
            print_error "无法自动安装 python3-venv，请手动安装后重试。"
            exit 1
        fi

        # 再次检查
        if ! python3 -c "import ensurepip" 2>/dev/null; then
            print_warn "安装后 ensurepip 仍不可用，可能是系统打包策略限制，但继续尝试创建虚拟环境。"
        else
            print_info "python3-venv / ensurepip 已就绪 ✓"
        fi
    else
        print_info "python3-venv / ensurepip 已就绪 ✓"
    fi

    # curl
    if ! command -v curl &> /dev/null; then
        install_system_package "curl" "curl" || {
            print_error "curl 安装失败，无法继续。"
            exit 1
        }
    fi

    # git（仅在使用 GitHub 源时需要）
    if [ "$CODE_SOURCE" = "github" ] && ! command -v git &> /dev/null; then
        install_system_package "git" "git" || {
            print_error "git 安装失败，无法从 GitHub 部署。"
            exit 1
        }
    fi

    # unzip（仅在使用 zip 压缩包时需要）
    if [ "$CODE_SOURCE" = "archive" ] && [[ "$ARCHIVE_PATH" == *.zip ]] && ! command -v unzip &> /dev/null; then
        install_system_package "unzip" "unzip" || {
            print_error "unzip 安装失败，无法解压 .zip 压缩包。"
            exit 1
        }
    fi

    print_info "系统依赖检查完成 ✓"
}

get_public_ip() {
    PUBLIC_IP=$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null || \
                curl -s --max-time 5 https://ifconfig.me 2>/dev/null || \
                curl -s --max-time 5 https://icanhazip.com 2>/dev/null || \
                echo "")
    echo "$PUBLIC_IP"
}

run_as_user() {
    local user="$1"
    shift
    local cmd="$*"

    if [ "$EUID" -eq 0 ]; then
        if command -v runuser &> /dev/null; then
            runuser -u "$user" -- bash -c "$cmd"
        else
            su -s /bin/bash "$user" -c "$cmd"
        fi
    else
        sudo -u "$user" bash -c "$cmd"
    fi
}

create_service_user() {
    print_step "创建服务用户与用户组..."

    if ! getent group "$SERVICE_GROUP" > /dev/null 2>&1; then
        groupadd -r "$SERVICE_GROUP"
        print_info "已创建用户组: $SERVICE_GROUP"
    else
        print_info "用户组已存在: $SERVICE_GROUP"
    fi

    if ! id "$SERVICE_USER" &>/dev/null; then
        useradd -r -g "$SERVICE_GROUP" -s /bin/false -d "$INSTALL_DIR" -c "FastAPI service user" "$SERVICE_USER"
        print_info "已创建用户: $SERVICE_USER"
    else
        print_info "用户已存在: $SERVICE_USER"
    fi
}

sync_code() {
    print_step "同步应用代码到: $INSTALL_DIR"

    local source_dir=""
    local temp_dir=""

    case "$CODE_SOURCE" in
        github)
            if [ -z "$GITHUB_REPO" ]; then
                print_error "未指定 GitHub 仓库地址，请使用 --from-github <repo>。"
                exit 1
            fi
            temp_dir="$(mktemp -d)"
            print_info "从 GitHub 克隆代码: $GITHUB_REPO (分支: $GITHUB_BRANCH)"
            git clone --depth 1 --branch "$GITHUB_BRANCH" "$GITHUB_REPO" "$temp_dir"
            source_dir="$temp_dir"
            ;;
        archive)
            if [ -z "$ARCHIVE_PATH" ] || [ ! -f "$ARCHIVE_PATH" ]; then
                print_error "未找到压缩包: $ARCHIVE_PATH"
                exit 1
            fi
            temp_dir="$(mktemp -d)"
            print_info "解压压缩包: $ARCHIVE_PATH"
            case "$ARCHIVE_PATH" in
                *.tar.gz|*.tgz|*.tar)
                    tar -xf "$ARCHIVE_PATH" -C "$temp_dir"
                    ;;
                *.zip)
                    unzip -q "$ARCHIVE_PATH" -d "$temp_dir"
                    ;;
                *)
                    print_error "不支持的压缩包格式，请使用 .tar.gz/.tgz/.tar/.zip"
                    exit 1
                    ;;
            esac
            source_dir=$(find "$temp_dir" -mindepth 1 -maxdepth 1 -type d | head -n 1)
            [ -z "$source_dir" ] && source_dir="$temp_dir"
            ;;
        *)
            source_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
            ;;
    esac

    mkdir -p "$INSTALL_DIR"

    print_info "复制文件..."
    if command -v rsync &> /dev/null; then
        rsync -av --exclude='.git' --exclude='__pycache__' --exclude='*.pyc' \
              --exclude='venv' "$source_dir/" "$INSTALL_DIR/"
    else
        cp -rv "$source_dir"/* "$INSTALL_DIR/" 2>/dev/null || true
        find "$INSTALL_DIR" -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true
        find "$INSTALL_DIR" -name "*.pyc" -delete 2>/dev/null || true
    fi

    chown -R "$SERVICE_USER:$SERVICE_GROUP" "$INSTALL_DIR"

    if [ -n "$temp_dir" ] && [ -d "$temp_dir" ]; then
        rm -rf "$temp_dir" || true
    fi

    print_info "代码同步完成 ✓"
}

setup_venv() {
    print_step "设置 Python 虚拟环境..."

    cd "$INSTALL_DIR"

    if [ ! -d "venv" ] || [ ! -f "venv/bin/activate" ]; then
        print_info "创建虚拟环境..."
        rm -rf venv

        # 再次检查 ensurepip（有些发行版只在安装 python3-venv 后才可用）
        if ! python3 -c "import ensurepip" 2>/dev/null; then
            print_warn "系统缺少 ensurepip，可能未正确安装 python3-venv。"
            local PY_MM
            PY_MM=$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')
            if command -v apt-get &> /dev/null; then
                print_info "可尝试手动执行: apt install python${PY_MM}-venv 或 apt install python3-venv"
            fi
        fi

        local VENV_OUTPUT
        if ! VENV_OUTPUT=$(run_as_user "$SERVICE_USER" "python3 -m venv venv" 2>&1); then
            print_error "虚拟环境创建失败。"
            echo "$VENV_OUTPUT"
            print_error "请根据上面的错误提示，在系统中安装对应的 python3-venv 包后重试。"
            exit 1
        fi
    else
        print_info "检测到已存在的虚拟环境，跳过创建 ✓"
    fi

    chown -R "$SERVICE_USER:$SERVICE_GROUP" "$INSTALL_DIR/venv"
    find "$INSTALL_DIR/venv/bin" -type f -exec chmod +x {} \; 2>/dev/null || true

    print_info "升级 pip / setuptools / wheel..."
    run_as_user "$SERVICE_USER" "source venv/bin/activate && pip install --upgrade pip setuptools wheel" || true

    if [ -f "requirements.txt" ]; then
        print_info "检测到 requirements.txt，安装项目依赖..."
        run_as_user "$SERVICE_USER" "source venv/bin/activate && pip install -r requirements.txt"
    else
        print_info "未找到 requirements.txt，安装最小 FastAPI 运行环境（fastapi + uvicorn[standard]）..."
        run_as_user "$SERVICE_USER" "source venv/bin/activate && pip install fastapi 'uvicorn[standard]'"
    fi

    print_info "虚拟环境准备完成 ✓"
}

setup_env_file() {
    print_step "准备 .env 配置文件（可选）..."

    local ENV_FILE="$INSTALL_DIR/.env"

    if [ ! -f "$ENV_FILE" ]; then
        print_info "创建最小 .env 文件..."
        touch "$ENV_FILE"
        if command -v python3 &> /dev/null; then
            local SECRET_KEY
            SECRET_KEY=$(python3 -c "import secrets; print(secrets.token_urlsafe(32))" 2>/dev/null || echo "")
            if [ -n "$SECRET_KEY" ]; then
                echo "SECRET_KEY=$SECRET_KEY" >> "$ENV_FILE"
            fi
        fi
        echo "APP_ENV=production" >> "$ENV_FILE"
    fi

    chmod 600 "$ENV_FILE"
    chown "$SERVICE_USER:$SERVICE_GROUP" "$ENV_FILE"

    print_info ".env 文件路径: $ENV_FILE"
}

create_sample_app_if_missing() {
    print_step "检测应用入口..."

    # 如果用户已经有自己的 app/main.py，则不做任何操作
    if [ -f "$INSTALL_DIR/app/main.py" ]; then
        print_info "检测到现有应用入口 app/main.py，跳过示例应用生成。"
        return 0
    fi

    print_info "未检测到 app/main.py，生成一个简单的 FastAPI 欢迎页面示例..."

    mkdir -p "$INSTALL_DIR/app"

    cat > "$INSTALL_DIR/app/main.py" << 'EOF'
from fastapi import FastAPI

app = FastAPI(title="FastAPI 部署示例")


@app.get("/")
async def read_root():
    return {
        "message": "FastAPI 部署成功！🚀",
        "tip": "你可以修改 app/main.py 来替换为自己的业务逻辑。",
    }


@app.get("/health")
async def health_check():
    return {"status": "ok"}
EOF

    chown -R "$SERVICE_USER:$SERVICE_GROUP" "$INSTALL_DIR/app"
    print_info "已生成示例应用 app/main.py，可用于测试部署是否成功。"
}

update_env_url() {
    # 根据当前域名 / IP 模式更新应用对外访问的基础 URL（APP_BASE_URL）
    local ENV_FILE="$INSTALL_DIR/.env"
    [ ! -f "$ENV_FILE" ] && return 0

    local SITE_URL=""
    if [ "$USE_IP_MODE" = true ]; then
        if [ -z "$PUBLIC_IP" ] || [ "$PUBLIC_IP" = "" ]; then
            PUBLIC_IP=$(get_public_ip)
        fi
        if [ -n "$PUBLIC_IP" ] && [ "$PUBLIC_IP" != "" ]; then
            SITE_URL="http://${PUBLIC_IP}/"
        else
            SITE_URL="http://localhost:${APP_PORT}/"
        fi
    else
        if [ -n "$DOMAIN" ] && [ "$DOMAIN" != "" ]; then
            SITE_URL="https://${DOMAIN}/"
        else
            SITE_URL="http://localhost:${APP_PORT}/"
        fi
    fi

    if grep -q "^APP_BASE_URL=" "$ENV_FILE"; then
        sed -i "s|^APP_BASE_URL=.*|APP_BASE_URL=$SITE_URL|" "$ENV_FILE"
    else
        echo "APP_BASE_URL=$SITE_URL" >>"$ENV_FILE"
    fi
    print_info "已更新 APP_BASE_URL: $SITE_URL"
}

app_service_is_active() {
    systemctl is-active --quiet "${PROJECT_NAME}.service"
}

app_service_start() {
    if app_service_is_active; then
        print_info "检测到服务已在运行，执行重启..."
        systemctl restart "${PROJECT_NAME}.service"
    else
        print_info "启动服务..."
        systemctl start "${PROJECT_NAME}.service"
    fi
}

app_service_stop() {
    print_info "停止服务..."
    systemctl stop "${PROJECT_NAME}.service" 2>/dev/null || true
}

app_service_restart() {
    print_info "重启服务..."
    systemctl restart "${PROJECT_NAME}.service"
}

show_summary() {
    echo ""
    print_info "=========================================="
    print_info "部署完成"
    print_info "=========================================="
    echo ""
    print_info "安装目录 : $INSTALL_DIR"
    print_info "服务名称 : ${PROJECT_NAME}.service"
    print_info "运行用户 : $SERVICE_USER/$SERVICE_GROUP"

    if [ "$USE_IP_MODE" = true ]; then
        [ -z "$PUBLIC_IP" ] && PUBLIC_IP=$(get_public_ip)
        if [ -n "$PUBLIC_IP" ]; then
            print_info "访问地址 : http://${PUBLIC_IP}"
        else
            print_info "访问地址 : http://<服务器IP>"
        fi
    else
        print_info "访问地址 : https://${DOMAIN}"
    fi

    echo ""
    if [ "$EUID" -eq 0 ]; then
        echo "  查看状态: systemctl status ${PROJECT_NAME}.service"
        echo "  查看日志: journalctl -u ${PROJECT_NAME}.service -f"
    else
        echo "  查看状态: sudo systemctl status ${PROJECT_NAME}.service"
        echo "  查看日志: sudo journalctl -u ${PROJECT_NAME}.service -f"
    fi
    echo ""
}

install_caddy() {
    print_step "Installing Caddy (if needed)..."

    mkdir -p "$CADDY_DIR"

    if [ ! -f "${CADDY_DIR}/caddy" ]; then
        local ARCH
        case "$(uname -m)" in
            x86_64) ARCH="amd64" ;;
            aarch64|arm64) ARCH="arm64" ;;
            armv7l) ARCH="armv7" ;;
            *) print_error "Unsupported architecture for Caddy"; return 1 ;;
        esac

        local VERSION
        VERSION=$(curl -s https://api.github.com/repos/caddyserver/caddy/releases/latest | grep -oP '"tag_name": "\K[^"]+' | head -1)
        [ -z "$VERSION" ] && VERSION="v2.10.2"
        local NUM="${VERSION#v}"
        local URL="https://github.com/caddyserver/caddy/releases/download/${VERSION}/caddy_${NUM}_linux_${ARCH}.tar.gz"

        print_info "Downloading Caddy $VERSION ($ARCH)..."
        cd "$CADDY_DIR"
        curl -L "$URL" -o caddy.tar.gz
        tar -xzf caddy.tar.gz
        rm -f caddy.tar.gz LICENSE README* 2>/dev/null || true
        chmod +x caddy
    else
        print_info "Caddy binary already present ✓"
    fi

    ln -sf "${CADDY_DIR}/caddy" /usr/local/bin/caddy

    # systemd service for Caddy
    if [ ! -f /etc/systemd/system/caddy.service ]; then
        cat >/etc/systemd/system/caddy.service <<EOF
[Unit]
Description=Caddy Web Server
After=network.target network-online.target
Requires=network-online.target

[Service]
Type=notify
ExecStart=${CADDY_DIR}/caddy run --environ --config /etc/caddy/Caddyfile
ExecReload=${CADDY_DIR}/caddy reload --config /etc/caddy/Caddyfile --force
TimeoutStopSec=5s
LimitNOFILE=1048576
LimitNPROC=512
PrivateTmp=true
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable caddy || true
    fi

    mkdir -p /etc/caddy /var/log/caddy
    print_info "Caddy installation/configuration done ✓"
}

setup_caddy() {
    print_step "Configuring Caddy..."

    install_caddy

    local CADDYFILE="/etc/caddy/Caddyfile"

    if [ "$USE_IP_MODE" = true ]; then
        print_info "使用 IP / HTTP 模式配置 Caddy..."
        cat >"$CADDYFILE" <<EOF
:80 {
    reverse_proxy 127.0.0.1:${APP_PORT} {
        header_up Host {host}
        header_up X-Real-IP {remote}
        header_up X-Forwarded-For {remote}
        header_up X-Forwarded-Proto {scheme}
    }

    encode gzip zstd

    header {
        X-Frame-Options "SAMEORIGIN"
        X-Content-Type-Options "nosniff"
        Referrer-Policy "strict-origin-when-cross-origin"
    }

    log {
        output file /var/log/caddy/fastapi_app.log
        format json
    }
}
EOF
    else
        print_info "使用域名 / HTTPS 模式配置 Caddy (${DOMAIN})..."
        local TEMPLATE_LOCAL
        TEMPLATE_LOCAL="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/${CADDYFILE_TEMPLATE_NAME}"
        if [ ! -f "$TEMPLATE_LOCAL" ] && [ -f "$INSTALL_DIR/tools/${CADDYFILE_TEMPLATE_NAME}" ]; then
            TEMPLATE_LOCAL="$INSTALL_DIR/tools/${CADDYFILE_TEMPLATE_NAME}"
        fi
        if [ ! -f "$TEMPLATE_LOCAL" ]; then
            print_error "Caddyfile template not found: $CADDYFILE_TEMPLATE_NAME"
            return 1
        fi
        sed \
            -e "s#__DOMAIN__#${DOMAIN}#g" \
            -e "s#__APP_PORT__#${APP_PORT}#g" \
            "$TEMPLATE_LOCAL" >"$CADDYFILE"
    fi

    if [ -x "${CADDY_DIR}/caddy" ]; then
        if ! "${CADDY_DIR}/caddy" validate --config "$CADDYFILE"; then
            print_warn "Caddyfile 校验失败，请稍后手动检查配置。"
        fi
    fi

    systemctl restart caddy || true
    print_info "Caddy 配置已应用并重启 ✓"
}

setup_systemd_service() {
    print_step "Configuring systemd service for FastAPI app..."

    local SERVICE_FILE="/etc/systemd/system/${PROJECT_NAME}.service"
    local TEMPLATE_LOCAL
    TEMPLATE_LOCAL="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/${SYSTEMD_SERVICE_TEMPLATE_NAME}"
    if [ ! -f "$TEMPLATE_LOCAL" ] && [ -f "$INSTALL_DIR/tools/${SYSTEMD_SERVICE_TEMPLATE_NAME}" ]; then
        TEMPLATE_LOCAL="$INSTALL_DIR/tools/${SYSTEMD_SERVICE_TEMPLATE_NAME}"
    fi
    if [ ! -f "$TEMPLATE_LOCAL" ]; then
        print_error "Systemd service template not found: ${SYSTEMD_SERVICE_TEMPLATE_NAME}"
        exit 1
    fi

    sed \
        -e "s#__SERVICE_USER__#${SERVICE_USER}#g" \
        -e "s#__SERVICE_GROUP__#${SERVICE_GROUP}#g" \
        -e "s#__INSTALL_DIR__#${INSTALL_DIR}#g" \
        -e "s#__APP_MODULE__#${APP_MODULE}#g" \
        -e "s#__APP_PORT__#${APP_PORT}#g" \
        -e "s#__PROJECT_NAME__#${PROJECT_NAME}#g" \
        "$TEMPLATE_LOCAL" >"$SERVICE_FILE"

    systemctl daemon-reload
    systemctl enable "${PROJECT_NAME}.service"
    print_info "Systemd service installed: ${PROJECT_NAME}.service ✓"
}

start_services() {
    print_step "Starting services..."
    app_service_start || print_error "Failed to start app service"
    systemctl start caddy 2>/dev/null || true
    print_info "Services started (FastAPI app + Caddy) ✓"
}

setup_bash_alias() {
    print_step "Setting up bash alias (optional)..."

    local target_user="${SUDO_USER:-$USER}"
    local home_dir
    home_dir=$(getent passwd "$target_user" | cut -d: -f6)
    [ -z "$home_dir" ] && return 0

    local bashrc="$home_dir/.bashrc"
    local alias_line="alias fastapi_deploy=\"bash $INSTALL_DIR/tools/fastapi_deploy.sh\""

    if [ -f "$bashrc" ] && grep -F "$alias_line" "$bashrc" >/dev/null 2>&1; then
        print_info "Alias already present in $bashrc"
        return 0
    fi

    echo "$alias_line" >>"$bashrc"
    chown "$target_user:$target_user" "$bashrc" 2>/dev/null || true
    print_info "Alias added to $bashrc: fastapi_deploy"
}

show_current_config() {
    print_step "当前配置概览"
    print_info "安装目录 : $INSTALL_DIR"
    print_info "服务名称 : ${PROJECT_NAME}.service"

    if [ -n "$DOMAIN" ]; then
        print_info "访问模式 : 域名 / HTTPS"
        print_info "当前域名 : $DOMAIN"
    else
        print_info "访问模式 : IP / HTTP"
        local cur_ip
        cur_ip=$(get_public_ip)
        if [ -n "$cur_ip" ]; then
            print_info "当前公网 IP : $cur_ip"
            print_info "预计访问地址 : http://${cur_ip}"
        else
            print_info "预计访问地址 : http://<服务器IP>"
        fi
    fi

    local ENV_FILE="$INSTALL_DIR/.env"
    if [ -f "$ENV_FILE" ]; then
        local url
        url=$(grep "^APP_BASE_URL=" "$ENV_FILE" 2>/dev/null | cut -d'=' -f2- || echo "")
        [ -n "$url" ] && print_info "APP_BASE_URL : $url"
    fi
}

apply_config_changes() {
    print_step "应用访问模式 / 域名配置变更..."

    if [ ! -d "$INSTALL_DIR" ]; then
        print_warn "尚未检测到安装目录: $INSTALL_DIR，建议先执行安装 / 更新。"
        return 0
    fi

    # 确保 .env 存在
    setup_env_file
    local ENV_FILE="$INSTALL_DIR/.env"

    # 更新 FASTAPI_DOMAIN 环境变量
    if [ -n "$DOMAIN" ]; then
        if grep -q "^FASTAPI_DOMAIN=" "$ENV_FILE"; then
            sed -i "s|^FASTAPI_DOMAIN=.*|FASTAPI_DOMAIN=$DOMAIN|" "$ENV_FILE"
        else
            echo "FASTAPI_DOMAIN=$DOMAIN" >>"$ENV_FILE"
        fi
    else
        sed -i '/^FASTAPI_DOMAIN=/d' "$ENV_FILE" || true
    fi

    # 更新 APP_BASE_URL
    update_env_url

    # 根据最新配置重写 Caddyfile
    setup_caddy

    # 重启应用服务以生效
    if app_service_is_active; then
        app_service_restart || print_warn "应用服务重启失败，请手动检查。"
    fi

    print_info "配置变更已应用完成。"
}

interactive_change_mode() {
    print_step "交互式切换访问模式（域名 / IP）..."

    echo ""
    echo "当前访问模式："
    if [ -n "$DOMAIN" ]; then
        echo "  - 域名模式（HTTPS），当前域名: $DOMAIN"
    else
        echo "  - IP 模式（HTTP）"
    fi
    echo ""
    echo "1) 使用域名（HTTPS，由 Caddy 自动申请证书）"
    echo "2) 使用 IP 地址（HTTP，不启用证书）"
    read -p "请选择新的访问方式 [1/2]: " MODE_CHOICE

    case "$MODE_CHOICE" in
        1)
            read -p "请输入域名（例如 example.com）: " NEW_DOMAIN
            if [ -z "$NEW_DOMAIN" ]; then
                print_error "域名不能为空。"
                return 1
            fi
            DOMAIN="$NEW_DOMAIN"
            USE_IP_MODE=false
            export FASTAPI_DOMAIN="$DOMAIN"
            print_info "已设置为域名模式: $DOMAIN（HTTPS，将由 Caddy 自动申请证书）"
            ;;
        2)
            DOMAIN=""
            USE_IP_MODE=true
            export FASTAPI_DOMAIN=""
            print_info "已切换为 IP 模式（HTTP）"
            ;;
        *)
            print_warn "无效选择，保持当前配置不变。"
            return 0
            ;;
    esac

    # IP 模式下更新公网 IP
    if [ "$USE_IP_MODE" = true ]; then
        print_info "正在检测公网 IP..."
        PUBLIC_IP=$(get_public_ip)
        if [ -n "$PUBLIC_IP" ]; then
            print_info "检测到公网 IP: $PUBLIC_IP"
        else
            print_warn "无法自动获取公网 IP，将使用本机地址。"
        fi
    fi

    apply_config_changes
}

install() {
    print_info "FastAPI + Caddy + Systemd 一键部署脚本"

    if [ -z "$DOMAIN" ] || [ "$USE_IP_MODE" = true ]; then
        USE_IP_MODE=true
        PUBLIC_IP=$(get_public_ip)
    else
        USE_IP_MODE=false
    fi

    check_root_or_sudo
    check_dependencies
    create_service_user
    sync_code
    create_sample_app_if_missing
    setup_venv
    setup_env_file
    setup_systemd_service
    setup_caddy
    start_services
    setup_bash_alias
    show_summary
}

uninstall() {
    print_step "卸载 FastAPI 应用..."

    if [ "$FORCE" = false ]; then
        read -p "此操作将删除服务并清理 $INSTALL_DIR 下的文件，是否继续？(y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            print_info "已取消卸载。"
            exit 0
        fi
    fi

    systemctl stop "${PROJECT_NAME}.service" 2>/dev/null || true
    systemctl disable "${PROJECT_NAME}.service" 2>/dev/null || true
    rm -f "/etc/systemd/system/${PROJECT_NAME}.service"
    systemctl daemon-reload

    rm -rf "$INSTALL_DIR"

    print_info "卸载完成。"
}

show_menu() {
    while true; do
        echo ""
        print_info "FastAPI 部署管理菜单"
        echo " 1) 安装 / 更新"
        echo " 2) 查看当前配置"
        echo " 3) 切换访问模式（域名 / IP）"
        echo " 4) 启动 / 停止 / 重启服务"
        echo " 5) 查看日志"
        echo " 6) 卸载"
        echo " 7) 退出"
        read -p "请选择 [1-7]: " choice

        case "$choice" in
            1) install ;;
            2) show_current_config ;;
            3) interactive_change_mode ;;
            4)
                echo " 1) 启动"
                echo " 2) 停止"
                echo " 3) 重启"
                read -p "请选择 [1-3]: " svc
                case "$svc" in
                    1) app_service_start ;;
                    2) app_service_stop ;;
                    3) app_service_restart ;;
                esac
                ;;
            5)
                echo ""
                print_step "应用最近 100 行日志："
                journalctl -u "${PROJECT_NAME}.service" -n 100 --no-pager || print_warn "无法读取应用日志（可能需要 root / sudo）。"
                echo ""
                print_step "Caddy 最近 100 行日志："
                journalctl -u caddy -n 100 --no-pager || print_warn "无法读取 Caddy 日志（可能尚未安装或需要 root / sudo）。"
                ;;
            6) uninstall ;;
            7) break ;;
            *) print_warn "无效选择，请输入 1-7 之间的数字。" ;;
        esac
    done
}

main() {
    parse_args "$@"

    case "${COMMAND:-menu}" in
        menu)      show_menu ;;
        install)   install ;;
        uninstall) uninstall ;;
        *)         print_usage; exit 1 ;;
    esac
}

main "$@"


