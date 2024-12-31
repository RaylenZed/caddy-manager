#!/usr/bin/env bash
#
# Caddy 管理脚本 (多功能 & 多发行版支持 & 全功能)
#
# 功能概述:
#   1. 安装/检查 Caddy
#      - 官方仓库安装
#      - 源码编译安装 (获取最新修复)
#      - 插件编译支持
#   2. 配置管理
#      - 添加最小化/完善配置
#      - 删除/查看/验证配置
#      - 备份/还原/清理配置
#   3. 服务管理
#      - 启动/停止/重载
#      - 查看状态/日志
#      - 性能监控
#   4. 证书管理
#      - 查看/更新证书
#      - 导出证书
#   5. 系统维护
#      - 日志轮转
#      - 错误分析
#      - 性能监控
#   6. 插件管理
#      - 查看/安装插件
#      - 重新编译

#####################################
# 全局变量与配置
#####################################
CADDYFILE="/etc/caddy/Caddyfile"
CADDY_LOG="/var/log/caddy/caddy.log"
BACKUP_DIR="/etc/caddy/backups"
BUILD_PATH="/usr/local/src/caddy"  # 源码编译目录
CERT_DIR="/var/lib/caddy/.local/share/caddy/certificates"
OS_RELEASE=""
PLUGIN_BUILD_DEPS=()  # 插件编译依赖

#####################################
# 基础工具函数
#####################################

# 检测系统类型
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_RELEASE=$ID
    elif [ -f /etc/redhat-release ]; then
        OS_RELEASE="rhel"
    else
        OS_RELEASE="unknown"
    fi
}

# 检查命令是否存在
check_command_exists() {
    local cmd="$1"
    command -v "$cmd" &>/dev/null
}

# 安装基础依赖
install_base_deps() {
    echo "📦 安装基础依赖..."
    case "$OS_RELEASE" in
        ubuntu|debian)
            sudo apt update
            sudo apt install -y curl wget git lsof
            ;;
        centos|rhel|fedora)
            if check_command_exists dnf; then
                sudo dnf install -y curl wget git lsof
            else
                sudo yum install -y curl wget git lsof
            fi
            ;;
        arch)
            sudo pacman -Syu --noconfirm
            sudo pacman -S --noconfirm curl wget git lsof
            ;;
        opensuse|suse)
            sudo zypper refresh
            sudo zypper install -y curl wget git lsof
            ;;
    esac
}

# 检查是否为 root 或有 sudo 权限
check_root_or_sudo() {
    if ! sudo -v &>/dev/null; then
        echo "❌ 此脚本需要 root 权限或 sudo 权限才能运行。"
        exit 1
    fi
}

# 确保目录存在
ensure_dirs_exist() {
    local dirs=("$BACKUP_DIR" "$(dirname "$CADDY_LOG")" "$(dirname "$CADDYFILE")")
    for dir in "${dirs[@]}"; do
        if [[ ! -d "$dir" ]]; then
            sudo mkdir -p "$dir"
        fi
    done
}

#####################################
# 安装相关
#####################################

# 检查 Caddy 是否已安装
check_caddy_installed() {
    if ! check_command_exists "caddy"; then
        echo "❌ 未检测到 Caddy。"
        echo "请选择安装方式："
        select install_type in "官方仓库安装" "源码编译安装" "源码编译安装(带插件)" "取消"; do
            case $install_type in
                "官方仓库安装" )
                    install_caddy_official
                    break
                    ;;
                "源码编译安装" )
                    compile_caddy_latest
                    break
                    ;;
                "源码编译安装(带插件)" )
                    compile_caddy_with_plugins
                    break
                    ;;
                "取消" )
                    echo "已取消安装。"
                    exit 1
                    ;;
                * )
                    echo "❌ 无效选项。"
                    ;;
            esac
        done
    else
        echo "✅ Caddy 已安装，版本：$(caddy version)"
    fi
}

