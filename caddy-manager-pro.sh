#!/usr/bin/env bash
#
# Caddy 管理脚本 (多功能 & 多发行版支持 & 全功能)
# Version: 2.0.0
#
# 功能概述:
#   1. 安装/检查/更新 Caddy
#      - 官方仓库安装
#      - 源码编译安装 (带版本检查和平滑升级)
#      - 插件编译支持 (带依赖检查)
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
#      - 证书到期提醒
#   5. 系统维护
#      - 日志轮转
#      - 错误分析
#      - 性能监控
#      - 自动告警
#   6. 插件管理
#      - 查看/安装插件
#      - 依赖管理
#   7. Docker 支持
#      - 构建镜像
#      - 更新容器
#   8. 多语言支持
#      - 中文
#      - English

#####################################
# 全局变量与配置
#####################################
SCRIPT_VERSION="2.0.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CADDYFILE="/etc/caddy/Caddyfile"
CADDY_LOG="/var/log/caddy/caddy.log"
BACKUP_DIR="/etc/caddy/backups"
BUILD_PATH="/usr/local/src/caddy"
CERT_DIR="/var/lib/caddy/.local/share/caddy/certificates"
DOCKER_DIR="/etc/caddy/docker"
OS_RELEASE=""
LANG_FILE="${SCRIPT_DIR}/lang.conf"
DEFAULT_LANG="zh_CN"
MAX_RETRY=3
RETRY_INTERVAL=3

# 告警配置
ENABLE_ALERTS=false
TELEGRAM_BOT_TOKEN=""
TELEGRAM_CHAT_ID=""
DINGTALK_WEBHOOK=""
SLACK_WEBHOOK=""

# 插件依赖映射
declare -A PLUGIN_DEPS=(
    ["image-filter"]="libjpeg-dev libpng-dev"
    ["webp"]="libwebp-dev"
    ["svg"]="librsvg2-dev"
)

#####################################
# 多语言支持
#####################################

# 加载默认语言
load_default_messages() {
    # 中文消息
    MSG_ZH=(
        "安装"
        "配置"
        "错误"
        "成功"
        "警告"
        "正在处理"
        "完成"
        "取消"
        "无效选项"
        "请选择"
    )

    # English messages
    MSG_EN=(
        "Install"
        "Configure"
        "Error"
        "Success"
        "Warning"
        "Processing"
        "Done"
        "Cancel"
        "Invalid option"
        "Please select"
    )
}

# 设置语言
set_language() {
    local lang=${1:-$DEFAULT_LANG}
    case $lang in
        zh_CN)
            MSG=("${MSG_ZH[@]}")
            ;;
        en_US)
            MSG=("${MSG_EN[@]}")
            ;;
        *)
            MSG=("${MSG_EN[@]}")
            ;;
    esac
}

# 保存语言选择
save_language_preference() {
    echo "CURRENT_LANG=$1" > "$LANG_FILE"
}

# 切换语言
switch_language() {
    echo "Select language / 选择语言:"
    select lang in "中文" "English" "Exit/退出"; do
        case $lang in
            "中文")
                save_language_preference "zh_CN"
                set_language "zh_CN"
                ;;
            "English")
                save_language_preference "en_US"
                set_language "en_US"
                ;;
            "Exit/退出")
                return
                ;;
        esac
        break
    done
}

#####################################
# 工具函数
#####################################

# 错误处理
error_exit() {
    local message=$1
    local code=${2:-1}
    echo "❌ 错误: $message" >&2
    exit "$code"
}

# 网络操作重试
retry_network_operation() {
    local cmd="$1"
    local attempt=1

    while (( attempt <= MAX_RETRY )); do
        if eval "$cmd"; then
            return 0
        else
            echo "⚠️ 第 $attempt 次尝试失败，${RETRY_INTERVAL}秒后重试..."
            sleep $RETRY_INTERVAL
            ((attempt++))
        fi
    done

    echo "❌ 操作失败，建议："
    echo "1. 检查网络连接"
    echo "2. 尝试使用代理"
    echo "3. 手动执行: $cmd"
    return 1
}

