#!/usr/bin/env bash
#
# Caddy 管理脚本 (多功能 & 多发行版支持 & 全功能)
# Version: 3.1.0
#
# 使用方法如下
# chmod +x caddy-manager.sh
# ./caddy-manager.sh help  # 查看使用说明
#

#####################################
# 常量定义
#####################################
readonly SCRIPT_VERSION="3.1.0"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly CADDYFILE="/etc/caddy/Caddyfile"
readonly CADDY_LOG="/var/log/caddy/caddy.log"
readonly CADDY_ACCESS_LOG="/var/log/caddy/access.log"
readonly CADDY_ERROR_LOG="/var/log/caddy/error.log"
readonly BACKUP_DIR="/etc/caddy/backups"
readonly BUILD_PATH="/usr/local/src/caddy"
readonly CERT_DIR="/var/lib/caddy/.local/share/caddy/certificates"
readonly LANG_FILE="${SCRIPT_DIR}/lang.conf"
readonly DEFAULT_LANG="zh_CN"

#####################################
# 可配置参数
#####################################
# 重试配置
MAX_RETRY=3
RETRY_INTERVAL=3

# 监控配置
HEALTH_CHECK_INTERVAL=300  # 5分钟
HEALTH_CHECK_TIMEOUT=10    # 10秒
HTTP_ERROR_THRESHOLD=10    # 10个错误触发告警
CPU_THRESHOLD=80          # CPU使用率阈值
MEM_THRESHOLD=80          # 内存使用率阈值
DISK_THRESHOLD=80         # 磁盘使用率阈值

# 告警配置
ENABLE_ALERTS=false
TELEGRAM_BOT_TOKEN=""
TELEGRAM_CHAT_ID=""
DINGTALK_WEBHOOK=""
SLACK_WEBHOOK=""
WEIXIN_WEBHOOK=""        # 企业微信webhook

# 日志分析配置
LOG_ANALYSIS_INTERVAL=3600  # 1小时
LOG_RETENTION_DAYS=30      # 日志保留30天
SLOW_REQUEST_THRESHOLD=2000 # 2秒以上记为慢请求

#####################################
# 工具函数
#####################################
error_exit() {
    local message=$1
    local code=${2:-1}
    local stack_trace
    stack_trace=$(caller)
    echo "❌ 错误: $message" >&2
    echo "位置: $stack_trace" >&2
    exit "$code"
}

log() {
    local level=$1
    local message=$2
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    case $level in
        info)  echo -e "[$timestamp] [INFO] $message" ;;
        warn)  echo -e "[$timestamp] [WARN] $message" >&2 ;;
        error) echo -e "[$timestamp] [ERROR] $message" >&2 ;;
    esac
}

log_info()  { log "info" "$1"; }
log_warn()  { log "warn" "$1"; }
log_error() { log "error" "$1"; }

# 验证输入
validate_input() {
    local input=$1
    local type=$2

    case $type in
        domain)
            [[ $input =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]] || return 1
            ;;
        port)
            [[ $input =~ ^[0-9]{1,5}$ && $input -le 65535 ]] || return 1
            ;;
        ip)
            [[ $input =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]] || return 1
            ;;
        path)
            [[ $input =~ ^[a-zA-Z0-9/_.-]+$ ]] || return 1
            ;;
    esac
    return 0
}

# 网络操作重试
retry_operation() {
    local cmd=$1
    local attempt=1

    while (( attempt <= MAX_RETRY )); do
        if eval "$cmd"; then
            return 0
        else
            log_warn "第 $attempt 次尝试失败，${RETRY_INTERVAL}秒后重试..."
            sleep $RETRY_INTERVAL
            ((attempt++))
        fi
    done

    return 1
}

#####################################
# 系统检查与初始化
#####################################
check_system() {
    # 检查root权限
    if [[ $EUID -ne 0 ]]; then
        error_exit "此脚本需要root权限运行"
    fi

    # 检查系统类型
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        OS_TYPE=$ID
    else
        error_exit "无法确定操作系统类型"
    fi

    # 检查必要命令
    local required_cmds=(curl wget systemctl awk sed grep)
    for cmd in "${required_cmds[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            install_dependencies
            break
        fi
    done
}

install_dependencies() {
    log_info "安装基础依赖..."
    case $OS_TYPE in
        ubuntu|debian)
            retry_operation "apt-get update"
            retry_operation "apt-get install -y curl wget systemctl gawk sed grep"
            ;;
        centos|rhel|fedora)
            retry_operation "yum install -y curl wget systemctl gawk sed grep"
            ;;
        *)
            error_exit "不支持的操作系统类型: $OS_TYPE"
            ;;
    esac
}

ensure_directories() {
    local dirs=(
        "$(dirname "$CADDYFILE")"
        "$(dirname "$CADDY_LOG")"
        "$(dirname "$CADDY_ACCESS_LOG")"
        "$(dirname "$CADDY_ERROR_LOG")"
        "$BACKUP_DIR"
        "$BUILD_PATH"
    )

    for dir in "${dirs[@]}"; do
        if [[ ! -d "$dir" ]]; then
            mkdir -p "$dir" || error_exit "无法创建目录: $dir"
            chmod 750 "$dir"
            chown root:caddy "$dir"
        fi
    done
}