# 官方仓库安装
install_caddy_official() {
    echo "🔧 开始从官方仓库安装 Caddy (系统: $OS_RELEASE)"
    install_base_deps

    case "$OS_RELEASE" in
        ubuntu|debian)
            sudo apt install -y debian-keyring debian-archive-keyring apt-transport-https
            curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
            curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | sudo tee /etc/apt/sources.list.d/caddy-stable.list
            sudo apt update
            sudo apt install -y caddy
            ;;
        centos|rhel|fedora)
            if check_command_exists dnf; then
                sudo dnf install -y dnf-plugins-core epel-release
                sudo dnf config-manager --add-repo https://dl.cloudsmith.io/public/caddy/stable/rpm.repo
                sudo dnf install -y caddy
            else
                sudo yum install -y yum-plugin-copr epel-release
                sudo yum copr enable @caddy/caddy
                sudo yum install -y caddy
            fi
            ;;
        arch)
            sudo pacman -Syu --noconfirm
            sudo pacman -S --noconfirm caddy
            ;;
        opensuse|suse)
            sudo zypper refresh
            sudo zypper install -y caddy
            ;;
        *)
            echo "⚠️ 未能自动适配此系统，请手动安装。"
            exit 1
            ;;
    esac

    post_install_steps
}

# 安装后的通用步骤
post_install_steps() {
    ensure_dirs_exist
    sudo systemctl enable caddy
    sudo systemctl start caddy
    echo "✅ Caddy 安装完成，版本：$(caddy version)"
}

#####################################
# 编译安装相关
#####################################

# 安装 Go 环境
install_golang() {
    if ! check_command_exists go; then
        echo "📦 安装 Go 环境..."
        case "$OS_RELEASE" in
            ubuntu|debian)
                sudo apt update
                sudo apt install -y golang
                ;;
            centos|rhel|fedora)
                if check_command_exists dnf; then
                    sudo dnf install -y golang
                else
                    sudo yum install -y golang
                fi
                ;;
            arch)
                sudo pacman -S --noconfirm go
                ;;
            opensuse|suse)
                sudo zypper install -y go
                ;;
            *)
                echo "⚠️ 请手动安装 Go 环境"
                exit 1
                ;;
        esac
    fi
}

# 源码编译安装
compile_caddy_latest() {
    echo "🔧 准备从源码编译安装 Caddy..."

    # 安装依赖
    install_base_deps
    install_golang

    # 准备编译环境
    sudo rm -rf "$BUILD_PATH"
    sudo mkdir -p "$BUILD_PATH"
    sudo chown "$USER":"$USER" "$BUILD_PATH"

    # 克隆源码
    echo "📥 克隆 Caddy 源码..."
    git clone --depth=1 https://github.com/caddyserver/caddy.git "$BUILD_PATH"
    cd "$BUILD_PATH" || exit 1

    # 编译
    echo "🔨 开始编译..."
    go build -o caddy cmd/caddy/main.go

    if [[ ! -f "caddy" ]]; then
        echo "❌ 编译失败。"
        exit 1
    fi

    # 安装
    sudo mv caddy /usr/bin/
    sudo chmod +x /usr/bin/caddy
    create_systemd_service
    post_install_steps
}

# 创建 systemd 服务
create_systemd_service() {
    echo "📝 创建 systemd 服务文件..."

    sudo bash -c 'cat > /etc/systemd/system/caddy.service <<EOF
[Unit]
Description=Caddy Web Server
Documentation=https://caddyserver.com/docs/
After=network.target network-online.target
Requires=network-online.target

[Service]
Type=notify
User=caddy
Group=caddy
ExecStart=/usr/bin/caddy run --environ --config /etc/caddy/Caddyfile
ExecReload=/usr/bin/caddy reload --config /etc/caddy/Caddyfile
TimeoutStopSec=5s
LimitNOFILE=1048576
LimitNPROC=512
PrivateTmp=true
ProtectSystem=full
AmbientCapabilities=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
EOF'

    # 创建 caddy 用户和组(如果不存在)
    if ! id caddy &>/dev/null; then
        sudo useradd -r -s /sbin/nologin caddy
    fi

    sudo systemctl daemon-reload
}

#####################################
# 插件管理
#####################################

