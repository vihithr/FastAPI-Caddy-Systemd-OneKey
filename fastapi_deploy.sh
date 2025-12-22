#!/bin/bash
# FastAPI 应用一键部署脚本
# 支持安装、更新、卸载功能

set -e  # 遇到错误立即退出

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

  # 从压缩包部署
  ./fastapi_deploy.sh install --from-archive project.tar.gz --domain example.com

备份功能:
  使用交互式菜单选择"备份"选项，或直接运行:
    $0 menu  # 然后选择备份选项

  备份将排除环境相关文件（venv, caddy, .env, .cache 等），
  只保存业务代码和配置文件。

  在新环境恢复:
    1. 解压备份文件: tar -xzf fastapi_app_backup_*.tar.gz
    2. 进入解压后的目录
    3. 运行: ./tools/fastapi_deploy.sh install
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
                print_warn "未知参数: $1"
                shift
                ;;
        esac
    done
}

# 统一的文件排除列表（用于备份和代码同步，类似 .gitignore）
get_exclude_patterns() {
    # 返回 rsync 的 --exclude 参数列表
    # Python 相关
    echo "--exclude='venv'"
    echo "--exclude='__pycache__'"
    echo "--exclude='*.pyc'"
    echo "--exclude='*.pyo'"
    echo "--exclude='*.pyd'"
    # 数据库文件
    echo "--exclude='*.db'"
    echo "--exclude='*.sqlite'"
    echo "--exclude='*.sqlite3'"
    # 配置文件
    echo "--exclude='.env'"
    # 日志文件
    echo "--exclude='*.log'"
    echo "--exclude='logs'"
    echo "--exclude='log'"
    # 临时文件
    echo "--exclude='*.tmp'"
    echo "--exclude='*.temp'"
    echo "--exclude='tmp'"
    echo "--exclude='temp'"
    # 缓存
    echo "--exclude='.cache'"
    echo "--exclude='cache'"
    echo "--exclude='*.cache'"
    # 系统文件
    echo "--exclude='*.pid'"
    echo "--exclude='*.lock'"
    echo "--exclude='.DS_Store'"
    echo "--exclude='Thumbs.db'"
    # IDE 配置
    echo "--exclude='.idea'"
    echo "--exclude='.vscode'"
    echo "--exclude='*.swp'"
    echo "--exclude='*.swo'"
    # 版本控制
    echo "--exclude='.git'"
    echo "--exclude='.svn'"
    # 运行时文件
    echo "--exclude='caddy'"
    # 注意：不排除 *.service，因为应用目录中的服务模板文件需要保留
}

# 备份排除列表（用于 tar 命令，格式为 --exclude=pattern）
get_backup_exclude_patterns() {
    # 返回 tar 的 --exclude 参数列表
    # Python 相关
    echo "--exclude=venv"
    echo "--exclude=__pycache__"
    echo "--exclude=*.pyc"
    echo "--exclude=*.pyo"
    echo "--exclude=*.pyd"
    # 数据库文件
    echo "--exclude=*.db"
    echo "--exclude=*.sqlite"
    echo "--exclude=*.sqlite3"
    # 配置文件（环境相关）
    echo "--exclude=.env"
    # 日志文件
    echo "--exclude=*.log"
    echo "--exclude=logs"
    echo "--exclude=log"
    # 临时文件
    echo "--exclude=*.tmp"
    echo "--exclude=*.temp"
    echo "--exclude=tmp"
    echo "--exclude=temp"
    # 缓存
    echo "--exclude=.cache"
    echo "--exclude=cache"
    echo "--exclude=*.cache"
    # 系统文件
    echo "--exclude=*.pid"
    echo "--exclude=*.lock"
    echo "--exclude=.DS_Store"
    echo "--exclude=Thumbs.db"
    # IDE 配置
    echo "--exclude=.idea"
    echo "--exclude=.vscode"
    echo "--exclude=*.swp"
    echo "--exclude=*.swo"
    # 版本控制
    echo "--exclude=.git"
    echo "--exclude=.svn"
    # 运行时文件
    echo "--exclude=caddy"
    # 特殊文件（如果存在）
    echo "--exclude=ystemctl reload caddy"
    # 注意：不排除 *.service，因为应用目录中的服务模板文件需要保留
}