#####################################
# Caddy 安装与管理
#####################################
install_caddy() {
    log_info "安装 Caddy..."

    case $OS_TYPE in
        ubuntu|debian)
            retry_operation "curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/setup.deb.sh' | bash"
            retry_operation "apt-get install caddy"
            ;;
        centos|rhel|fedora)
            retry_operation "curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/setup.rpm.sh' | bash"
            retry_operation "yum install caddy"
            ;;
    esac

    # 设置服务
    setup_caddy_service

    # 初始化配置
    if [[ ! -f $CADDYFILE ]]; then
        create_default_config
    fi
}

setup_caddy_service() {
    cat > /etc/systemd/system/caddy.service << EOF
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
MemoryLimit=1G
CPUQuota=200%
TasksMax=4096

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable caddy
    systemctl start caddy
}

create_default_config() {
    cat > "$CADDYFILE" << EOF
{
    email admin@example.com
    # 全局设置
    admin off  # 禁用管理API
    auto_https disable_redirects  # 禁用HTTP到HTTPS的自动重定向
    log {
        output file {
            filename "${CADDY_ACCESS_LOG}"
            roll_size 100mb
            roll_keep 10
        }
    }
}

# 示例配置
# example.com {
#     reverse_proxy localhost:8080
#     tls {
#         protocols tls1.2 tls1.3
#     }
#     encode gzip
# }
EOF

    chmod 640 "$CADDYFILE"
    chown root:caddy "$CADDYFILE"
}

#####################################
# 配置管理
#####################################
validate_config() {
    local config_file=$1

    # 语法检查
    if ! caddy fmt --config "$config_file" >/dev/null 2>&1; then
        return 1
    fi

    # 配置验证
    if ! caddy validate --config "$config_file" 2>/dev/null; then
        return 1
    fi

    return 0
}

backup_config() {
    local timestamp
    timestamp=$(date +%Y%m%d_%H%M%S)
    local backup_file="$BACKUP_DIR/Caddyfile_$timestamp"

    # 创建备份
    cp "$CADDYFILE" "$backup_file" || error_exit "配置备份失败"
    chmod 640 "$backup_file"

    # 压缩备份
    gzip -9 "$backup_file"

    log_info "配置已备份至: ${backup_file}.gz"

    # 清理旧备份
    find "$BACKUP_DIR" -name "Caddyfile_*.gz" -mtime +30 -delete
}

restore_config() {
    local backup_file=$1

    if [[ ! -f $backup_file ]]; then
        error_exit "备份文件不存在: $backup_file"
    fi

    # 解压缩（如果是压缩文件）
    if [[ $backup_file == *.gz ]]; then
        gunzip -c "$backup_file" > "${backup_file%.gz}"
        backup_file="${backup_file%.gz}"
    fi

    # 验证备份文件
    if ! validate_config "$backup_file"; then
        error_exit "备份文件验证失败"
    fi

    # 还原配置
    cp "$backup_file" "$CADDYFILE" || error_exit "配置还原失败"
    chmod 640 "$CADDYFILE"
    chown root:caddy "$CADDYFILE"

    # 重新加载配置
    reload_caddy

    log_info "配置已还原"
}

reload_caddy() {
    if ! systemctl is-active --quiet caddy; then
        systemctl start caddy || return 1
    else
        systemctl reload caddy || return 1
    fi
    return 0
}

#####################################
# 站点管理
#####################################
add_site() {
    local domain=$1
    local upstream=$2

    # 验证输入
    if ! validate_input "$domain" "domain"; then
        error_exit "无效的域名格式: $domain"
    fi

    # 检查是否已存在
    if grep -q "^$domain" "$CADDYFILE"; then
        error_exit "站点已存在: $domain"
    fi

    # 备份当前配置
    backup_config

    # 添加站点配置
    cat >> "$CADDYFILE" << EOF

$domain {
    reverse_proxy $upstream
    tls {
        protocols tls1.2 tls1.3
    }
    encode gzip
    log {
        output file $CADDY_LOG {
            roll_size 10MB
            roll_keep 10
        }
    }
}
EOF

    # 验证新配置
    if ! validate_config "$CADDYFILE"; then
        restore_config "$(ls -t "$BACKUP_DIR"/Caddyfile_* | head -1)"
        error_exit "配置验证失败"
    fi

    # 重载配置
    reload_caddy || error_exit "配置重载失败"

    log_info "站点添加成功: $domain"
}

remove_site() {
    local domain=$1

    # 验证输入
    if ! validate_input "$domain" "domain"; then
        error_exit "无效的域名格式: $domain"
    fi

    # 检查站点是否存在
    if ! grep -q "^$domain" "$CADDYFILE"; then
        error_exit "站点不存在: $domain"
    fi

    # 备份当前配置
    backup_config

    # 删除站点配置
    sed -i "/^$domain/,/^}/d" "$CADDYFILE"

    # 验证新配置
    if ! validate_config "$CADDYFILE"; then
        restore_config "$(ls -t "$BACKUP_DIR"/Caddyfile_* | head -1)"
        error_exit "配置验证失败"
    fi

    # 重载配置
    reload_caddy || error_exit "配置重载失败"

    log_info "站点删除成功: $domain"
}