# 编译带插件的 Caddy
compile_caddy_with_plugins() {
    echo "🔌 准备编译带插件的 Caddy..."

    # 安装 xcaddy
    if ! check_command_exists xcaddy; then
        echo "📦 安装 xcaddy..."
        go install github.com/caddyserver/xcaddy/cmd/xcaddy@latest
    fi

    # 选择插件
    echo "可用的常用插件:"
    echo "1. cache      - 缓存插件"
    echo "2. ratelimit  - 限速插件"
    echo "3. cors       - CORS 插件"
    echo "4. jwt        - JWT 认证"
    echo "5. 自定义插件"

    read -p "请选择要安装的插件(多个插件用逗号分隔): " plugins

    # 准备插件参数
    local build_args=()
    IFS=',' read -ra ADDR <<< "$plugins"
    for plugin in "${ADDR[@]}"; do
        case "$plugin" in
            1|cache)
                build_args+=("--with github.com/caddyserver/cache-handler")
                ;;
            2|ratelimit)
                build_args+=("--with github.com/mholt/caddy-ratelimit")
                ;;
            3|cors)
                build_args+=("--with github.com/caddyserver/cors")
                ;;
            4|jwt)
                build_args+=("--with github.com/greenpau/caddy-jwt")
                ;;
            5)
                read -p "请输入插件的 GitHub 地址: " custom_plugin
                build_args+=("--with $custom_plugin")
                ;;
        esac
    done

    # 编译
    echo "🔨 开始编译带插件的 Caddy..."
    cd "$BUILD_PATH" || exit 1
    xcaddy build "${build_args[@]}"

    if [[ ! -f "caddy" ]]; then
        echo "❌ 编译失败。"
        exit 1
    fi

    # 安装
    sudo mv caddy /usr/bin/
    sudo chmod +x /usr/bin/caddy
    create_systemd_service
    post_install_steps
}

# 列出已安装的插件
list_installed_plugins() {
    echo "📋 已安装的 Caddy 模块:"
    caddy list-modules
}

#####################################
# 证书管理功能
#####################################

# 检查证书状态
check_cert_status() {
   echo "🔍 检查证书状态..."

   if [[ ! -d "$CERT_DIR" ]]; then
       echo "❌ 证书目录不存在: $CERT_DIR"
       return 1
   fi

   echo "📂 证书目录内容:"
   sudo ls -lh "$CERT_DIR"

   # 检查证书有效期
   echo -e "\n📜 证书有效期检查:"
   for cert in "$CERT_DIR"/**/*.crt; do
       if [[ -f "$cert" ]]; then
           echo "证书: $cert"
           sudo openssl x509 -in "$cert" -noout -dates
           echo "------------------------"
       fi
   done
}

