#!/bin/bash

# SSL证书管理简化脚本
# 版本：1.0.0

set -e

# 配置目录
CONFIG_DIR="/config"
CERT_DIR="/data/certs"
LOG_DIR="/data/logs"
BACKUP_DIR="/data/backups"

# 日志函数
log_info() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] $1"
}

log_error() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] $1" >&2
}

log_success() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [SUCCESS] $1"
}

# 健康检查
health_check() {
    log_info "执行健康检查"
    
    # 检查必要目录
    local dirs=("$CONFIG_DIR" "$CERT_DIR" "$LOG_DIR" "$BACKUP_DIR")
    for dir in "${dirs[@]}"; do
        if [[ ! -d "$dir" ]]; then
            log_error "目录不存在: $dir"
            exit 1
        fi
    done
    
    # 检查acme.sh
    if ! command -v acme.sh &> /dev/null; then
        log_error "acme.sh 未找到"
        exit 1
    fi
    
    # 检查配置文件
    if [[ ! -f "$CONFIG_DIR/domains.yml.example" ]]; then
        log_error "配置文件模板不存在"
        exit 1
    fi
    
    log_success "健康检查通过"
    return 0
}

# 显示状态
show_status() {
    log_info "证书管理系统状态"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "📁 配置目录: $CONFIG_DIR"
    echo "📁 证书目录: $CERT_DIR"
    echo "📁 日志目录: $LOG_DIR"
    echo "📁 备份目录: $BACKUP_DIR"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    # 检查acme.sh版本
    if command -v acme.sh &> /dev/null; then
        echo "🔧 ACME客户端: $(acme.sh --version 2>/dev/null | head -1 || echo '已安装')"
    else
        echo "❌ ACME客户端: 未安装"
    fi
    
    # 检查证书数量
    if [[ -d "$CERT_DIR" ]]; then
        local cert_count=$(find "$CERT_DIR" -name "*.pem" -o -name "*.crt" | wc -l)
        echo "📜 证书数量: $cert_count"
    fi
    
    # 检查日志文件
    if [[ -d "$LOG_DIR" ]]; then
        local log_count=$(find "$LOG_DIR" -name "*.log" | wc -l)
        echo "📄 日志文件: $log_count"
    fi
    
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_success "状态查看完成"
}

# 显示帮助
show_help() {
    cat << EOF
SSL证书管理工具 (简化版) v1.0.0

使用方法: $0 [命令]

命令:
    health-check    执行健康检查
    verify-chains   验证所有证书链完整性
    status          显示系统状态
    help            显示帮助信息

示例:
    $0 health-check
    $0 status

EOF
}

# 主函数
main() {
    case "${1:-help}" in
        "health-check")
            health_check
            ;;
        "verify-chains")
            # 验证证书链完整性
            log_info "验证证书链完整性"
            if [[ -d "$CERT_DIR" ]]; then
                echo "证书目录: $CERT_DIR"
                for domain_dir in "$CERT_DIR"/*; do
                    if [[ -d "$domain_dir" ]]; then
                        domain=$(basename "$domain_dir")
                        if [[ -f "$domain_dir/fullchain.cer" ]]; then
                            cert_count=$(grep -c 'BEGIN CERTIFICATE' "$domain_dir/fullchain.cer" 2>/dev/null || echo "0")
                            if [[ $cert_count -ge 2 ]]; then
                                echo "✅ $domain: 完整证书链 ($cert_count 个证书)"
                            else
                                echo "⚠️  $domain: 证书链不完整 ($cert_count 个证书)"
                            fi
                        else
                            echo "❌ $domain: 缺少 fullchain.cer 文件"
                        fi
                    fi
                done
            else
                log_error "证书目录不存在: $CERT_DIR"
            fi
            ;;
        "status")
            show_status
            ;;
        "help"|"-h"|"--help")
            show_help
            ;;
        *)
            log_error "未知命令: $1"
            show_help
            exit 1
            ;;
    esac
}

# 执行主函数
main "$@" 