#####################################
# 日志分析功能
#####################################
analyze_access_logs() {
    local hours=${1:-24}
    local log_file=$CADDY_ACCESS_LOG
    local start_time
    start_time=$(date -d "$hours hours ago" +%s)

    log_info "开始分析最近 $hours 小时的访问日志..."

    # 确保日志文件存在
    if [[ ! -f "$log_file" ]]; then
        error_exit "访问日志文件不存在: $log_file"
    fi

    # 统计基本指标
    local total_requests total_ips avg_response_time

    total_requests=$(wc -l < "$log_file")
    total_ips=$(awk '{print $1}' "$log_file" | sort -u | wc -l)
    avg_response_time=$(awk '{sum+=$NF} END {printf "%.2f", sum/NR}' "$log_file")

    # 统计HTTP状态码
    echo "=== 访问统计报告 ==="
    echo "分析时间范围: 最近 $hours 小时"
    echo "总请求数: $total_requests"
    echo "独立IP数: $total_ips"
    echo "平均响应时间: ${avg_response_time}ms"
    echo -e "\nHTTP状态码分布:"
    awk '{print $9}' "$log_file" | sort | uniq -c | sort -rn

    # Top 10 IP
    echo -e "\nTop 10访问IP:"
    awk '{print $1}' "$log_file" | sort | uniq -c | sort -rn | head -10

    # Top 10 URL
    echo -e "\nTop 10请求URL:"
    awk '{print $7}' "$log_file" | sort | uniq -c | sort -rn | head -10

    # Top 10 User Agent
    echo -e "\nTop 10 User Agent:"
    awk -F'"' '{print $6}' "$log_file" | sort | uniq -c | sort -rn | head -10

    # 流量统计
    echo -e "\n带宽使用统计:"
    awk '{sum+=$10} END {
        printf "总流量: %.2f GB\n", sum/1024/1024/1024;
        printf "平均请求大小: %.2f KB\n", (sum/NR)/1024
    }' "$log_file"

    # 按小时统计请求数
    echo -e "\n每小时请求数分布:"
    awk '{print $4}' "$log_file" | awk -F: '{print $2}' | sort | uniq -c | sort -k2n

    # 慢请求分析
    echo -e "\n慢请求分析 (>${SLOW_REQUEST_THRESHOLD}ms):"
    awk -v threshold="$SLOW_REQUEST_THRESHOLD" '$NF > threshold {
        printf "[%s] %s %s %sms\n", $4, $6, $7, $NF
    }' "$log_file" | tail -10
}

analyze_error_logs() {
    local hours=${1:-24}
    local log_file=$CADDY_ERROR_LOG
    local start_time
    start_time=$(date -d "$hours hours ago" +%s)

    log_info "开始分析错误日志..."

    # 确保日志文件存在
    if [[ ! -f "$log_file" ]]; then
        error_exit "错误日志文件不存在: $log_file"
    fi

    # 统计错误类型
    echo "=== 错误日志分析 ==="
    echo "分析时间范围: 最近 $hours 小时"

    # 5xx错误分析
    echo -e "\n5xx服务器错误:"
    grep "HTTP/[0-9.]* 5[0-9][0-9]" "$log_file" | awk '{print $9}' | sort | uniq -c | sort -rn

    # 4xx错误分析
    echo -e "\n4xx客户端错误:"
    grep "HTTP/[0-9.]* 4[0-9][0-9]" "$log_file" | awk '{print $9}' | sort | uniq -c | sort -rn

    # 错误URL分析
    echo -e "\n错误最多的URL (Top 10):"
    grep -E "HTTP/[0-9.]* [45][0-9][0-9]" "$log_file" | awk '{print $7}' | sort | uniq -c | sort -rn | head -10

    # 错误IP分析
    echo -e "\n产生错误最多的IP (Top 10):"
    grep -E "HTTP/[0-9.]* [45][0-9][0-9]" "$log_file" | awk '{print $1}' | sort | uniq -c | sort -rn | head -10

    # 详细错误分析
    echo -e "\n错误详细信息:"
    grep -E "HTTP/[0-9.]* [45][0-9][0-9]" "$log_file" | tail -10

    # 统计每小时错误数
    echo -e "\n每小时错误数分布:"
    grep -E "HTTP/[0-9.]* [45][0-9][0-9]" "$log_file" | awk '{print $4}' | awk -F: '{print $2}' | sort | uniq -c | sort -k2n
}