# 强制更新证书
force_cert_renewal() {
   echo "🔄 强制更新所有证书..."
   sudo rm -rf "$CERT_DIR"/*
   sudo systemctl reload caddy
   echo "✅ 已触发证书更新，Caddy 将自动申请新证书。"
}

# 导出证书
export_certificates() {
   echo "📤 导出证书..."
   local export_dir="$HOME/caddy_certs_$(date +%Y%m%d)"

   # 创建导出目录
   mkdir -p "$export_dir"

   # 复制证书
   if [[ -d "$CERT_DIR" ]]; then
       sudo cp -r "$CERT_DIR"/* "$export_dir/"
       sudo chown -R "$USER":"$USER" "$export_dir"
       echo "✅ 证书已导出到: $export_dir"
   else
       echo "❌ 证书目录不存在"
   fi
}

# 证书管理主菜单
manage_certificates() {
   while true; do
       echo "========== 证书管理 =========="
       echo "1. 查看证书状态"
       echo "2. 强制更新证书"
       echo "3. 导出证书"
       echo "4. 返回主菜单"
       echo "============================"

       read -p "请选择操作: " cert_choice
       case $cert_choice in
           1) check_cert_status ;;
           2) force_cert_renewal ;;
           3) export_certificates ;;
           4) return ;;
           *) echo "❌ 无效选项" ;;
       esac
   done
}

#####################################
# 监控与分析
#####################################

# 分析错误日志
analyze_errors() {
   echo "🔍 分析最近 24 小时的错误日志..."

   # 统计错误类型及频率
   echo "错误统计:"
   sudo journalctl -u caddy -p err --since "24 hours ago" | \
       awk '{$1=$2=$3=$4=$5=""; print $0}' | \
       sort | uniq -c | sort -rn

   # 显示最近的错误详情
   echo -e "\n最近 10 条错误信息:"
   sudo journalctl -u caddy -p err --since "24 hours ago" -n 10

   # 检查是否有证书相关错误
   echo -e "\n证书相关错误:"
   sudo journalctl -u caddy --since "24 hours ago" | grep -i "certificate"
}

# 性能监控
monitor_performance() {
   echo "📊 Caddy 性能监控..."

   # 进程状态
   echo "进程状态:"
   ps aux | grep caddy | grep -v grep

   # 资源使用
   echo -e "\n资源使用统计:"
   local pid
   pid=$(pgrep caddy)
   if [[ -n "$pid" ]]; then
       echo "CPU 使用率: $(ps -p "$pid" -o %cpu | tail -n 1)%"
       echo "内存使用: $(ps -p "$pid" -o rss | tail -n 1 | awk '{print $1/1024 "MB"}')"
   fi

   # 连接统计
   echo -e "\n当前连接统计:"
   sudo lsof -i -n | grep caddy

   # 请求统计 (最近5分钟)
   echo -e "\n最近 5 分钟的请求数:"
   sudo journalctl -u caddy --since "5 minutes ago" | grep "handled request" | wc -l
}

# 系统资源监控
monitor_system() {
   echo "🖥️ 系统资源监控..."

   # CPU 负载
   echo "CPU 负载: $(uptime | awk -F'load average:' '{print $2}')"

   # 内存使用
   echo -e "\n内存使用:"
   free -h

   # 磁盘使用
   echo -e "\n磁盘使用:"
   df -h | grep -v "tmpfs"

   # 网络连接
   echo -e "\nTCP 连接统计:"
   sudo netstat -ant | awk '{print $6}' | sort | uniq -c | sort -rn
}

#####################################
# 主菜单与功能整合
#####################################

# 扩展的系统维护菜单
system_maintenance_menu() {
   while true; do
       echo "========== 系统维护 =========="
       echo "1. 分析错误日志"
       echo "2. 监控性能"
       echo "3. 系统资源监控"
       echo "4. 配置日志轮转"
       echo "5. 检查配置健康状态"
       echo "6. 返回主菜单"
       echo "============================="

       read -p "请选择操作: " maint_choice
       case $maint_choice in
           1) analyze_errors ;;
           2) monitor_performance ;;
           3) monitor_system ;;
           4) setup_logrotate ;;
           5) check_config_health ;;
           6) return ;;
           *) echo "❌ 无效选项" ;;
       esac

       echo -e "\n按 Enter 继续..."
       read -r
   done
}

# 更新主菜单，整合新功能
main_menu() {
   while true; do
       echo "========== Caddy 管理脚本 =========="
       echo "1.  检查/安装/更新 Caddy"
       echo "2.  添加最小化配置"
       echo "3.  添加完善配置"
       echo "4.  删除网站配置"
       echo "5.  启动 Caddy"
       echo "6.  停止 Caddy"
       echo "7.  重载 Caddy"
       echo "8.  查看 Caddy 日志"
       echo "9.  证书管理"
       echo "10. 配置管理"
       echo "11. 插件管理"
       echo "12. 系统维护"
       echo "13. 退出"
       echo "=================================="

       read -p "请选择一个选项: " choice
       case $choice in
           1)  check_caddy_installed ;;
           2)  add_minimal_config ;;
           3)  add_advanced_config ;;
           4)  delete_website_config ;;
           5)  start_caddy ;;
           6)  stop_caddy ;;
           7)  reload_caddy ;;
           8)  view_logs ;;
           9)  manage_certificates ;;
           10) config_management_menu ;;
           11) plugin_management_menu ;;
           12) system_maintenance_menu ;;
           13) exit 0 ;;
           *)  echo "❌ 无效选项" ;;
       esac
   done
}

# 配置管理子菜单
config_management_menu() {
   while true; do
       echo "========== 配置管理 =========="
       echo "1. 查看当前配置"
       echo "2. 备份配置"
       echo "3. 还原配置"
       echo "4. 列出备份"
       echo "5. 清理旧备份"
       echo "6. 返回主菜单"
       echo "============================"

       read -p "请选择操作: " config_choice
       case $config_choice in
           1) view_current_config ;;
           2) backup_caddy_config ;;
           3) restore_config ;;
           4) list_backup_files ;;
           5) cleanup_backups ;;
           6) return ;;
           *) echo "❌ 无效选项" ;;
       esac
   done
}

# 插件管理子菜单
plugin_management_menu() {
   while true; do
       echo "========== 插件管理 =========="
       echo "1. 查看已安装插件"
       echo "2. 安装新插件"
       echo "3. 返回主菜单"
       echo "============================"

       read -p "请选择操作: " plugin_choice
       case $plugin_choice in
           1) list_installed_plugins ;;
           2) compile_caddy_with_plugins ;;
           3) return ;;
           *) echo "❌ 无效选项" ;;
       esac
   done
}

#####################################
# 脚本入口
#####################################

# 前置检查
check_root_or_sudo
detect_os
ensure_dirs_exist

# 检查 Caddy 安装
check_caddy_installed

# 进入主菜单循环
while true; do
   main_menu
done
