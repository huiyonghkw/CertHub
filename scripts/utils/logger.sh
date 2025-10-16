#!/bin/bash

# 日志工具脚本
# 提供统一的日志记录功能
# 版本：1.0.0

# 日志级别定义
LOG_LEVEL_DEBUG=0
LOG_LEVEL_INFO=1
LOG_LEVEL_WARN=2
LOG_LEVEL_ERROR=3

# 当前日志级别（从环境变量或配置文件读取，默认为INFO）
CURRENT_LOG_LEVEL=${LOG_LEVEL:-$LOG_LEVEL_INFO}

# 日志文件路径
LOG_FILE="${LOG_DIR:-/data/logs}/cert-manager.log"
ERROR_LOG_FILE="${LOG_DIR:-/data/logs}/cert-manager-error.log"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# 确保日志目录存在
init_logger() {
    local log_dir
    log_dir=$(dirname "$LOG_FILE")
    mkdir -p "$log_dir"
    
    # 设置日志文件权限
    touch "$LOG_FILE" "$ERROR_LOG_FILE"
    chmod 644 "$LOG_FILE" "$ERROR_LOG_FILE"
}

# 获取时间戳
get_timestamp() {
    date '+%Y-%m-%d %H:%M:%S'
}

# 获取调用者信息
get_caller_info() {
    local caller_script caller_line caller_function
    caller_script=$(basename "${BASH_SOURCE[3]}" 2>/dev/null || echo "unknown")
    caller_line="${BASH_LINENO[2]}"
    caller_function="${FUNCNAME[3]:-main}"
    echo "${caller_script}:${caller_line}:${caller_function}"
}

# 通用日志函数
write_log() {
    local level="$1"
    local level_num="$2"
    local color="$3"
    local message="$4"
    
    # 检查日志级别
    if [[ $level_num -lt $CURRENT_LOG_LEVEL ]]; then
        return 0
    fi
    
    local timestamp
    local caller_info
    timestamp=$(get_timestamp)
    caller_info=$(get_caller_info)
    
    # 格式化日志消息
    local log_entry="[$timestamp] [$level] [$caller_info] $message"
    
    # 写入日志文件
    echo "$log_entry" >> "$LOG_FILE"
    
    # 错误日志额外写入错误日志文件
    if [[ "$level" == "ERROR" ]]; then
        echo "$log_entry" >> "$ERROR_LOG_FILE"
    fi
    
    # 控制台输出（带颜色）
    if [[ -t 1 ]]; then
        echo -e "${color}[$timestamp] [$level] $message${NC}"
    else
        echo "[$timestamp] [$level] $message"
    fi
}

# 调试日志
log_debug() {
    write_log "DEBUG" $LOG_LEVEL_DEBUG "$CYAN" "$1"
}

# 信息日志
log_info() {
    write_log "INFO" $LOG_LEVEL_INFO "$BLUE" "$1"
}

# 警告日志
log_warn() {
    write_log "WARN" $LOG_LEVEL_WARN "$YELLOW" "$1"
}

# 错误日志
log_error() {
    write_log "ERROR" $LOG_LEVEL_ERROR "$RED" "$1"
}

# 成功日志
log_success() {
    write_log "SUCCESS" $LOG_LEVEL_INFO "$GREEN" "$1"
}

# 重要信息日志
log_important() {
    write_log "IMPORTANT" $LOG_LEVEL_INFO "$PURPLE" "$1"
}

# 分隔线
log_separator() {
    local char="${1:-=}"
    local length="${2:-60}"
    local line
    line=$(printf "%*s" "$length" | tr ' ' "$char")
    log_info "$line"
}

# 日志开始标记
log_start() {
    local operation="$1"
    log_separator
    log_important "开始执行: $operation"
    log_separator
}

# 日志结束标记
log_end() {
    local operation="$1"
    local status="${2:-完成}"
    log_separator
    log_important "执行结束: $operation - $status"
    log_separator
}

# 日志清理
cleanup_logs() {
    local days_to_keep="${1:-30}"
    local log_dir
    log_dir=$(dirname "$LOG_FILE")
    
    log_info "开始清理 $days_to_keep 天前的日志文件"
    
    # 查找并删除旧日志
    find "$log_dir" -name "*.log" -type f -mtime +$days_to_keep -delete
    find "$log_dir" -name "*.log.*" -type f -mtime +$days_to_keep -delete
    
    log_info "日志清理完成"
}