analyze_performance() {
    local hours=${1:-24}
    local log_file=$CADDY_ACCESS_LOG

    log_info "开始性能分析..."

    # 响应时间分析
    awk '
    BEGIN {
        count=0; sum=0; max=0; min=999999;
    }
    {
        count++;
        time=$NF;
        sum+=time;
        times[count]=time;
        if(time>max) max=time;
        if(time<min) min=time;
    }
    END {
        if(count>0) {
            avg=sum/count;
            asort(times);
            printf "\n=== 响应时间分析 ===\n";
            printf "请求总数: %d\n", count;
            printf "平均响应时间: %.2fms\n", avg;
            printf "最大响应时间: %.2fms\n", max;
            printf "最小响应时间: %.2fms\n", min;
            printf "中位数响应时间(P50): %.2fms\n", times[int(count*0.5)];
            printf "75th分位(P75): %.2fms\n", times[int(count*0.75)];
            printf "90th分位(P90): %.2fms\n", times[int(count*0.90)];
            printf "95th分位(P95): %.2fms\n", times[int(count*0.95)];
            printf "99th分位(P99): %.2fms\n", times[int(count*0.99)];
        }
    }' "$log_file"

    # QPS分析
    echo -e "\n每秒请求数(QPS)分析:"
    awk '{
        split($4, dt, ":");
        hour=dt[2];
        reqs[hour]++;
    } END {
        for (h in reqs) {
            printf "%02d:00 - %02d:59: %.2f qps\n", h, h, reqs[h]/3600;
        }
    }' "$log_file" | sort -n

    # 状态码分布
    echo -e "\n状态码分布:"
    awk '{
        codes[$9]++;
        total++;
    } END {
        for (code in codes) {
            printf "%s: %d (%.2f%%)\n", code, codes[code], codes[code]/total*100;
        }
    }' "$log_file" | sort -rn -k2

    # 带宽使用分析
    echo -e "\n带宽使用分析:"
    awk '{
        bytes+=$10;
        reqs++;
    } END {
        mb=bytes/1024/1024;
        printf "总流量: %.2f MB\n", mb;
        printf "平均请求大小: %.2f KB\n", (bytes/reqs)/1024;
        printf "平均带宽使用: %.2f KB/s\n", (bytes/NR)/1024;
    }' "$log_file"
}

# 日志清理
cleanup_logs() {
    local days=${1:-$LOG_RETENTION_DAYS}
    log_info "清理 $days 天前的日志..."

    # 清理访问日志
    if [[ -f "$CADDY_ACCESS_LOG" ]]; then
        find "$(dirname "$CADDY_ACCESS_LOG")" -name "access.log*" -type f -mtime +$days -delete
    fi

    # 清理错误日志
    if [[ -f "$CADDY_ERROR_LOG" ]]; then
        find "$(dirname "$CADDY_ERROR_LOG")" -name "error.log*" -type f -mtime +$days -delete
    fi

    # 清理备份日志
    if [[ -d "$BACKUP_DIR" ]]; then
        find "$BACKUP_DIR" -name "*.log.gz" -type f -mtime +$days -delete
    fi

    log_info "日志清理完成"
}

# 日志轮转
rotate_logs() {
    local max_size=$((100*1024*1024))  # 100MB
    local log_files=("$CADDY_ACCESS_LOG" "$CADDY_ERROR_LOG")

    for log_file in "${log_files[@]}"; do
        if [[ -f "$log_file" ]]; then
            local size
            size=$(stat -f%z "$log_file" 2>/dev/null || stat -c%s "$log_file")

            if (( size > max_size )); then
                local timestamp
                timestamp=$(date +%Y%m%d_%H%M%S)
                local backup_name="${log_file}_${timestamp}.gz"

                # 压缩当前日志
                gzip -c "$log_file" > "$backup_name"

                # 清空当前日志文件
                cat /dev/null > "$log_file"

                # 设置权限
                chmod 640 "$backup_name"
                chown root:caddy "$backup_name"

                log_info "已轮转日志文件: $log_file -> $backup_name"
            fi
        fi
    done
}

# 日志监控告警阈值检查
check_log_alerts() {
    local hours=${1:-1}
    local error_count

    # 检查5xx错误数量
    error_count=$(grep -c "HTTP/[0-9.]* 5[0-9][0-9]" "$CADDY_ERROR_LOG")
    if (( error_count > HTTP_ERROR_THRESHOLD )); then
        send_alert "检测到大量服务器错误 (5xx): $error_count 个" "error"
    fi

    # 检查慢请求数量
    local slow_count
    slow_count=$(awk -v threshold="$SLOW_REQUEST_THRESHOLD" '$NF > threshold {count++} END {print count}' "$CADDY_ACCESS_LOG")
    if (( slow_count > HTTP_ERROR_THRESHOLD )); then
        send_alert "检测到大量慢请求 (>${SLOW_REQUEST_THRESHOLD}ms): $slow_count 个" "warning"
    fi

    # 检查4xx错误数量
    local client_error_count
    client_error_count=$(grep -c "HTTP/[0-9.]* 4[0-9][0-9]" "$CADDY_ERROR_LOG")
    if (( client_error_count > HTTP_ERROR_THRESHOLD * 2 )); then
        send_alert "检测到大量客户端错误 (4xx): $client_error_count 个" "warning"
    fi
}

# 在main函数中添加新命令
main() {
    case "$1" in
        analyze)
            case "$2" in
                access)
                    analyze_access_logs "${3:-24}"
                    ;;
                error)
                    analyze_error_logs "${3:-24}"
                    ;;
                performance)
                    analyze_performance "${3:-24}"
                    ;;
                all)
                    analyze_access_logs "${3:-24}"
                    analyze_error_logs "${3:-24}"
                    analyze_performance "${3:-24}"
                    ;;
                *)
                    echo "用法: $0 analyze [access|error|performance|all] [hours]"
                    ;;
            esac
            ;;
        cleanup-logs)
            cleanup_logs "${2:-$LOG_RETENTION_DAYS}"
            ;;
        rotate-logs)
            rotate_logs
            ;;
        check-alerts)
            check_log_alerts "${2:-1}"
            ;;
        # ... 其他命令 ...
    esac
}