# 从已安装环境中加载现有配置（域名 / IP 模式），避免每次重复输入
load_existing_config() {
    # 如果通过命令行参数或环境变量已经显式设置了 DOMAIN，则尊重该值
    if [ -n "${DOMAIN:-}" ]; then
        USE_IP_MODE=false
        return
    fi

    local ENV_FILE_PATH="$INSTALL_DIR/.env"
    if [ -f "$ENV_FILE_PATH" ]; then
        # 优先从 FASTAPI_DOMAIN 读取
        local ENV_DOMAIN
        ENV_DOMAIN=$(grep "^FASTAPI_DOMAIN=" "$ENV_FILE_PATH" 2>/dev/null | cut -d'=' -f2- | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/^["'\'']//' -e 's/["'\'']$//')
        if [ -n "$ENV_DOMAIN" ]; then
            DOMAIN="$ENV_DOMAIN"
            USE_IP_MODE=false
            return
        fi

        # 其次根据 APP_BASE_URL 推断
        local SITE_URL
        SITE_URL=$(grep "^APP_BASE_URL=" "$ENV_FILE_PATH" 2>/dev/null | cut -d'=' -f2- | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/^["'\'']//' -e 's/["'\'']$//')
        if echo "$SITE_URL" | grep -q "^https://"; then
            DOMAIN=$(echo "$SITE_URL" | sed -E 's#^https?://([^/]+)/?.*#\1#')
            USE_IP_MODE=false
            return
        elif echo "$SITE_URL" | grep -q "^http://"; then
            # 认为是 IP 模式
            USE_IP_MODE=true
            PUBLIC_IP=$(echo "$SITE_URL" | sed -E 's#^http://([^/:]+)/?.*#\1#')
            return
        fi
    fi
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
                print_error "未提供 GitHub 仓库地址，请使用 --from-github <repo>"
                exit 1
            fi
            if ! command -v git &> /dev/null; then
                print_error "未找到 git，请先安装 git 再使用 --from-github"
                exit 1
            fi
            temp_dir="$(mktemp -d)"
            print_info "从 GitHub 拉取代码: $GITHUB_REPO (branch: $GITHUB_BRANCH)"
            if ! git clone --depth 1 --branch "$GITHUB_BRANCH" "$GITHUB_REPO" "$temp_dir"; then
                print_error "Git 克隆失败，请检查仓库地址/分支是否存在"
                rm -rf "$temp_dir" 2>/dev/null || true
                exit 1
            fi
            source_dir="$temp_dir"
            ;;
        archive)
            if [ -z "$ARCHIVE_PATH" ]; then
                print_error "未提供压缩包路径，请使用 --from-archive <file>"
                exit 1
            fi
            if [ ! -f "$ARCHIVE_PATH" ]; then
                print_error "压缩包不存在: $ARCHIVE_PATH"
                exit 1
            fi
            temp_dir="$(mktemp -d)"
            print_info "解压压缩包: $ARCHIVE_PATH"
            case "$ARCHIVE_PATH" in
                *.tar.gz|*.tgz|*.tar)
                    if ! tar -xf "$ARCHIVE_PATH" -C "$temp_dir"; then
                        print_error "解压失败，请确认文件格式为 tar/tgz"
                        rm -rf "$temp_dir" 2>/dev/null || true
                        exit 1
                    fi
                    ;;
                *.zip)
                    if ! command -v unzip &> /dev/null; then
                        print_error "未找到 unzip，请安装后再使用 .zip 包"
                        rm -rf "$temp_dir" 2>/dev/null || true
                        exit 1
                    fi
                    if ! unzip -q "$ARCHIVE_PATH" -d "$temp_dir"; then
                        print_error "解压 zip 失败，请检查文件"
                        rm -rf "$temp_dir" 2>/dev/null || true
                        exit 1
                    fi
                    ;;
                *)
                    print_error "不支持的压缩包格式，仅支持 .tar.gz/.tgz/.tar/.zip"
                    rm -rf "$temp_dir" 2>/dev/null || true
                    exit 1
                    ;;
            esac
            source_dir=$(find "$temp_dir" -mindepth 1 -maxdepth 1 -type d | head -n 1)
            if [ -z "$source_dir" ]; then
                source_dir="$temp_dir"
            fi
            ;;
        *)
            # 严格以脚本所在目录为源目录，不做任何检测或判断
            source_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
            ;;
    esac

    # 创建安装目录
    mkdir -p "$INSTALL_DIR"

    # 复制所有文件（排除不必要的文件）
    print_info "复制应用文件..."
    print_info "源目录: $source_dir"
    print_info "目标目录: $INSTALL_DIR"
    
    # 验证源目录中的关键文件
    if [ -f "$source_dir/app/main.py" ]; then
        print_info "检测到源目录中的 app/main.py ✓"
    else
        print_warn "源目录中未找到 app/main.py"
    fi
    if [ -f "$source_dir/requirements.txt" ]; then
        print_info "检测到源目录中的 requirements.txt ✓"
    else
        print_warn "源目录中未找到 requirements.txt"
    fi
    
    if command -v rsync &> /dev/null; then
        print_info "使用 rsync 复制文件（显示详细输出）..."
        # 使用统一的排除列表，构建 rsync 排除参数数组
        local RSYNC_EXCLUDE_ARGS=()
        while IFS= read -r exclude_pattern; do
            # 提取排除模式（移除 --exclude=' 和末尾的 '）
            local pattern
            pattern=$(echo "$exclude_pattern" | sed "s/^--exclude='\(.*\)'$/\1/")
            RSYNC_EXCLUDE_ARGS+=("--exclude=$pattern")
        done < <(get_exclude_patterns)
        
        # 执行 rsync 命令
        if ! rsync -av "${RSYNC_EXCLUDE_ARGS[@]}" "$source_dir/" "$INSTALL_DIR/"; then
            print_error "rsync 复制失败，尝试使用 cp 命令..."
            # 如果 rsync 失败，回退到 cp
            cp -rv "$source_dir"/* "$INSTALL_DIR/" 2>&1 || true
        fi
    else
        # 如果没有 rsync，使用 cp 并清理环境相关文件
        print_info "使用 cp 复制文件..."
        cp -rv "$source_dir"/* "$INSTALL_DIR/" 2>&1 || true
        # 清理环境相关文件（使用与get_exclude_patterns相同的排除规则）
        print_info "清理环境相关文件..."
        # Python 相关
        find "$INSTALL_DIR" -type d -name "__pycache__" -exec rm -rf {} + 2>&1 || true
        find "$INSTALL_DIR" -name "*.pyc" -delete 2>&1 || true
        find "$INSTALL_DIR" -name "*.pyo" -delete 2>&1 || true
        find "$INSTALL_DIR" -name "*.pyd" -delete 2>&1 || true
        # 数据库文件
        find "$INSTALL_DIR" -maxdepth 1 -name "*.db" -delete 2>&1 || true
        find "$INSTALL_DIR" -maxdepth 1 -name "*.sqlite" -delete 2>&1 || true
        find "$INSTALL_DIR" -maxdepth 1 -name "*.sqlite3" -delete 2>&1 || true
        # 配置文件
        rm -f "$INSTALL_DIR/.env" 2>&1 || true
        # 日志文件
        find "$INSTALL_DIR" -name "*.log" -delete 2>&1 || true
        rm -rf "$INSTALL_DIR/logs" 2>&1 || true
        rm -rf "$INSTALL_DIR/log" 2>&1 || true
        # 临时文件
        find "$INSTALL_DIR" -name "*.tmp" -delete 2>&1 || true
        find "$INSTALL_DIR" -name "*.temp" -delete 2>&1 || true
        rm -rf "$INSTALL_DIR/tmp" 2>&1 || true
        rm -rf "$INSTALL_DIR/temp" 2>&1 || true
        # 缓存
        rm -rf "$INSTALL_DIR/.cache" 2>&1 || true
        rm -rf "$INSTALL_DIR/cache" 2>&1 || true
        find "$INSTALL_DIR" -name "*.cache" -delete 2>&1 || true
        # 系统文件
        find "$INSTALL_DIR" -name "*.pid" -delete 2>&1 || true
        find "$INSTALL_DIR" -name "*.lock" -delete 2>&1 || true
        find "$INSTALL_DIR" -name ".DS_Store" -delete 2>&1 || true
        find "$INSTALL_DIR" -name "Thumbs.db" -delete 2>&1 || true
        # IDE 配置
        rm -rf "$INSTALL_DIR/.idea" 2>&1 || true
        rm -rf "$INSTALL_DIR/.vscode" 2>&1 || true
        find "$INSTALL_DIR" -name "*.swp" -delete 2>&1 || true
        find "$INSTALL_DIR" -name "*.swo" -delete 2>&1 || true
        # 版本控制
        rm -rf "$INSTALL_DIR/.git" 2>&1 || true
        rm -rf "$INSTALL_DIR/.svn" 2>&1 || true
        # 运行时文件
        rm -rf "$INSTALL_DIR/caddy" 2>&1 || true
    fi

    # 设置所有权
    chown -R "$SERVICE_USER:$SERVICE_GROUP" "$INSTALL_DIR"

    # 设置文件权限（目录 755，文件 644）
    find "$INSTALL_DIR" -type d -exec chmod 755 {} \;
    find "$INSTALL_DIR" -type f -exec chmod 644 {} \;
    # 确保 Caddy 二进制保持可执行（避免被上面的 644 覆盖）
    if [ -f "$CADDY_DIR/caddy" ]; then
        chmod +x "$CADDY_DIR/caddy"
    fi

    # 使脚本可执行
    chmod +x "$INSTALL_DIR/tools/fastapi_deploy.sh" 2>/dev/null || true

    # 验证关键文件是否已复制
    print_info "验证关键文件..."
    if [ -f "$INSTALL_DIR/app/main.py" ]; then
        print_info "✓ app/main.py 已复制"
    else
        print_warn "⚠ app/main.py 未找到（将在后续步骤中生成示例文件）"
    fi
    if [ -f "$INSTALL_DIR/requirements.txt" ]; then
        print_info "✓ requirements.txt 已复制"
    else
        print_warn "⚠ requirements.txt 未找到（将安装最小依赖）"
    fi

    # 清理临时目录（如有）
    if [ -n "$temp_dir" ] && [ -d "$temp_dir" ] && [ "$temp_dir" != "/" ]; then
        rm -rf "$temp_dir" 2>/dev/null || true
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
        print_info "检测到服务已在运行，执行重启以加载最新代码..."
        systemctl restart "${PROJECT_NAME}.service" || {
            print_error "服务重启失败，请检查日志: journalctl -u ${PROJECT_NAME}.service -n 50"
            return 1
        }
    else
        print_info "启动服务..."
        systemctl start "${PROJECT_NAME}.service" || {
            print_error "服务启动失败，请检查日志: journalctl -u ${PROJECT_NAME}.service -n 50"
            return 1
        }
    fi
}

app_service_stop() {
    print_info "停止服务..."
    systemctl stop "${PROJECT_NAME}.service" 2>/dev/null || {
        print_warn "停止服务时出现问题（可能本就未运行）"
    }
}

app_service_restart() {
    print_info "重启服务..."
    systemctl restart "${PROJECT_NAME}.service" || {
        print_error "服务重启失败，请检查日志: journalctl -u ${PROJECT_NAME}.service -n 50"
        return 1
    }
}

app_service_status() {
    systemctl status "${PROJECT_NAME}.service"
}

show_summary() {
    echo ""
    print_info "=========================================="
    print_info "部署完成！"
    print_info "=========================================="
    echo ""
    print_info "安装目录: $INSTALL_DIR"
    print_info "Caddy 目录: $CADDY_DIR"
    print_info "服务用户: $SERVICE_USER"
    print_info "服务名称: ${PROJECT_NAME}.service"
    print_info "部署脚本: $INSTALL_DIR/tools/fastapi_deploy.sh（用于后续更新 / 管理）"

    if [ "$USE_IP_MODE" = true ]; then
        print_info "访问模式: IP 地址（HTTP）"
        if [ -n "$PUBLIC_IP" ] && [ "$PUBLIC_IP" != "" ]; then
            print_info "访问地址: http://${PUBLIC_IP}:80"
            echo ""
            print_info "═══════════════════════════════════════"
            print_info "  网站访问地址: http://${PUBLIC_IP}"
            print_info "═══════════════════════════════════════"
        else
            print_warn "无法获取公网 IP，请手动检查服务器 IP 地址"
            print_info "本地访问: http://localhost:${APP_PORT}"
        fi
    else
        print_info "访问模式: 域名（HTTPS）"
        print_info "域名: $DOMAIN"
        echo ""
        print_info "═══════════════════════════════════════"
        print_info "  网站访问地址: https://${DOMAIN}"
        print_info "═══════════════════════════════════════"
    fi
    echo ""
    print_info "常用命令:"
    if [ "$EUID" -eq 0 ]; then
        echo "  - 查看日志: journalctl -u ${PROJECT_NAME}.service -f"
        echo "  - 重启服务: systemctl restart ${PROJECT_NAME}.service"
        echo "  - 查看状态: systemctl status ${PROJECT_NAME}.service"
        echo "  - 查看 Caddy 日志: journalctl -u caddy -f"
        echo "  - 编辑配置: nano $INSTALL_DIR/.env"
        echo "  - 进入部署管理菜单: $INSTALL_DIR/tools/fastapi_deploy.sh menu"
        echo "  - 卸载: $0 uninstall"
    else
        echo "  - 查看日志: sudo journalctl -u ${PROJECT_NAME}.service -f"
        echo "  - 重启服务: sudo systemctl restart ${PROJECT_NAME}.service"
        echo "  - 查看状态: sudo systemctl status ${PROJECT_NAME}.service"
        echo "  - 查看 Caddy 日志: sudo journalctl -u caddy -f"
        echo "  - 编辑配置: sudo nano $INSTALL_DIR/.env"
        echo "  - 进入部署管理菜单: sudo $INSTALL_DIR/tools/fastapi_deploy.sh menu"
        echo "  - 卸载: sudo $0 uninstall"
    fi
    echo ""
    print_warn "重要提示:"
    print_warn "  1. 请检查并更新 $INSTALL_DIR/.env 中的配置（如需要）"
    if [ "$USE_IP_MODE" = false ]; then
        print_warn "  2. 确保 DNS 已正确配置，将 $DOMAIN 指向此服务器"
    else
        print_warn "  2. 当前使用 IP 模式，如需切换为域名，请在脚本菜单中选择"切换访问模式""
    fi
    echo ""
    print_info "部署完成！网站应该已经可以访问了。"
}

install_caddy() {
    print_step "安装 Caddy 反向代理服务器（集中安装到 ${CADDY_DIR}）..."

    # 创建 Caddy 安装目录
    mkdir -p "$CADDY_DIR"

    if [ ! -f "${CADDY_DIR}/caddy" ]; then
        # 检测架构
        local ARCH
        ARCH=$(uname -m)
        case "$ARCH" in
            x86_64) ARCH="amd64" ;;
            aarch64|arm64) ARCH="arm64" ;;
            armv7l) ARCH="armv7" ;;
            *) print_error "不支持的架构: $ARCH"; return 1 ;;
        esac

        # 获取最新版本
        print_info "获取 Caddy 最新版本..."
        local VERSION
        VERSION=$(curl -s https://api.github.com/repos/caddyserver/caddy/releases/latest | grep -oP '"tag_name": "\K[^"]+' | head -1)
        if [ -z "$VERSION" ]; then
            VERSION="v2.10.2"  # 使用已知版本作为后备
            print_warn "无法获取最新版本，使用默认版本: $VERSION"
        fi

        # 移除版本号中的 'v' 前缀（如果存在）用于下载 URL
        local NUM="${VERSION#v}"

        print_info "下载 Caddy $VERSION ($ARCH)..."
        cd "$CADDY_DIR"

        # 下载文件并检查 HTTP 状态码
        local HTTP_CODE
        HTTP_CODE=$(curl -L --write-out "%{http_code}" --progress-bar "https://github.com/caddyserver/caddy/releases/download/${VERSION}/caddy_${NUM}_linux_${ARCH}.tar.gz" -o caddy.tar.gz)

        if [ "$HTTP_CODE" != "200" ]; then
            print_error "下载 Caddy 失败，HTTP 状态码: $HTTP_CODE"
            print_error "请手动下载 Caddy: https://caddyserver.com/download"
            return 1
        fi

        # 检查下载的文件是否是有效的 tar.gz 文件
        if ! file caddy.tar.gz | grep -q "gzip\|tar archive"; then
            print_error "下载的文件格式不正确"
            rm -f caddy.tar.gz
            return 1
        fi

        # 文件格式正确，解压
        print_info "解压 Caddy..."
        tar -xzf caddy.tar.gz || {
            print_error "解压 Caddy 失败"
            return 1
        }
        chmod +x caddy
        rm -f caddy.tar.gz LICENSE README.md 2>/dev/null || true
    else
        print_info "Caddy 二进制文件已存在，跳过下载 ✓"
    fi

    # 创建符号链接到系统路径（便于使用）
    ln -sf "${CADDY_DIR}/caddy" /usr/local/bin/caddy

    # 创建 systemd 服务文件（使用 root 用户，不需要 caddy 用户）
    if [ ! -f /etc/systemd/system/caddy.service ]; then
        cat > /etc/systemd/system/caddy.service << EOF
[Unit]
Description=Caddy Web Server
Documentation=https://caddyserver.com/docs/
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

        # 创建配置目录
        mkdir -p /etc/caddy

        systemctl daemon-reload
    fi

    # 设置所有权
    chown -R "$SERVICE_USER:$SERVICE_GROUP" "$CADDY_DIR"

    print_info "Caddy 安装完成（安装位置: ${CADDY_DIR}）✓"
}

setup_caddy() {
    print_step "配置 Caddy 反向代理..."

    # 检查 Caddy 是否已安装
    if [ ! -f "${CADDY_DIR}/caddy" ]; then
        install_caddy
    fi

    local CADDYFILE="/etc/caddy/Caddyfile"

    # 确保 /etc/caddy 目录存在
    if [ ! -d "/etc/caddy" ]; then
        print_info "创建 Caddy 配置目录..."
        mkdir -p /etc/caddy
    fi

    # 创建日志目录（如果 Caddyfile 中使用了日志）
    if [ ! -d "/var/log/caddy" ]; then
        print_info "创建 Caddy 日志目录..."
        mkdir -p /var/log/caddy
    fi

    if [ "$USE_IP_MODE" = true ]; then
        # IP 模式：使用 HTTP，不使用 HTTPS
        print_info "使用 IP 模式配置（HTTP）..."
        cat > "$CADDYFILE" << EOF
# FastAPI App Caddyfile - IP Mode
# Using HTTP (no HTTPS) for IP access

:80 {
    # Reverse proxy to FastAPI app
    reverse_proxy 127.0.0.1:${APP_PORT} {
        # Headers
        header_up Host {host}
        header_up X-Real-IP {remote}
        header_up X-Forwarded-For {remote}
        header_up X-Forwarded-Proto http
    }

    # Enable compression
    encode gzip zstd

    # Security headers (without HSTS since we're using HTTP)
    header {
        # Prevent clickjacking
        X-Frame-Options "SAMEORIGIN"
        # XSS Protection
        X-Content-Type-Options "nosniff"
        # Referrer Policy
        Referrer-Policy "strict-origin-when-cross-origin"
    }

    # Logging
    log {
        output file /var/log/caddy/fastapi_app.log
        format json
    }
}
EOF
    else
        # 域名模式：使用 HTTPS
        print_info "使用域名模式配置（HTTPS）..."
        local TEMPLATE_LOCAL
        TEMPLATE_LOCAL="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/${CADDYFILE_TEMPLATE_NAME}"
        if [ ! -f "$TEMPLATE_LOCAL" ] && [ -f "$INSTALL_DIR/tools/${CADDYFILE_TEMPLATE_NAME}" ]; then
            TEMPLATE_LOCAL="$INSTALL_DIR/tools/${CADDYFILE_TEMPLATE_NAME}"
        fi
        if [ -f "$TEMPLATE_LOCAL" ]; then
            sed \
                -e "s#__DOMAIN__#${DOMAIN}#g" \
                -e "s#__APP_PORT__#${APP_PORT}#g" \
                "$TEMPLATE_LOCAL" > "$CADDYFILE"
        else
            # 如果没有模板，生成默认配置
            print_warn "未找到 Caddyfile 模板，使用默认配置..."
            cat > "$CADDYFILE" << EOF
# FastAPI App Caddyfile - Domain Mode
# Using HTTPS with automatic certificate

${DOMAIN} {
    # Reverse proxy to FastAPI app
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
        Strict-Transport-Security "max-age=31536000; includeSubDomains; preload"
    }

    log {
        output file /var/log/caddy/fastapi_app.log
        format json
    }
}
EOF
        fi
    fi

    # 验证 Caddyfile
    if [ -f "${CADDY_DIR}/caddy" ]; then
        local VALIDATE_OUTPUT
        VALIDATE_OUTPUT=$("${CADDY_DIR}/caddy" validate --config "$CADDYFILE" 2>&1)
        local VALIDATE_EXIT=$?
        if [ $VALIDATE_EXIT -eq 0 ]; then
            print_info "Caddyfile 验证通过 ✓"

            # 重新加载 Caddy
            systemctl reload caddy 2>/dev/null || systemctl restart caddy 2>/dev/null || true
            print_info "Caddy 配置已应用 ✓"
        else
            print_warn "Caddyfile 验证失败（退出码: $VALIDATE_EXIT）"
            if [ -n "$VALIDATE_OUTPUT" ]; then
                echo "验证错误: $VALIDATE_OUTPUT"
            fi
            print_warn "但继续执行，Caddy 可能会在启动时报告错误..."
            print_info "您可以稍后手动验证: ${CADDY_DIR}/caddy validate --config $CADDYFILE"
            systemctl restart caddy 2>/dev/null || true
        fi
    else
        print_warn "Caddy 二进制文件不存在，跳过验证"
        print_warn "Caddyfile 已创建，但 Caddy 服务可能无法启动"
        print_warn "请检查 Caddy 安装是否成功"
    fi
}

setup_systemd_service() {
    print_step "Configuring systemd service for FastAPI app..."

    local SERVICE_FILE="/etc/systemd/system/${PROJECT_NAME}.service"
    local TEMPLATE_LOCAL
    TEMPLATE_LOCAL="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/${SYSTEMD_SERVICE_TEMPLATE_NAME}"
    if [ ! -f "$TEMPLATE_LOCAL" ] && [ -f "$INSTALL_DIR/tools/${SYSTEMD_SERVICE_TEMPLATE_NAME}" ]; then
        TEMPLATE_LOCAL="$INSTALL_DIR/tools/${SYSTEMD_SERVICE_TEMPLATE_NAME}"
    fi
    # 如果安装目录中有服务模板文件，也尝试使用
    if [ ! -f "$TEMPLATE_LOCAL" ] && [ -f "$INSTALL_DIR/${SYSTEMD_SERVICE_TEMPLATE_NAME}" ]; then
        TEMPLATE_LOCAL="$INSTALL_DIR/${SYSTEMD_SERVICE_TEMPLATE_NAME}"
    fi
    # 如果安装目录中有项目名.service，也尝试使用
    if [ ! -f "$TEMPLATE_LOCAL" ] && [ -f "$INSTALL_DIR/${PROJECT_NAME}.service" ]; then
        TEMPLATE_LOCAL="$INSTALL_DIR/${PROJECT_NAME}.service"
    fi
    
    if [ -f "$TEMPLATE_LOCAL" ]; then
        print_info "使用服务模板文件: $TEMPLATE_LOCAL"
        sed \
            -e "s#__SERVICE_USER__#${SERVICE_USER}#g" \
            -e "s#__SERVICE_GROUP__#${SERVICE_GROUP}#g" \
            -e "s#__INSTALL_DIR__#${INSTALL_DIR}#g" \
            -e "s#__APP_MODULE__#${APP_MODULE}#g" \
            -e "s#__APP_PORT__#${APP_PORT}#g" \
            -e "s#__PROJECT_NAME__#${PROJECT_NAME}#g" \
            "$TEMPLATE_LOCAL" >"$SERVICE_FILE"
    else
        # 如果找不到模板，生成默认的 systemd 服务文件
        print_warn "未找到服务模板文件 ${SYSTEMD_SERVICE_TEMPLATE_NAME}，使用默认配置生成 systemd 服务文件"
        cat > "$SERVICE_FILE" << EOF
[Unit]
Description=FastAPI Application Service
After=network.target

[Service]
Type=simple
User=${SERVICE_USER}
Group=${SERVICE_GROUP}
WorkingDirectory=${INSTALL_DIR}
EnvironmentFile=${INSTALL_DIR}/.env
ExecStart=${INSTALL_DIR}/venv/bin/uvicorn ${APP_MODULE} --host 0.0.0.0 --port ${APP_PORT}
Restart=always
RestartSec=3
KillSignal=SIGINT
TimeoutStopSec=10
SyslogIdentifier=${PROJECT_NAME}

[Install]
WantedBy=multi-user.target
EOF
        print_info "已生成默认 systemd 服务文件"
    fi

    systemctl daemon-reload
    systemctl enable "${PROJECT_NAME}.service"
    print_info "Systemd service installed: ${PROJECT_NAME}.service ✓"
}

start_services() {
    print_step "启动服务..."

    # 启动 / 重启 应用服务（如果已在运行则重启以加载最新代码）
    if ! app_service_start; then
        exit 1
    fi

    sleep 2

    # 检查服务状态
    if app_service_is_active; then
        print_info "应用服务运行正常 ✓"
    else
        print_warn "应用服务可能未正常运行，请检查: sudo systemctl status ${PROJECT_NAME}.service"
    fi

    # 确保 Caddy 运行
    if [ -f "${CADDY_DIR}/caddy" ]; then
        systemctl start caddy 2>/dev/null || true
    fi

    print_info "服务启动完成 ✓"
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
    print_info "运行用户 : $SERVICE_USER/$SERVICE_GROUP"
    print_info "应用模块 : $APP_MODULE"
    print_info "应用端口 : $APP_PORT"

    # 服务状态
    if app_service_is_active; then
        print_info "服务状态 : 运行中 ✓"
    else
        print_warn "服务状态 : 未运行"
    fi

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
    else
        print_warn ".env 文件不存在"
    fi

    # 数据库信息（如果使用数据库）
    if [ -f "$ENV_FILE" ]; then
        local db_url
        db_url=$(grep "^DATABASE_URL=" "$ENV_FILE" 2>/dev/null | cut -d'=' -f2- || echo "")
        if [ -n "$db_url" ]; then
            if echo "$db_url" | grep -q "^sqlite"; then
                local db_path
                db_path=$(echo "$db_url" | sed 's|^sqlite:///||')
                print_info "数据库类型 : SQLite"
                print_info "数据库路径 : $db_path"
            else
                local safe_url
                safe_url=$(echo "$db_url" | sed 's/:[^:@]*@/:***@/')
                print_info "数据库 URL : $safe_url"
            fi
        fi
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

    if [ ! -d "$INSTALL_DIR" ]; then
        print_warn "尚未检测到安装目录: $INSTALL_DIR，建议先执行安装 / 更新。"
    fi

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
            read -p "请输入域名（留空则保留当前: ${DOMAIN:-<未设置>}）: " NEW_DOMAIN
            if [ -n "$NEW_DOMAIN" ]; then
                DOMAIN="$NEW_DOMAIN"
            fi
            if [ -z "$DOMAIN" ]; then
                print_error "未配置域名，无法切换到域名模式。"
                return 1
            fi
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
        print_info "正在获取公网 IP 地址..."
        PUBLIC_IP=$(get_public_ip)
        if [ -n "$PUBLIC_IP" ] && [ "$PUBLIC_IP" != "" ]; then
            print_info "检测到公网 IP: $PUBLIC_IP"
        else
            print_warn "无法自动获取公网 IP，将使用本地 IP"
            PUBLIC_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "127.0.0.1")
        fi
    fi

    # 应用变更（更新 .env / Caddy / 服务）
    apply_config_changes
}

interactive_install_settings() {
    echo ""
    print_step "安装 / 更新 配置向导"
    echo ""

    echo ""
    print_step "网站访问方式设置"
    echo ""

    # 根据当前变量推断默认模式（如果已有配置则优先使用）
    local DEFAULT_MODE="2"
    if [ -n "${DOMAIN:-}" ]; then
        DEFAULT_MODE="1"
    fi

    echo "访问方式："
    echo "  1) 使用域名（HTTPS）"
    echo "  2) 使用 IP 地址（HTTP）"
    read -p "请选择访问方式 [${DEFAULT_MODE}]: " MODE_CHOICE
    MODE_CHOICE=${MODE_CHOICE:-$DEFAULT_MODE}

    if [ "$MODE_CHOICE" = "1" ]; then
        read -p "请输入域名（当前: ${DOMAIN:-<未设置>}，直接回车保留当前）: " INPUT_DOMAIN
        if [ -n "$INPUT_DOMAIN" ]; then
            DOMAIN="$INPUT_DOMAIN"
        fi

        if [ -n "$DOMAIN" ]; then
            export FASTAPI_DOMAIN="$DOMAIN"
            USE_IP_MODE=false
            print_info "将使用域名模式: $DOMAIN（HTTPS）"
        else
            print_warn "未配置域名，将回退为 IP 模式（HTTP）"
            DOMAIN=""
            export FASTAPI_DOMAIN=""
            USE_IP_MODE=true
        fi
    else
        DOMAIN=""
        export FASTAPI_DOMAIN=""
        USE_IP_MODE=true
        print_info "将使用 IP 模式（HTTP）"
    fi
}

install() {
    echo ""
    print_info "=========================================="
    print_info "FastAPI 应用一键部署脚本"
    print_info "=========================================="
    echo ""

    # 交互式安装配置
    interactive_install_settings

    # 根据是否配置域名决定运行模式（结合交互结果）
    if [ -z "$DOMAIN" ] || [ "$DOMAIN" = "" ]; then
        USE_IP_MODE=true
        print_info "未配置域名，将使用 IP 地址模式（HTTP）"
        print_info "正在获取公网 IP 地址..."
        PUBLIC_IP=$(get_public_ip)
        if [ -n "$PUBLIC_IP" ] && [ "$PUBLIC_IP" != "" ]; then
            print_info "检测到公网 IP: $PUBLIC_IP"
        else
            print_warn "无法自动获取公网 IP，将使用本地 IP"
            PUBLIC_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "127.0.0.1")
        fi
    else
        USE_IP_MODE=false
        print_info "使用域名模式: $DOMAIN"
    fi

    check_root_or_sudo
    check_dependencies
    create_service_user
    sync_code
    create_sample_app_if_missing
    setup_venv
    setup_env_file
    update_env_url
    setup_systemd_service
    setup_caddy
    start_services
    setup_bash_alias
    show_summary
}

uninstall() {
    print_step "开始卸载 FastAPI 应用..."

    # 确认
    if [ "$FORCE" = false ]; then
        read -p "确定要卸载吗？这将删除所有安装的文件和服务。 (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            print_info "取消卸载"
            exit 0
        fi
    else
        print_warn "已开启 --force，跳过卸载确认，默认继续。"
    fi

    # 停止服务
    print_info "停止服务..."
    systemctl stop "${PROJECT_NAME}.service" 2>/dev/null || true
    systemctl stop caddy 2>/dev/null || true

    # 禁用服务
    print_info "禁用服务..."
    systemctl disable "${PROJECT_NAME}.service" 2>/dev/null || true
    systemctl disable caddy 2>/dev/null || true

    # 删除服务文件
    print_info "删除服务文件..."
    rm -f "/etc/systemd/system/${PROJECT_NAME}.service"
    rm -f /etc/systemd/system/caddy.service
    systemctl daemon-reload

    # 删除 Caddy 符号链接
    rm -f /usr/local/bin/caddy

    # 删除 Caddy 配置文件（可选，保留用户数据）
    if [ "$FORCE" = false ]; then
        read -p "是否删除 Caddy 配置文件？ (y/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            rm -f /etc/caddy/Caddyfile
        fi
    else
        print_warn "已开启 --force，删除 Caddy 配置文件。"
        rm -f /etc/caddy/Caddyfile
    fi

    # 删除安装目录（可选，保留用户数据）
    if [ "$FORCE" = false ]; then
        read -p "是否删除安装目录 ${INSTALL_DIR}？（这将删除所有数据，包括数据库） (y/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            rm -rf "$INSTALL_DIR"
            print_info "已删除安装目录: $INSTALL_DIR"
        else
            print_info "保留安装目录: $INSTALL_DIR"
        fi
    else
        print_warn "已开启 --force，删除安装目录和数据。"
        rm -rf "$INSTALL_DIR"
        print_info "已删除安装目录: $INSTALL_DIR"
    fi

    # 删除用户和组（可选）
    if [ "$FORCE" = false ]; then
        read -p "是否删除服务用户 ${SERVICE_USER} 和组 ${SERVICE_GROUP}？ (y/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            userdel "$SERVICE_USER" 2>/dev/null || true
            groupdel "$SERVICE_GROUP" 2>/dev/null || true
            print_info "已删除用户和组"
        else
            print_info "保留用户和组"
        fi
    else
        print_warn "已开启 --force，删除服务用户与组。"
        userdel "$SERVICE_USER" 2>/dev/null || true
        groupdel "$SERVICE_GROUP" 2>/dev/null || true
        print_info "已删除用户和组"
    fi

    print_info "卸载完成！"
}

backup() {
    print_step "开始备份 FastAPI 应用..."

    # 检查安装目录是否存在
    if [ ! -d "$INSTALL_DIR" ]; then
        print_error "安装目录不存在: $INSTALL_DIR"
        print_error "请先安装应用后再执行备份。"
        return 1
    fi

    # 生成备份文件名（带时间戳）
    local TIMESTAMP
    TIMESTAMP=$(date +"%Y%m%d_%H%M%S" 2>/dev/null || echo "backup")
    local BACKUP_NAME="${PROJECT_NAME}_backup_${TIMESTAMP}.tar.gz"
    
    # 备份文件保存位置（默认保存在安装目录的父目录）
    local BACKUP_DIR
    BACKUP_DIR=$(dirname "$INSTALL_DIR")
    local BACKUP_PATH="${BACKUP_DIR}/${BACKUP_NAME}"

    # 询问用户是否指定备份路径
    echo ""
    read -p "备份文件将保存到: $BACKUP_PATH (直接回车使用默认路径，或输入自定义路径): " USER_BACKUP_PATH
    if [ -n "$USER_BACKUP_PATH" ]; then
        BACKUP_PATH="$USER_BACKUP_PATH"
        # 如果用户只输入了文件名，则使用默认目录
        if [ "$(dirname "$BACKUP_PATH")" = "." ] || [ "$(dirname "$BACKUP_PATH")" = "$BACKUP_PATH" ]; then
            BACKUP_PATH="${BACKUP_DIR}/${BACKUP_PATH}"
        fi
    fi

    # 确保备份目录存在
    local BACKUP_DIR_PATH
    BACKUP_DIR_PATH=$(dirname "$BACKUP_PATH")
    if [ ! -d "$BACKUP_DIR_PATH" ]; then
        print_info "创建备份目录: $BACKUP_DIR_PATH"
        mkdir -p "$BACKUP_DIR_PATH" || {
            print_error "无法创建备份目录: $BACKUP_DIR_PATH"
            return 1
        }
    fi

    # 检查备份文件是否已存在
    if [ -f "$BACKUP_PATH" ]; then
        print_warn "备份文件已存在: $BACKUP_PATH"
        read -p "是否覆盖？(y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            print_info "取消备份"
            return 0
        fi
        rm -f "$BACKUP_PATH"
    fi

    print_info "正在创建备份..."
    print_info "源目录: $INSTALL_DIR"
    print_info "备份文件: $BACKUP_PATH"
    print_info "排除环境相关文件（venv, caddy, .env, .cache 等）..."

    # 切换到安装目录的父目录，以便备份时保持相对路径
    cd "$(dirname "$INSTALL_DIR")" || {
        print_error "无法切换到目录: $(dirname "$INSTALL_DIR")"
        return 1
    }

    # 使用 tar 创建压缩包，应用排除规则
    local INSTALL_DIR_BASENAME
    INSTALL_DIR_BASENAME=$(basename "$INSTALL_DIR")
    
    # 构建排除参数数组
    local EXCLUDE_ARGS=()
    while IFS= read -r exclude_pattern; do
        EXCLUDE_ARGS+=("$exclude_pattern")
    done < <(get_backup_exclude_patterns)
    
    # 执行备份命令
    if ! tar -czf "$BACKUP_PATH" "${EXCLUDE_ARGS[@]}" "$INSTALL_DIR_BASENAME" 2>/dev/null; then
        print_error "备份失败，请检查磁盘空间和权限"
        print_error "如果问题持续，请检查 tar 命令是否可用"
        return 1
    fi

    # 验证备份文件
    if [ ! -f "$BACKUP_PATH" ]; then
        print_error "备份文件创建失败"
        return 1
    fi

    # 获取备份文件大小
    local BACKUP_SIZE
    if command -v du &> /dev/null; then
        BACKUP_SIZE=$(du -h "$BACKUP_PATH" | cut -f1)
    else
        BACKUP_SIZE="未知"
    fi

    print_info "备份完成！✓"
    echo ""
    print_info "备份文件: $BACKUP_PATH"
    print_info "文件大小: $BACKUP_SIZE"
    echo ""
    print_info "使用方法："
    print_info "  1. 将备份文件传输到新环境"
    print_info "  2. 在新环境中解压: tar -xzf $BACKUP_NAME"
    print_info "  3. 进入解压后的目录，运行: ./tools/fastapi_deploy.sh install"
    echo ""
}

show_menu() {
    while true; do
        echo ""
        print_info "=========================================="
        print_info " FastAPI 应用 管理脚本"
        print_info "=========================================="
        echo ""
        echo " 1) 安装 / 更新"
        echo " 2) 查看当前配置"
        echo " 3) 切换访问模式（域名 / IP）"
        echo " 4) 运行管理（服务 / 日志）"
        echo " 5) 备份"
        echo " 6) 卸载"
        echo " 7) 退出"
        echo ""
        read -p "请选择 [1-7]: " choice

        case "$choice" in
            1)
                echo ""
                print_step "开始安装 / 更新 FastAPI 应用..."
                install
                ;;
            2)
                echo ""
                print_step "查看当前配置..."
                show_current_config
                ;;
            3)
                echo ""
                print_step "切换访问模式（域名 / IP）..."
                interactive_change_mode
                ;;
            4)
                echo ""
                print_step "运行管理..."
                echo " 1) 启动服务"
                echo " 2) 停止服务"
                echo " 3) 重启服务"
                echo " 4) 查看状态"
                echo " 5) 查看最近日志（应用）"
                echo " 6) 查看最近日志（Caddy）"
                echo " 7) 返回上级菜单"
                read -p "请选择 [1-7]: " svc_choice
                case "$svc_choice" in
                    1)
                        if app_service_start; then
                            print_info "服务已启动或已重启 ✓"
                        fi
                        ;;
                    2)
                        app_service_stop
                        print_info "停止命令已执行（如服务在运行则已停止）"
                        ;;
                    3)
                        if app_service_restart; then
                            print_info "服务已重启 ✓"
                        fi
                        ;;
                    4)
                        app_service_status
                        ;;
                    5)
                        echo ""
                        print_step "查看应用最近 100 行日志..."
                        journalctl -u "${PROJECT_NAME}.service" -n 100 --no-pager || print_warn "无法读取日志（可能需要 root 或 sudo）"
                        ;;
                    6)
                        echo ""
                        print_step "查看 Caddy 最近 100 行日志..."
                        journalctl -u caddy -n 100 --no-pager || print_warn "无法读取 Caddy 日志（可能尚未安装或需要 root）"
                        ;;
                    *)
                        ;;
                esac
                ;;
            5)
                echo ""
                print_step "备份 FastAPI 应用..."
                backup
                ;;
            6)
                echo ""
                print_step "卸载 FastAPI 应用..."
                check_root_or_sudo
                uninstall
                ;;
            7) break ;;
            *)
                echo ""
                print_warn "无效的选择，请输入 1-7 之间的数字。"
                ;;
        esac
    done
}

main() {
    parse_args "$@"
    # 在处理子命令前，从已安装环境中加载现有配置，便于交互时使用默认值
    load_existing_config

    case "${COMMAND:-menu}" in
        menu)      show_menu ;;
        install)   install ;;
        uninstall) check_root_or_sudo; uninstall ;;
        *)         print_usage; exit 1 ;;
    esac
}

main "$@"