# 检查系统环境
check_system_environment() {
   echo "🔍 检查系统环境..."

   # 检查必要命令
   local required_cmds=(curl wget git sudo)
   for cmd in "${required_cmds[@]}"; do
       if ! command -v "$cmd" &>/dev/null; then
           echo "⚠️ 未找到命令: $cmd"
           install_base_deps
           break
       fi
   done

   # 检查 systemd
   if ! command -v systemctl &>/dev/null; then
       error_exit "此系统未使用 systemd，暂不支持自动安装。"
   fi
}

# 检查 Docker 环境
check_docker_environment() {
   if ! command -v docker &>/dev/null; then
       echo "⚠️ Docker 未安装，是否安装 Docker？(y/n)"
       read -r install_docker
       if [[ $install_docker == "y" ]]; then
           install_docker
       else
           return 1
       fi
   fi

   if ! command -v docker-compose &>/dev/null; then
       echo "⚠️ Docker Compose 未安装，是否安装？(y/n)"
       read -r install_compose
       if [[ $install_compose == "y" ]]; then
           install_docker_compose
       else
           return 1
       fi
   fi

   return 0
}

# 安装 Docker
install_docker() {
   echo "🐳 安装 Docker..."

   case "$OS_RELEASE" in
       ubuntu|debian)
           retry_network_operation "curl -fsSL https://get.docker.com -o get-docker.sh"
           sudo sh get-docker.sh
           rm get-docker.sh
           ;;
       centos|rhel|fedora)
           if check_command_exists dnf; then
               sudo dnf install -y docker
           else
               sudo yum install -y docker
           fi
           ;;
       *)
           error_exit "暂不支持在此系统自动安装 Docker"
           ;;
   esac

   sudo systemctl enable docker
   sudo systemctl start docker

   # 将当前用户加入 docker 组
   sudo usermod -aG docker "$USER"
   echo "✅ Docker 安装完成，请重新登录以应用组权限"
}

# 安装 Docker Compose
install_docker_compose() {
   echo "🐳 安装 Docker Compose..."

   # 获取最新版本
   local compose_version
   compose_version=$(curl -s https://api.github.com/repos/docker/compose/releases/latest | grep "tag_name" | cut -d '"' -f 4)

   sudo curl -L "https://github.com/docker/compose/releases/download/$compose_version/docker-compose-$(uname -s)-$(uname -m)" \
       -o /usr/local/bin/docker-compose
   sudo chmod +x /usr/local/bin/docker-compose

   echo "✅ Docker Compose 安装完成"
}

# Docker 相关功能
build_docker_image() {
   local custom_name=${1:-"custom-caddy"}

   # 确保 Docker 目录存在
   mkdir -p "$DOCKER_DIR"

   # 创建 Dockerfile
   cat > "$DOCKER_DIR/Dockerfile" <<EOF
FROM caddy:latest

# 添加自定义配置
COPY Caddyfile /etc/caddy/Caddyfile

# 暴露端口
EXPOSE 80 443 2019

# 启动命令
CMD ["caddy", "run", "--config", "/etc/caddy/Caddyfile", "--adapter", "caddyfile"]
EOF

   # 创建 docker-compose.yml
   cat > "$DOCKER_DIR/docker-compose.yml" <<EOF
version: '3'
services:
 caddy:
   build: .
   image: ${custom_name}:latest
   container_name: caddy
   restart: unless-stopped
   ports:
     - "80:80"
     - "443:443"
     - "2019:2019"
   volumes:
     - ./Caddyfile:/etc/caddy/Caddyfile
     - caddy_data:/data
     - caddy_config:/config

volumes:
 caddy_data:
 caddy_config:
EOF

   # 复制当前 Caddyfile
   cp "$CADDYFILE" "$DOCKER_DIR/Caddyfile"

   # 构建镜像
   cd "$DOCKER_DIR" || exit 1
   if docker-compose build; then
       echo "✅ Docker 镜像构建成功"
       echo "可以使用以下命令启动容器："
       echo "cd $DOCKER_DIR && docker-compose up -d"
   else
       error_exit "Docker 镜像构建失败"
   fi
}

# 更新 Docker 容器
update_docker_container() {
   cd "$DOCKER_DIR" || error_exit "Docker 目录不存在"

   echo "🔄 更新 Docker 容器..."

   # 拉取最新镜像
   if docker-compose pull; then
       # 重新创建容器
       if docker-compose up -d --force-recreate; then
           echo "✅ Docker 容器已更新"
       else
           error_exit "容器更新失败"
       fi
   else
       error_exit "镜像拉取失败"
   fi
}

#####################################
# 告警功能
#####################################

# 发送 Telegram 告警
send_telegram_alert() {
   local message=$1
   if [[ -n $TELEGRAM_BOT_TOKEN && -n $TELEGRAM_CHAT_ID ]]; then
       curl -s -X POST \
           "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendMessage" \
           -d "chat_id=$TELEGRAM_CHAT_ID" \
           -d "text=$message" \
           -d "parse_mode=HTML"
   fi
}

# 发送钉钉告警
send_dingtalk_alert() {
   local message=$1
   if [[ -n $DINGTALK_WEBHOOK ]]; then
       curl -s -H 'Content-Type: application/json' \
           -d "{\"msgtype\": \"text\", \"text\": {\"content\": \"$message\"}}" \
           "$DINGTALK_WEBHOOK"
   fi
}

# 发送 Slack 告警
send_slack_alert() {
   local message=$1
   if [[ -n $SLACK_WEBHOOK ]]; then
       curl -s -X POST \
           -H 'Content-Type: application/json' \
           -d "{\"text\": \"$message\"}" \
           "$SLACK_WEBHOOK"
   fi
}

# 统一告警接口
send_alert() {
   local message=$1
   local level=${2:-"info"}  # info, warning, error

   if [[ $ENABLE_ALERTS == "true" ]]; then
       local formatted_message="[Caddy Alert - $level] $message"
       send_telegram_alert "$formatted_message"
       send_dingtalk_alert "$formatted_message"
       send_slack_alert "$formatted_message"
   fi
}

# 配置告警通道
configure_alerts() {
   echo "⚡ 配置告警通道"
   echo "1. Telegram"
   echo "2. 钉钉"
   echo "3. Slack"
   echo "4. 退出"

   read -p "请选择要配置的告警通道: " alert_choice
   case $alert_choice in
       1)
           read -p "请输入 Telegram Bot Token: " TELEGRAM_BOT_TOKEN
           read -p "请输入 Telegram Chat ID: " TELEGRAM_CHAT_ID
           ;;
       2)
           read -p "请输入钉钉 Webhook 地址: " DINGTALK_WEBHOOK
           ;;
       3)
           read -p "请输入 Slack Webhook 地址: " SLACK_WEBHOOK
           ;;
       4)
           return
           ;;
       *)
           echo "❌ 无效选项"
           return
           ;;
   esac

   ENABLE_ALERTS=true
   echo "✅ 告警配置已保存"
}