# 在show_help中添加新命令说明
show_help() {
    cat << EOF

日志分析命令:
    analyze access [hours]        分析访问日志
    analyze error [hours]         分析错误日志
    analyze performance [hours]   分析性能数据
    analyze all [hours]          执行所有分析
    cleanup-logs [days]          清理旧日志文件
    rotate-logs                  轮转日志文件
    check-alerts [hours]         检查日志告警

    示例:
        $0 analyze access 24     # 分析最近24小时的访问日志
        $0 cleanup-logs 30       # 清理30天前的日志
        $0 check-alerts 1        # 检查最近1小时的日志告警
EOF
}

#####################################
# 监控功能
#####################################

# 系统资源监控
monitor_system() {
    log_info "开始系统资源监控..."

    # CPU使用率监控
    local cpu_usage cpu_load1 cpu_load5 cpu_load15
    cpu_usage=$(top -bn1 | grep "Cpu(s)" | awk '{print $2}')
    read -r cpu_load1 cpu_load5 cpu_load15 < /proc/loadavg

    # 内存使用监控
    local mem_total mem_used mem_free mem_cached mem_usage
    mem_total=$(free -m | awk 'NR==2{print $2}')
    mem_used=$(free -m | awk 'NR==2{print $3}')
    mem_free=$(free -m | awk 'NR==2{print $4}')
    mem_cached=$(free -m | awk 'NR==2{print $6}')
    mem_usage=$(awk "BEGIN {printf \"%.2f\", $mem_used/$mem_total*100}")

    # 磁盘使用监控
    local disk_usage disk_iops disk_throughput
    disk_usage=$(df -h / | awk 'NR==2{print $5}' | tr -d '%')
    disk_iops=$(iostat -x 1 2 | awk '/^sda/ {printf "%.2f", $4}' | tail -1)
    disk_throughput=$(iostat -x 1 2 | awk '/^sda/ {printf "%.2f", $6}' | tail -1)

    # 网络连接监控
    local total_conn established_conn time_wait_conn
    total_conn=$(netstat -an | wc -l)
    established_conn=$(netstat -an | grep ESTABLISHED | wc -l)
    time_wait_conn=$(netstat -an | grep TIME_WAIT | wc -l)

    # 输出监控结果
    echo "=== 系统资源监控报告 ==="
    echo "时间: $(date '+%Y-%m-%d %H:%M:%S')"
    echo -e "\nCPU状态:"
    echo "  使用率: ${cpu_usage}%"
    echo "  负载(1/5/15分钟): $cpu_load1 / $cpu_load5 / $cpu_load15"

    echo -e "\n内存状态:"
    echo "  总计: ${mem_total}MB"
    echo "  已用: ${mem_used}MB"
    echo "  空闲: ${mem_free}MB"
    echo "  缓存: ${mem_cached}MB"
    echo "  使用率: ${mem_usage}%"

    echo -e "\n磁盘状态:"
    echo "  使用率: ${disk_usage}%"
    echo "  IOPS: ${disk_iops}/s"
    echo "  吞吐量: ${disk_throughput}MB/s"

    echo -e "\n网络连接状态:"
    echo "  总连接数: $total_conn"
    echo "  已建立连接: $established_conn"
    echo "  TIME_WAIT连接: $time_wait_conn"

    # 告警检查
    if (( $(echo "$cpu_usage > $CPU_THRESHOLD" | bc -l) )); then
        send_alert "CPU使用率过高: ${cpu_usage}%" "warning"
    fi

    if (( $(echo "$mem_usage > $MEM_THRESHOLD" | bc -l) )); then
        send_alert "内存使用率过高: ${mem_usage}%" "warning"
    fi

    if (( disk_usage > DISK_THRESHOLD )); then
        send_alert "磁盘使用率过高: ${disk_usage}%" "warning"
    fi
}

