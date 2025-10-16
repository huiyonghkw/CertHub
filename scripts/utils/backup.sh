#!/bin/bash

# 备份工具脚本
# 提供证书备份和恢复功能
# 版本：1.0.0

# 导入日志工具
UTILS_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${UTILS_SCRIPT_DIR}/logger.sh"

# 备份配置
BACKUP_DIR="${BACKUP_DIR:-/data/backups}"
CERT_DIR="${CERT_DIR:-/data/certs}"
DEFAULT_RETENTION_DAYS=90

# 创建备份目录
init_backup_dir() {
    if [[ ! -d "$BACKUP_DIR" ]]; then
        mkdir -p "$BACKUP_DIR"
        log_info "创建备份目录: $BACKUP_DIR"
    fi
}

# 获取时间戳
get_backup_timestamp() {
    date +%Y%m%d_%H%M%S
}

# 本地证书备份
backup_local_certificate() {
    local domain="$1"
    local backup_name="${2:-$(get_backup_timestamp)}"
    
    if [[ -z "$domain" ]]; then
        log_error "域名参数不能为空"
        return 1
    fi
    
    local cert_path="${CERT_DIR}/${domain}"
    
    if [[ ! -d "$cert_path" ]]; then
        log_error "证书目录不存在: $cert_path"
        return 1
    fi
    
    local backup_path="${BACKUP_DIR}/${domain}"
    mkdir -p "$backup_path"
    
    local backup_file="${backup_path}/${domain}_${backup_name}.tar.gz"
    
    log_info "开始备份本地证书: $domain"
    
    # 创建压缩包
    if tar -czf "$backup_file" -C "$CERT_DIR" "$domain"; then
        log_success "本地证书备份成功: $backup_file"
        
        # 记录备份信息
        record_backup_info "$domain" "local" "$backup_file" "$backup_name"
        
        return 0
    else
        log_error "本地证书备份失败: $domain"
        return 1
    fi
}

# 远程证书备份
backup_remote_certificate() {
    local host="$1"
    local user="$2"
    local remote_cert_dir="$3"
    local backup_name="${4:-$(get_backup_timestamp)}"
    
    if [[ -z "$host" || -z "$user" || -z "$remote_cert_dir" ]]; then
        log_error "参数不能为空: host=$host, user=$user, remote_cert_dir=$remote_cert_dir"
        return 1
    fi
    
    local domain
    domain=$(basename "$remote_cert_dir")
    
    local backup_path="${BACKUP_DIR}/remote_${host}/${domain}"
    mkdir -p "$backup_path"
    
    local backup_file="${backup_path}/${domain}_${backup_name}.tar.gz"
    
    log_info "开始备份远程证书: $host:$remote_cert_dir"
    
    # SSH选项
    local ssh_opts="-o ConnectTimeout=10 -o BatchMode=yes -o StrictHostKeyChecking=accept-new"
    
    # 在远程服务器上创建备份
    local remote_backup_cmd="cd $(dirname $remote_cert_dir) && tar -czf /tmp/${domain}_${backup_name}.tar.gz $(basename $remote_cert_dir)"
    
    if ssh $ssh_opts "${user}@${host}" "$remote_backup_cmd"; then
        # 下载备份文件
        if scp $ssh_opts "${user}@${host}:/tmp/${domain}_${backup_name}.tar.gz" "$backup_file"; then
            log_success "远程证书备份成功: $backup_file"
            
            # 清理远程临时文件
            ssh $ssh_opts "${user}@${host}" "rm -f /tmp/${domain}_${backup_name}.tar.gz"
            
            # 记录备份信息
            record_backup_info "$domain" "remote" "$backup_file" "$backup_name" "$host"
            
            return 0
        else
            log_error "远程证书备份下载失败: $host"
            return 1
        fi
    else
        log_error "远程证书备份创建失败: $host"
        return 1
    fi
}