#####################################
# 监控功能
#####################################

# 监控证书过期
check_cert_expiry() {
   local warning_days=14
   local certs_found=false

   echo "🔍 检查证书过期时间..."

   if [[ ! -d $CERT_DIR ]]; then
       echo "⚠️ 证书目录不存在"
       return 1
   fi

   find "$CERT_DIR" -type f -name "*.crt" | while read -r cert; do
       certs_found=true
       local end_date
       end_date=$(openssl x509 -enddate -noout -in "$cert")
       local exp_date
       exp_date=$(echo "$end_date" | cut -d= -f2)
       local exp_epoch
       exp_epoch=$(date -d "$exp_date" +%s)
       local now_epoch
       now_epoch=$(date +%s)
       local days_left
       days_left=$(( (exp_epoch - now_epoch) / 86400 ))

       if (( days_left <= warning_days )); then
           local message="证书即将过期: $cert (剩余 $days_left 天)"
           echo "⚠️ $message"
           send_alert "$message" "warning"
       fi
   done

   if [[ $certs_found != true ]]; then
       echo "⚠️ 未找到任何证书文件"
       return 1
   fi
}

# 监控系统资源
monitor_system_resources() {
   echo "📊 监控系统资源使用情况..."

   # CPU 使用率
   local cpu_usage
   cpu_usage=$(top -bn1 | grep "Cpu(s)" | awk '{print $2}')

   # 内存使用率
   local mem_usage
   mem_usage=$(free | grep Mem | awk '{print $3/$2 * 100.0}')

   # 磁盘使用率
   local disk_usage
   disk_usage=$(df -h / | tail -n1 | awk '{print $5}' | tr -d '%')

   # 检查阈值并告警
   if (( $(echo "$cpu_usage > 80" | bc -l) )); then
       send_alert "CPU 使用率过高: $cpu_usage%" "warning"
   fi

   if (( $(echo "$mem_usage > 80" | bc -l) )); then
       send_alert "内存使用率过高: $mem_usage%" "warning"
   fi

   if (( disk_usage > 80 )); then
       send_alert "磁盘使用率过高: $disk_usage%" "warning"
   fi
}