# 站点监控
monitor_site() {
    local domain=$1
    local protocol=${2:-https}
    local retry_count=3
    local retry_interval=5

    log_info "开始监控站点: $domain"

    local start_time status_code response_time success=false

    for ((i=1; i<=retry_count; i++)); do
        start_time=$(date +%s%N)
        status_code=$(curl -sL -w "%{http_code}" -m "$HEALTH_CHECK_TIMEOUT" "$protocol://$domain" -o /dev/null) || status_code=0
        local end_time
        end_time=$(date +%s%N)
        response_time=$(( (end_time - start_time) / 1000000 ))

        if [[ $status_code -eq 200 ]]; then
            success=true
            break
        fi

        log_warn "第 $i 次检查失败，状态码: $status_code，等待 ${retry_interval}s 后重试..."
        sleep $retry_interval
    done

    # 检查SSL证书
    local ssl_expiry
    if [[ $protocol == "https" ]]; then
        ssl_expiry=$(echo | openssl s_client -servername "$domain" -connect "$domain":443 2>/dev/null | openssl x509 -noout -dates)
        local expire_date
        expire_date=$(echo "$ssl_expiry" | grep 'notAfter=' | cut -d= -f2)
        local expire_timestamp
        expire_timestamp=$(date -d "$expire_date" +%s)
        local current_timestamp
        current_timestamp=$(date +%s)
        local days_left
        days_left=$(( (expire_timestamp - current_timestamp) / 86400 ))

        if (( days_left <= 7 )); then
            send_alert "SSL证书即将过期: $domain (剩余 $days_left 天)" "error"
        elif (( days_left <= 14 )); then
            send_alert "SSL证书即将过期: $domain (剩余 $days_left 天)" "warning"
        fi
    fi

    # 生成监控报告
    echo "=== 站点监控报告: $domain ==="
    echo "检查时间: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "状态码: $status_code"
    echo "响应时间: ${response_time}ms"
    if [[ $protocol == "https" ]]; then
        echo "SSL证书有效期: $days_left 天"
    fi

    # 检查结果告警
    if [[ $success == false ]]; then
        send_alert "站点无法访问: $domain (状态码: $status_code)" "error"
        return 1
    elif [[ $status_code -ge 500 ]]; then
        send_alert "站点服务器错误: $domain (状态码: $status_code)" "error"
        return 1
    elif [[ $response_time -gt 5000 ]]; then
        send_alert "站点响应缓慢: $domain (${response_time}ms)" "warning"
    fi

    return 0
}

# SSL证书监控
check_certificates() {
    local warning_days=14
    local critical_days=7

    log_info "开始检查SSL证书状态..."

    find "$CERT_DIR" -type f -name "*.crt" | while read -r cert; do
        local domain
        domain=$(openssl x509 -noout -subject -in "$cert" | sed -n 's/.*CN = \(.*\)/\1/p')

        # 检查证书有效性
        local cert_status
        cert_status=$(openssl x509 -noout -checkend 86400 -in "$cert")

        # 获取证书详细信息
        local cert_info
        cert_info=$(openssl x509 -noout -text -in "$cert")

        # 检查证书过期时间
        local end_date
        end_date=$(openssl x509 -noout -enddate -in "$cert")
        local exp_date
        exp_date=$(date -d "${end_date#*=}" +%s)
        local now
        now=$(date +%s)
        local days_left
        days_left=$(( (exp_date - now) / 86400 ))

        # 检查证书算法
        local cert_alg
        cert_alg=$(echo "$cert_info" | grep "Signature Algorithm" | head -1 | awk '{print $NF}')

        # 检查密钥长度
        local key_length
        key_length=$(echo "$cert_info" | grep "Public-Key:" | awk '{print $2}')

        echo "=== SSL证书检查报告: $domain ==="
        echo "剩余有效期: $days_left 天"
        echo "签名算法: $cert_alg"
        echo "密钥长度: $key_length bits"

        # 告警检测
        if (( days_left <= critical_days )); then
            send_alert "证书紧急告警: $domain 证书即将在 $days_left 天后过期" "error"
        elif (( days_left <= warning_days )); then
            send_alert "证书警告: $domain 证书将在 $days_left 天后过期" "warning"
        fi

        # 检查弱加密算法
        if [[ $cert_alg == *"md5"* ]] || [[ $cert_alg == *"sha1"* ]]; then
            send_alert "证书安全警告: $domain 使用弱加密算法 ($cert_alg)" "warning"
        fi

        # 检查密钥长度
        if [[ $key_length -lt 2048 ]]; then
            send_alert "证书安全警告: $domain 密钥长度不足 ($key_length bits)" "warning"
        fi
    done
}

# 全面监控
monitor_all() {
    log_info "启动全面监控..."

    while true; do
        # 系统资源监控
        monitor_system

        # 站点监控
        local domains
        domains=$(grep -E "^[a-zA-Z0-9][a-zA-Z0-9.-]+\s*{" "$CADDYFILE" | sed 's/{.*$//')
        for domain in $domains; do
            monitor_site "$domain"
            sleep 1  # 避免过快请求
        done

        # 证书检查
        check_certificates

        # 日志检查
        check_log_alerts

        sleep "$HEALTH_CHECK_INTERVAL"
    done
}

#####################################
# 告警功能
#####################################