# 记录备份信息
record_backup_info() {
    local domain="$1"
    local type="$2"
    local file="$3"
    local name="$4"
    local host="${5:-localhost}"
    
    local info_file="${BACKUP_DIR}/backup_info.json"
    
    # 创建备份信息记录
    local backup_info
    backup_info=$(cat << EOF
{
    "domain": "$domain",
    "type": "$type",
    "file": "$file",
    "name": "$name",
    "host": "$host",
    "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
    "size": $(stat -c%s "$file" 2>/dev/null || echo "0")
}
EOF
)
    
    # 如果信息文件不存在，创建新的JSON数组
    if [[ ! -f "$info_file" ]]; then
        echo "[]" > "$info_file"
    fi
    
    # 添加备份信息到JSON文件
    local temp_file
    temp_file=$(mktemp)
    
    if jq ". += [$backup_info]" "$info_file" > "$temp_file"; then
        mv "$temp_file" "$info_file"
        log_debug "备份信息记录成功: $domain"
    else
        log_error "备份信息记录失败: $domain"
        rm -f "$temp_file"
    fi
}

# 恢复本地证书
restore_local_certificate() {
    local domain="$1"
    local backup_name="$2"
    
    if [[ -z "$domain" ]]; then
        log_error "域名参数不能为空"
        return 1
    fi
    
    local backup_path="${BACKUP_DIR}/${domain}"
    
    if [[ ! -d "$backup_path" ]]; then
        log_error "备份目录不存在: $backup_path"
        return 1
    fi
    
    local backup_file
    if [[ -n "$backup_name" ]]; then
        backup_file="${backup_path}/${domain}_${backup_name}.tar.gz"
    else
        # 使用最新的备份文件
        backup_file=$(ls -t "${backup_path}"/*.tar.gz 2>/dev/null | head -1)
    fi
    
    if [[ ! -f "$backup_file" ]]; then
        log_error "备份文件不存在: $backup_file"
        return 1
    fi
    
    log_info "开始恢复本地证书: $domain"
    
    # 备份当前证书
    if [[ -d "${CERT_DIR}/${domain}" ]]; then
        local current_backup_name="before_restore_$(get_backup_timestamp)"
        backup_local_certificate "$domain" "$current_backup_name"
    fi
    
    # 恢复证书
    if tar -xzf "$backup_file" -C "$CERT_DIR"; then
        log_success "本地证书恢复成功: $domain"
        return 0
    else
        log_error "本地证书恢复失败: $domain"
        return 1
    fi
}

# 恢复远程证书
restore_remote_certificate() {
    local domain="$1"
    local host="$2"
    local user="$3"
    local remote_cert_dir="$4"
    local backup_name="$5"
    
    if [[ -z "$domain" || -z "$host" || -z "$user" || -z "$remote_cert_dir" ]]; then
        log_error "参数不能为空"
        return 1
    fi
    
    local backup_path="${BACKUP_DIR}/remote_${host}/${domain}"
    
    if [[ ! -d "$backup_path" ]]; then
        log_error "备份目录不存在: $backup_path"
        return 1
    fi
    
    local backup_file
    if [[ -n "$backup_name" ]]; then
        backup_file="${backup_path}/${domain}_${backup_name}.tar.gz"
    else
        # 使用最新的备份文件
        backup_file=$(ls -t "${backup_path}"/*.tar.gz 2>/dev/null | head -1)
    fi
    
    if [[ ! -f "$backup_file" ]]; then
        log_error "备份文件不存在: $backup_file"
        return 1
    fi
    
    log_info "开始恢复远程证书: $host:$remote_cert_dir"
    
    # SSH选项
    local ssh_opts="-o ConnectTimeout=10 -o BatchMode=yes -o StrictHostKeyChecking=accept-new"
    
    # 上传备份文件到远程服务器
    local remote_backup_file="/tmp/${domain}_restore_$(get_backup_timestamp).tar.gz"
    
    if scp $ssh_opts "$backup_file" "${user}@${host}:${remote_backup_file}"; then
        # 在远程服务器上恢复证书
        local restore_cmd="cd $(dirname $remote_cert_dir) && tar -xzf $remote_backup_file && rm -f $remote_backup_file"
        
        if ssh $ssh_opts "${user}@${host}" "$restore_cmd"; then
            log_success "远程证书恢复成功: $host:$remote_cert_dir"
            return 0
        else
            log_error "远程证书恢复失败: $host"
            return 1
        fi
    else
        log_error "备份文件上传失败: $host"
        return 1
    fi
}

# 列出备份
list_backups() {
    local domain="$1"
    local type="$2"
    
    local info_file="${BACKUP_DIR}/backup_info.json"
    
    if [[ ! -f "$info_file" ]]; then
        log_warn "备份信息文件不存在"
        return 1
    fi
    
    log_info "备份列表:"
    
    # 构建jq查询条件
    local query="."
    if [[ -n "$domain" ]]; then
        query="$query | map(select(.domain == \"$domain\"))"
    fi
    if [[ -n "$type" ]]; then
        query="$query | map(select(.type == \"$type\"))"
    fi
    
    # 输出格式化的备份列表
    jq -r "$query | sort_by(.timestamp) | reverse | .[] | 
        \"\(.domain) | \(.type) | \(.name) | \(.timestamp) | \(.size | tostring) bytes\"" "$info_file" |
    while IFS='|' read -r domain type name timestamp size; do
        printf "%-20s %-10s %-25s %-20s %s\n" "$domain" "$type" "$name" "$timestamp" "$size"
    done
}

# 清理过期备份
cleanup_old_backups() {
    local retention_days="${1:-$DEFAULT_RETENTION_DAYS}"
    
    init_backup_dir
    
    log_info "开始清理 $retention_days 天前的备份文件"
    
    local deleted_count=0
    local total_size=0
    
    # 查找并删除过期的备份文件
    while IFS= read -r -d '' file; do
        local file_size
        file_size=$(stat -c%s "$file" 2>/dev/null || echo "0")
        
        if rm "$file"; then
            deleted_count=$((deleted_count + 1))
            total_size=$((total_size + file_size))
            log_debug "删除过期备份: $file"
        else
            log_error "删除备份文件失败: $file"
        fi
    done < <(find "$BACKUP_DIR" -name "*.tar.gz" -type f -mtime +$retention_days -print0)
    
    # 更新备份信息文件
    update_backup_info_after_cleanup
    
    # 清理空目录
    find "$BACKUP_DIR" -type d -empty -delete 2>/dev/null
    
    local size_mb=$((total_size / 1024 / 1024))
    log_info "清理完成: 删除 $deleted_count 个文件，释放 ${size_mb}MB 空间"
}

# 更新备份信息文件（清理后）
update_backup_info_after_cleanup() {
    local info_file="${BACKUP_DIR}/backup_info.json"
    
    if [[ ! -f "$info_file" ]]; then
        return 0
    fi
    
    local temp_file
    temp_file=$(mktemp)
    
    # 只保留文件仍然存在的备份记录
    jq 'map(select(.file | test("^.+") and (. as $file | $file | @sh | "test -f " + . | system) == 0))' "$info_file" > "$temp_file"
    
    if [[ -s "$temp_file" ]]; then
        mv "$temp_file" "$info_file"
        log_debug "备份信息文件更新完成"
    else
        rm -f "$temp_file"
        log_error "备份信息文件更新失败"
    fi
}

# 验证备份文件
verify_backup() {
    local backup_file="$1"
    
    if [[ ! -f "$backup_file" ]]; then
        log_error "备份文件不存在: $backup_file"
        return 1
    fi
    
    log_info "验证备份文件: $backup_file"
    
    # 检查文件是否为有效的tar.gz格式
    if tar -tzf "$backup_file" > /dev/null 2>&1; then
        log_success "备份文件验证成功: $backup_file"
        
        # 列出备份文件内容
        log_info "备份文件内容:"
        tar -tzf "$backup_file" | head -20
        
        return 0
    else
        log_error "备份文件验证失败: $backup_file"
        return 1
    fi
}

# 获取备份统计信息
get_backup_stats() {
    local info_file="${BACKUP_DIR}/backup_info.json"
    
    if [[ ! -f "$info_file" ]]; then
        log_warn "备份信息文件不存在"
        return 1
    fi
    
    local total_backups local_backups remote_backups total_size
    total_backups=$(jq '. | length' "$info_file")
    local_backups=$(jq 'map(select(.type == "local")) | length' "$info_file")
    remote_backups=$(jq 'map(select(.type == "remote")) | length' "$info_file")
    total_size=$(jq 'map(.size) | add' "$info_file")
    
    local size_mb=$((total_size / 1024 / 1024))
    
    cat << EOF
备份统计信息:
- 总备份数: $total_backups
- 本地备份: $local_backups
- 远程备份: $remote_backups
- 总大小: ${size_mb}MB
- 备份目录: $BACKUP_DIR
EOF
}

# 备份所有本地证书
backup_all_local_certificates() {
    local backup_name="${1:-$(get_backup_timestamp)}"
    
    if [[ ! -d "$CERT_DIR" ]]; then
        log_error "证书目录不存在: $CERT_DIR"
        return 1
    fi
    
    log_info "开始备份所有本地证书"
    
    local success_count=0
    local total_count=0
    
    for domain_dir in "$CERT_DIR"/*/; do
        if [[ -d "$domain_dir" ]]; then
            local domain
            domain=$(basename "$domain_dir")
            total_count=$((total_count + 1))
            
            if backup_local_certificate "$domain" "$backup_name"; then
                success_count=$((success_count + 1))
            fi
        fi
    done
    
    log_info "批量备份完成: 成功 $success_count/$total_count"
    
    if [[ $success_count -eq $total_count ]]; then
        return 0
    else
        return 1
    fi
}

# 初始化备份系统
init_backup_system() {
    log_info "初始化备份系统"
    
    init_backup_dir
    
    # 创建备份信息文件
    local info_file="${BACKUP_DIR}/backup_info.json"
    if [[ ! -f "$info_file" ]]; then
        echo "[]" > "$info_file"
        log_info "创建备份信息文件: $info_file"
    fi
    
    # 设置权限
    chmod 755 "$BACKUP_DIR"
    chmod 644 "$info_file"
    
    log_success "备份系统初始化完成"
}

# 初始化备份系统
init_backup_system

# 如果作为独立脚本运行，提供命令行接口
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    case "${1:-}" in
        "backup")
            case "${2:-}" in
                "local")
                    backup_local_certificate "$3" "$4"
                    ;;
                "remote")
                    backup_remote_certificate "$3" "$4" "$5" "$6"
                    ;;
                "all")
                    backup_all_local_certificates "$3"
                    ;;
                *)
                    log_error "请指定备份类型: local|remote|all"
                    ;;
            esac
            ;;
        "restore")
            case "${2:-}" in
                "local")
                    restore_local_certificate "$3" "$4"
                    ;;
                "remote")
                    restore_remote_certificate "$3" "$4" "$5" "$6" "$7"
                    ;;
                *)
                    log_error "请指定恢复类型: local|remote"
                    ;;
            esac
            ;;
        "list")
            list_backups "$2" "$3"
            ;;
        "cleanup")
            cleanup_old_backups "$2"
            ;;
        "verify")
            verify_backup "$2"
            ;;
        "stats")
            get_backup_stats
            ;;
        "init")
            init_backup_system
            ;;
        *)
            cat << EOF
备份工具使用说明:

用法: $0 [命令] [参数]

命令:
    backup local <域名> [备份名称]           备份本地证书
    backup remote <主机> <用户> <远程目录> [备份名称]  备份远程证书
    backup all [备份名称]                   备份所有本地证书
    restore local <域名> [备份名称]          恢复本地证书
    restore remote <域名> <主机> <用户> <远程目录> [备份名称]  恢复远程证书
    list [域名] [类型]                      列出备份
    cleanup [保留天数]                      清理过期备份
    verify <备份文件>                       验证备份文件
    stats                                   显示备份统计信息
    init                                    初始化备份系统

示例:
    $0 backup local example.com
    $0 backup remote example.com 192.168.1.100 root /opt/ssl/example.com
    $0 backup all daily_backup
    $0 restore local example.com
    $0 list example.com
    $0 cleanup 30
    $0 verify /data/backups/example.com/example.com_20231201_120000.tar.gz
    $0 stats
EOF
            ;;
    esac
fi 