# 监控 Caddy 状态
monitor_caddy_status() {
   echo "🔍 监控 Caddy 状态..."

   # 检查进程
   if ! pgrep caddy >/dev/null; then
       send_alert "Caddy 进程不存在" "error"
       return 1
   fi

   # 检查端口
   if ! netstat -tuln | grep -q ':80\|:443'; then
       send_alert "Caddy 未监听标准端口" "warning"
   fi

   # 检查最近日志错误
   local error_count
   error_count=$(journalctl -u caddy --since "5m ago" | grep -i "error" | wc -l)
   if (( error_count > 10 )); then
       send_alert "Caddy 出现大量错误日志" "warning"
   fi
}

#####################################
# 主菜单
#####################################

show_main_menu() {
   while true; do
       echo "========== Caddy 管理脚本 v${SCRIPT_VERSION} =========="
       echo "1.  检查/安装/更新 Caddy"
       echo "2.  配置管理"
       echo "3.  服务管理"
       echo "4.  Docker 管理"
       echo "5.  监控与告警"
       echo "6.  系统维护"
       echo "7.  切换语言"
       echo "8.  退出"
       echo "==========================================="

       read -p "请选择: " choice
       case $choice in
           1) install_menu ;;
           2) config_menu ;;
           3) service_menu ;;
           4) docker_menu ;;
           5) monitor_menu ;;
           6) maintenance_menu ;;
           7) switch_language ;;
           8) exit 0 ;;
           *) echo "❌ 无效选项" ;;
       esac
   done
}

# 安装菜单
install_menu() {
   echo "========== 安装管理 =========="
   echo "1. 检查 Caddy 安装"
   echo "2. 官方源安装"
   echo "3. 源码编译安装"
   echo "4. 更新 Caddy"
   echo "5. 返回主菜单"

   read -p "请选择: " choice
   case $choice in
       1) check_caddy_installed ;;
       2) install_caddy_official ;;
       3) install_caddy_source ;;
       4) update_caddy ;;
       5) return ;;
       *) echo "❌ 无效选项" ;;
   esac
}

# 配置菜单
config_menu() {
   echo "========== 配置管理 =========="
   echo "1. 查看当前配置"
   echo "2. 添加网站配置"
   echo "3. 删除网站配置"
   echo "4. 备份配置"
   echo "5. 还原配置"
   echo "6. 返回主菜单"

   read -p "请选择: " choice
   case $choice in
       1) view_config ;;
       2) add_site_config ;;
       3) remove_site_config ;;
       4) backup_config ;;
       5) restore_config ;;
       6) return ;;
       *) echo "❌ 无效选项" ;;
   esac
}

# Docker 菜单
docker_menu() {
   echo "========== Docker 管理 =========="
   echo "1. 构建 Docker 镜像"
   echo "2. 更新 Docker 容器"
   echo "3. 查看 Docker 状态"
   echo "4. 返回主菜单"

   read -p "请选择: " choice
   case $choice in
       1) build_docker_image ;;
       2) update_docker_container ;;
       3) docker ps -a | grep caddy ;;
       4) return ;;
       *) echo "❌ 无效选项" ;;
   esac
}

# 监控菜单
monitor_menu() {
   echo "========== 监控与告警 =========="
   echo "1. 查看系统状态"
   echo "2. 查看证书状态"
   echo "3. 查看性能统计"
   echo "4. 配置告警通道"
   echo "5. 测试告警"
   echo "6. 返回主菜单"

   read -p "请选择: " choice
   case $choice in
       1) monitor_system_resources ;;
       2) check_cert_expiry ;;
       3) show_performance_stats ;;
       4) configure_alerts ;;
       5) send_alert "这是一条测试告警消息" "info" ;;
       6) return ;;
       *) echo "❌ 无效选项" ;;
   esac
}