# 告警发送函数
send_alert() {
    local message=$1
    local level=${2:-"info"}
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local formatted_message="[Caddy Alert - $level] [$timestamp] $message"

    # 只在告警功能启用时发送
    if [[ $ENABLE_ALERTS != "true" ]]; then
        return
    fi

    # Telegram告警
    if [[ -n $TELEGRAM_BOT_TOKEN && -n $TELEGRAM_CHAT_ID ]]; then
        local telegram_url="https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendMessage"
        retry_operation "curl -s -X POST '$telegram_url' \
            -d 'chat_id=$TELEGRAM_CHAT_ID' \
            -d 'text=$formatted_message' \
            -d 'parse_mode=HTML'"
    fi

    # 钉钉告警
    if [[ -n $DINGTALK_WEBHOOK ]]; then
        local json="{\"msgtype\": \"text\", \"text\": {\"content\": \"$formatted_message\"}}"
        retry_operation "curl -s -H 'Content-Type: application/json' -d '$json' '$DINGTALK_WEBHOOK'"
    fi

    # Slack告警
    if [[ -n $SLACK_WEBHOOK ]]; then
        local json="{\"text\": \"$formatted_message\"}"
        retry_operation "curl -s -X POST -H 'Content-Type: application/json' -d '$json' '$SLACK_WEBHOOK'"
    fi

    # 企业微信告警
    if [[ -n $WEIXIN_WEBHOOK ]]; then
        # 根据告警级别设置不同的标记颜色
        local color="info"
        case $level in
            error) color="warning" ;;
            warning) color="comment" ;;
        esac

        # 使用 Markdown 格式发送更美观的消息
        local markdown_message="### Caddy 监控告警通知\n"
        markdown_message+="- **时间**: ${timestamp}\n"
        markdown_message+="- **级别**: <font color=\"${color}\">${level}</font>\n"
        markdown_message+="- **详情**: ${message}\n"

        local json="{\"msgtype\": \"markdown\", \"markdown\": {\"content\": \"${markdown_message}\"}}"
        retry_operation "curl -s -H 'Content-Type: application/json' -d '$json' '$WEIXIN_WEBHOOK'"
    fi

    # 记录到日志
    log "$level" "$message"
}

# 在main函数中添加监控相关命令
main() {
    case "$1" in
        monitor)
            case "$2" in
                system)
                    monitor_system
                    ;;
                site)
                    if [[ -z $3 ]]; then
                        error_exit "用法: $0 monitor site <domain>"
                    fi
                    monitor_site "$3"
                    ;;
                cert)
                    check_certificates
                    ;;
                all)
                    monitor_all
                    ;;
                *)
                    echo "用法: $0 monitor [system|site|cert|all]"
                    ;;
            esac
            ;;
        # ... 其他命令 ...
    esac
}

# 在show_help中添加监控相关命令说明
show_help() {
    cat << EOF

监控命令:
    monitor system              监控系统资源
    monitor site <domain>       监控指定站点
    monitor cert               检查SSL证书状态
    monitor all               启动全面监控

    示例:
        $0 monitor system      # 监控系统资源
        $0 monitor site example.com  # 监控指定站点
        $0 monitor all        # 启动全面监控
EOF
}

#####################################
# 版本检查与更新
#####################################
check_version() {
    local current_version=$SCRIPT_VERSION
    log_info "当前版本: $current_version"

    # 检查最新版本
    local latest_version
    latest_version=$(curl -s "https://api.github.com/repos/raylenzed/caddy-manager/releases/latest" | grep '"tag_name":' | sed -E 's/.*"v([^"]+)".*/\1/')

    if [[ -n $latest_version ]]; then
        if [[ $latest_version != "$current_version" ]]; then
            log_info "发现新版本: $latest_version"
            if [[ $1 == "--auto-update" ]]; then
                update_script
            else
                echo "可以使用 '$0 update' 命令更新到最新版本"
            fi
        else
            log_info "已经是最新版本"
        fi
    else
        log_warn "无法检查更新"
    fi
}

update_script() {
    log_info "开始更新脚本..."

    # 备份当前脚本
    local backup_file="${SCRIPT_DIR}/$(basename "$0").backup"
    cp "$0" "$backup_file"

    # 下载新版本
    if curl -o "$0" -L "https://raw.githubusercontent.com/raylenzed/caddy-manager/main/caddy-manager.sh"; then
        chmod +x "$0"
        log_info "更新成功,请重新运行脚本"
        exit 0
    else
        log_error "更新失败"
        mv "$backup_file" "$0"
        exit 1
    fi
}

#####################################
# 性能优化
#####################################
optimize_performance() {
    log_info "开始性能优化..."

    # 备份当前配置
    backup_config

    # 添加性能优化配置
    local perf_config="
    {
        # 全局性能优化
        admin off
        auto_https disable_redirects
        servers {
            protocol {
                experimental_http3  # 启用HTTP/3
            }
        }

        # 限制最大连接数
        servers :443 {
            max_concurrent_requests 1000
        }
    }
    "

    # 更新Caddyfile
    echo "$perf_config" > "$CADDYFILE.tmp"
    cat "$CADDYFILE" >> "$CADDYFILE.tmp"
    mv "$CADDYFILE.tmp" "$CADDYFILE"

    # 验证新配置
    if ! validate_config "$CADDYFILE"; then
        log_error "性能优化配置验证失败"
        restore_config "$(ls -t "$BACKUP_DIR"/Caddyfile_* | head -1)"
        return 1
    fi

    # 重载配置
    reload_caddy
    log_info "性能优化完成"
}