# 日志轮转
rotate_logs() {
    local max_size="${1:-10M}"
    local max_files="${2:-5}"
    
    # 检查日志文件大小
    if [[ -f "$LOG_FILE" ]]; then
        local file_size
        file_size=$(stat -f%z "$LOG_FILE" 2>/dev/null || stat -c%s "$LOG_FILE" 2>/dev/null || echo "0")
        local max_bytes
        max_bytes=$(echo "$max_size" | sed 's/M/*1024*1024/g; s/K/*1024/g; s/G/*1024*1024*1024/g' | bc)
        
        if [[ $file_size -gt $max_bytes ]]; then
            log_info "日志文件大小超过限制，开始轮转"
            
            # 轮转日志文件
            for ((i=max_files-1; i>=1; i--)); do
                local old_file="${LOG_FILE}.${i}"
                local new_file="${LOG_FILE}.$((i+1))"
                
                if [[ -f "$old_file" ]]; then
                    mv "$old_file" "$new_file"
                fi
            done
            
            # 压缩当前日志文件
            if command -v gzip &> /dev/null; then
                cp "$LOG_FILE" "${LOG_FILE}.1"
                gzip "${LOG_FILE}.1"
                > "$LOG_FILE"
            else
                mv "$LOG_FILE" "${LOG_FILE}.1"
            fi
            
            log_info "日志轮转完成"
        fi
    fi
}

# 获取日志统计信息
get_log_stats() {
    local log_file="${1:-$LOG_FILE}"
    
    if [[ ! -f "$log_file" ]]; then
        echo "日志文件不存在: $log_file"
        return 1
    fi
    
    local total_lines error_lines warn_lines info_lines
    total_lines=$(wc -l < "$log_file")
    error_lines=$(grep -c "\[ERROR\]" "$log_file" || echo "0")
    warn_lines=$(grep -c "\[WARN\]" "$log_file" || echo "0")
    info_lines=$(grep -c "\[INFO\]" "$log_file" || echo "0")
    
    cat << EOF
日志统计信息:
- 总行数: $total_lines
- 错误数: $error_lines
- 警告数: $warn_lines
- 信息数: $info_lines
- 文件大小: $(du -h "$log_file" | cut -f1)
EOF
}

# 实时查看日志
tail_logs() {
    local lines="${1:-50}"
    local log_file="${2:-$LOG_FILE}"
    
    if [[ ! -f "$log_file" ]]; then
        log_error "日志文件不存在: $log_file"
        return 1
    fi
    
    log_info "实时查看日志: $log_file"
    tail -n "$lines" -f "$log_file"
}

# 搜索日志
search_logs() {
    local pattern="$1"
    local log_file="${2:-$LOG_FILE}"
    local context_lines="${3:-3}"
    
    if [[ ! -f "$log_file" ]]; then
        log_error "日志文件不存在: $log_file"
        return 1
    fi
    
    log_info "搜索日志: $pattern"
    grep -n -C "$context_lines" "$pattern" "$log_file"
}

# 导出日志
export_logs() {
    local start_date="$1"
    local end_date="$2"
    local output_file="$3"
    local log_file="${4:-$LOG_FILE}"
    
    if [[ ! -f "$log_file" ]]; then
        log_error "日志文件不存在: $log_file"
        return 1
    fi
    
    log_info "导出日志: $start_date 到 $end_date"
    
    # 使用awk按日期过滤日志
    awk -v start="$start_date" -v end="$end_date" '
        /^\[.*\]/ {
            match($0, /\[([0-9]{4}-[0-9]{2}-[0-9]{2})\]/, arr)
            if (arr[1] >= start && arr[1] <= end) {
                print $0
            }
        }
    ' "$log_file" > "$output_file"
    
    log_info "日志导出完成: $output_file"
}

# 初始化日志系统
init_logger

# 如果作为独立脚本运行，提供命令行接口
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    case "${1:-}" in
        "stats")
            get_log_stats "${2:-}"
            ;;
        "tail")
            tail_logs "${2:-50}" "${3:-}"
            ;;
        "search")
            search_logs "${2:-}" "${3:-}" "${4:-3}"
            ;;
        "export")
            export_logs "$2" "$3" "$4" "${5:-}"
            ;;
        "cleanup")
            cleanup_logs "${2:-30}"
            ;;
        "rotate")
            rotate_logs "${2:-10M}" "${3:-5}"
            ;;
        "test")
            log_debug "这是一个调试消息"
            log_info "这是一个信息消息"
            log_warn "这是一个警告消息"
            log_error "这是一个错误消息"
            log_success "这是一个成功消息"
            log_important "这是一个重要消息"
            ;;
        *)
            cat << EOF
日志工具使用说明:

用法: $0 [命令] [参数]

命令:
    stats [日志文件]           显示日志统计信息
    tail [行数] [日志文件]     实时查看日志
    search <模式> [日志文件] [上下文行数]  搜索日志
    export <开始日期> <结束日期> <输出文件> [日志文件]  导出日志
    cleanup [保留天数]         清理旧日志
    rotate [最大大小] [最大文件数]  轮转日志
    test                       测试日志功能

示例:
    $0 stats
    $0 tail 100
    $0 search "ERROR"
    $0 export 2023-01-01 2023-12-31 /tmp/logs_2023.log
    $0 cleanup 30
    $0 rotate 10M 5
EOF
            ;;
    esac
fi 