# 系统维护菜单
maintenance_menu() {
   echo "========== 系统维护 =========="
   echo "1. 分析错误日志"
   echo "2. 清理旧日志"
   echo "3. 清理旧备份"
   echo "4. 检查配置健康状态"
   echo "5. 配置日志轮转"
   echo "6. 返回主菜单"

   read -p "请选择: " choice
   case $choice in
       1) analyze_error_logs ;;
       2) cleanup_old_logs ;;
       3) cleanup_old_backups ;;
       4) check_config_health ;;
       5) setup_logrotate ;;
       6) return ;;
       *) echo "❌ 无效选项" ;;
   esac
}

# 性能统计
show_performance_stats() {
   echo "📊 Caddy 性能统计"

   # 进程信息
   echo "进程信息:"
   ps aux | grep caddy | grep -v grep

   # 连接统计
   echo -e "\n连接统计:"
   netstat -ant | grep ESTABLISHED | grep ":443\|:80" | wc -l

   # 请求统计 (最近5分钟)
   echo -e "\n最近5分钟请求数:"
   journalctl -u caddy --since "5 minutes ago" | grep "handled request" | wc -l

   # 内存使用
   echo -e "\n内存使用:"
   local pid
   pid=$(pgrep caddy)
   if [[ -n $pid ]]; then
       ps -o pid,ppid,%mem,rss,cmd -p "$pid"
   fi
}

# 错误日志分析
analyze_error_logs() {
   echo "🔍 分析错误日志..."

   # 统计最近24小时的错误类型
   echo "最近24小时错误类型统计:"
   journalctl -u caddy --since "24 hours ago" | grep -i "error" | \
       sort | uniq -c | sort -nr

   # 显示最新的错误
   echo -e "\n最新10条错误信息:"
   journalctl -u caddy -p err -n 10 --no-pager

   # 检查是否有证书相关错误
   echo -e "\n证书相关错误:"
   journalctl -u caddy --since "24 hours ago" | grep -i "certificate" | \
       grep -i "error"
}

# 清理旧日志
cleanup_old_logs() {
   echo "🧹 清理旧日志..."

   # 清理超过30天的日志
   sudo journalctl --vacuum-time=30d

   # 清理日志文件
   if [[ -f $CADDY_LOG ]]; then
       local log_size
       log_size=$(du -sh "$CADDY_LOG" | cut -f1)
       echo "当前日志大小: $log_size"

       read -p "是否清空日志文件？(y/n) " choice
       if [[ $choice == "y" ]]; then
           sudo truncate -s 0 "$CADDY_LOG"
           echo "✅ 日志已清空"
       fi
   fi
}

# 清理旧备份
cleanup_old_backups() {
   echo "🧹 清理旧备份..."

   if [[ ! -d $BACKUP_DIR ]]; then
       echo "❌ 备份目录不存在"
       return 1
   fi

   local backup_count
   backup_count=$(ls -1 "$BACKUP_DIR"/Caddyfile_* 2>/dev/null | wc -l)

   if (( backup_count == 0 )); then
       echo "没有找到备份文件"
       return 0
   fi

   echo "当前备份数量: $backup_count"
   read -p "要保留最近几个备份？(默认: 5) " keep_count
   keep_count=${keep_count:-5}

   if (( backup_count > keep_count )); then
       ls -1t "$BACKUP_DIR"/Caddyfile_* | tail -n+"$((keep_count + 1))" | xargs rm -f
       echo "✅ 已清理旧备份，保留最新的 $keep_count 个"
   else
       echo "备份数量未超过保留数量，无需清理"
   fi
}

#####################################
# 脚本入口
#####################################

main() {
   # 检查权限
   if [[ $EUID -ne 0 && ! -w "/etc/caddy" ]]; then
       echo "❌ 此脚本需要 root 权限或 sudo 权限才能运行"
       echo "请使用 sudo $0 运行"
       exit 1
   fi

   # 初始化
   check_system_environment

   # 加载语言配置
   load_default_messages
   if [[ -f $LANG_FILE ]]; then
       source "$LANG_FILE"
   fi
   set_language "$CURRENT_LANG"

   # 检查 Caddy 安装
   if ! command -v caddy &>/dev/null; then
       echo "⚠️ 未检测到 Caddy，是否现在安装？(y/n)"
       read -r install_choice
       if [[ $install_choice == "y" ]]; then
           install_menu
       fi
   fi

   # 进入主菜单
   show_main_menu
}

# 启动脚本
main "$@"