#####################################
# 安全加固
#####################################
enhance_security() {
    log_info "开始安全加固..."

    # 备份当前配置
    backup_config

    # 添加安全配置
    local security_config="
    {
        # 安全相关全局配置
        servers {
            protocol {
                strict_sni_host true  # 严格SNI检查
            }
        }

        # 安全响应头
        header /* {
            Strict-Transport-Security \"max-age=31536000; includeSubDomains; preload\"
            X-Content-Type-Options \"nosniff\"
            X-Frame-Options \"SAMEORIGIN\"
            X-XSS-Protection \"1; mode=block\"
            Referrer-Policy \"strict-origin-when-cross-origin\"
            Content-Security-Policy \"default-src 'self'\"
        }
    }
    "

    # 更新Caddyfile
    echo "$security_config" > "$CADDYFILE.tmp"
    cat "$CADDYFILE" >> "$CADDYFILE.tmp"
    mv "$CADDYFILE.tmp" "$CADDYFILE"

    # 验证新配置
    if ! validate_config "$CADDYFILE"; then
        log_error "安全配置验证失败"
        restore_config "$(ls -t "$BACKUP_DIR"/Caddyfile_* | head -1)"
        return 1
    fi

    # 设置文件权限
    chmod 600 "$CADDYFILE"
    chmod 700 "$CERT_DIR"
    chmod 600 "$CERT_DIR"/*

    # 重载配置
    reload_caddy
    log_info "安全加固完成"
}

#####################################
# 主程序
#####################################
main() {
    # 检查root权限
    if [[ $EUID -ne 0 ]]; then
        error_exit "此脚本需要root权限运行"
    fi

    # 命令行参数解析
    case "$1" in
        install)
            check_system
            ensure_directories
            install_caddy
            ;;
        update)
            update_script
            ;;
        version)
            check_version
            ;;
        add-site)
            if [[ -z $2 || -z $3 ]]; then
                error_exit "用法: $0 add-site <domain> <upstream>"
            fi
            add_site "$2" "$3"
            ;;
        remove-site)
            if [[ -z $2 ]]; then
                error_exit "用法: $0 remove-site <domain>"
            fi
            remove_site "$2"
            ;;
        list-sites)
            grep -E "^[a-zA-Z0-9][a-zA-Z0-9.-]+\s*{" "$CADDYFILE" | sed 's/{.*$//'
            ;;
        backup)
            backup_config
            ;;
        restore)
            if [[ -z $2 ]]; then
                error_exit "用法: $0 restore <backup_file>"
            fi
            restore_config "$2"
            ;;
        analyze)
            case "$2" in
                access)
                    analyze_access_logs "${3:-24}"
                    ;;
                error)
                    analyze_error_logs "${3:-24}"
                    ;;
                performance)
                    analyze_performance "${3:-24}"
                    ;;
                all)
                    analyze_access_logs "${3:-24}"
                    analyze_error_logs "${3:-24}"
                    analyze_performance "${3:-24}"
                    ;;
                *)
                    echo "用法: $0 analyze [access|error|performance|all] [hours]"
                    ;;
            esac
            ;;
        monitor)
            case "$2" in
                system)
                    monitor_system
                    ;;
                site)
                    if [[ -z $3 ]]; then
                        error_exit "用法: $0 monitor site <domain>"
                    fi
                    monitor_site "$3"
                    ;;
                cert)
                    check_certificates
                    ;;
                all)
                    monitor_all
                    ;;
                *)
                    echo "用法: $0 monitor [system|site|cert|all]"
                    ;;
            esac
            ;;
        optimize)
            optimize_performance
            ;;
        secure)
            enhance_security
            ;;
        cleanup-logs)
            cleanup_logs "${2:-$LOG_RETENTION_DAYS}"
            ;;
        rotate-logs)
            rotate_logs
            ;;
        test)
            validate_config "$CADDYFILE"
            ;;
        reload)
            reload_caddy
            ;;
        help|--help|-h)
            show_help
            ;;
        *)
            show_help
            exit 1
            ;;
    esac
}

# 显示帮助信息
show_help() {
    cat << EOF
Caddy 管理脚本 v${SCRIPT_VERSION}

用法: $0 <command> [options]

基础命令:
    install              安装或更新 Caddy
    update              更新脚本到最新版本
    version             检查脚本版本
    help                显示此帮助信息

站点管理:
    add-site <domain> <upstream>    添加新站点
    remove-site <domain>            删除指定站点
    list-sites                      列出所有站点

配置管理:
    backup                          备份当前配置
    restore <file>                  从备份文件还原配置
    reload                          重新加载配置
    test                           测试配置文件

日志分析:
    analyze access [hours]          分析访问日志
    analyze error [hours]           分析错误日志
    analyze performance [hours]     分析性能数据
    analyze all [hours]            执行所有分析
    cleanup-logs [days]            清理旧日志文件
    rotate-logs                    轮转日志文件

监控功能:
    monitor system                  监控系统资源
    monitor site <domain>           监控指定站点
    monitor cert                   检查SSL证书状态
    monitor all                   启动全面监控

优化功能:
    optimize                       执行性能优化
    secure                        执行安全加固

示例:
    $0 add-site example.com localhost:8080  # 添加新站点
    $0 monitor all                         # 启动全面监控
    $0 analyze access 24                   # 分析最近24小时的访问日志

注意:
1. 所有命令都需要 root 权限
2. 建议在修改配置前先执行备份
3. monitor all 建议在 screen 或 tmux 中运行
4. 完整的日志文件位于 ${CADDY_LOG}

项目地址: https://github.com/raylenzed/caddy-manager
问题反馈: https://github.com/raylenzed/caddy-manager/issues

EOF
}

# 脚本入口
main "$@"
