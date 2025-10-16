#!/bin/bash

# SSL证书管理主脚本
# 功能：生成、部署、更新、监控SSL证书
# 作者：SSL Certificate Manager
# 版本：1.0.0

set -euo pipefail

# 脚本目录和配置
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="/config"
CERT_DIR="/data/certs"
LOG_DIR="/data/logs"
BACKUP_DIR="/data/backups"

# 导入工具函数
source "${SCRIPT_DIR}/utils/logger.sh"
source "${SCRIPT_DIR}/utils/notify.sh"
source "${SCRIPT_DIR}/utils/backup.sh"

# 全局变量
DOMAINS_CONFIG="${CONFIG_DIR}/domains.yml"
SERVERS_CONFIG="${CONFIG_DIR}/servers.yml"
DNS_PROVIDERS_CONFIG="${CONFIG_DIR}/dns-providers.yml"
SCRIPT_NAME=$(basename "$0")

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 显示使用说明
show_usage() {
    cat << EOF
SSL证书管理工具 v1.0.0

使用方法: $SCRIPT_NAME [命令] [选项]

命令:
    generate <domain>           生成指定域名的SSL证书
    generate-all               生成所有配置域名的SSL证书
    deploy <domain> <server_id> [custom_dir]  部署指定域名的SSL证书
    deploy-all                  部署所有域名的SSL证书（自动跳过deploy_method=manual的域名）
    renew <domain>              续期指定域名的SSL证书
    renew-all                   续期所有即将过期的SSL证书
    revoke <domain>             吊销指定域名的SSL证书
    status <domain>             查看指定域名的证书状态
    status-all                  查看所有域名的证书状态
    report                      生成并发送证书状态报告
    monitor                     监控所有证书的过期状态
    list                        列出所有管理的域名
    list-manual                 列出所有需要手动部署的域名
    test <domain>               测试指定域名的SSL证书
    verify-chains               验证所有域名的证书链完整性
    health-check                健康检查
    cleanup                     清理过期的证书和日志
    init                        初始化证书管理系统
    
选项:
    -h, --help                  显示此帮助信息
    -v, --verbose               详细输出
    -f, --force                 强制执行操作
    -d, --dry-run               试运行模式
    --config-dir <dir>          指定配置目录
    --cert-dir <dir>            指定证书目录
    --log-dir <dir>             指定日志目录

示例:
    $SCRIPT_NAME generate api.zhengcetongban.com
    $SCRIPT_NAME deploy api.zhengcetongban.com server_202_209
    $SCRIPT_NAME deploy dis-beta.ly.higgses.com server_202_209 custom-dir
    $SCRIPT_NAME deploy-all
    $SCRIPT_NAME renew-all
    $SCRIPT_NAME status-all
    $SCRIPT_NAME report
    $SCRIPT_NAME monitor
    
参数说明:
    <domain>                    要操作的域名
    <server_id>                 服务器ID（在servers.yml中定义）
    [custom_dir]                可选：自定义服务器目录名称
                               如果不指定，默认使用域名作为目录名

EOF
}

# 检查依赖
check_dependencies() {
    local deps=("acme.sh" "yq" "jq" "ssh" "scp")
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            log_error "依赖 $dep 未找到"
            exit 1
        fi
    done
}

# 检查配置文件
check_config_files() {
    local configs=("$DOMAINS_CONFIG" "$SERVERS_CONFIG" "$DNS_PROVIDERS_CONFIG")
    for config in "${configs[@]}"; do
        if [[ ! -f "$config" ]]; then
            log_error "配置文件不存在: $config"
            exit 1
        fi
    done
}

# 获取域名配置
get_domain_config() {
    local domain="$1"
    local clean_domain="$domain"
    
    # 如果是泛域名请求（以*.开头），去掉*. 前缀
    if [[ "$domain" == \*.* ]]; then
        clean_domain="${domain#\*.}"
    fi
    
    # 首先尝试查找父域名配置（处理子域名情况）
    local config=""
    local parent_domain="$clean_domain"
    # 逐级查找父域名
    while [[ "$parent_domain" == *.* ]]; do
        parent_domain="${parent_domain#*.}"
        config=$(yq eval ".domains[] | select(.domain == \"$parent_domain\")" "$DOMAINS_CONFIG")
        if [[ -n "$config" ]]; then
            # 验证子域名是否在配置的子域名列表中
            local subdomain_exists
            # 尝试新格式（对象格式）
            subdomain_exists=$(echo "$config" | yq eval ".subdomains[] | select(.domain == \"$clean_domain\") | .domain" - 2>/dev/null || true)
            
            # 如果新格式没找到，尝试旧格式（字符串格式）
            if [[ -z "$subdomain_exists" ]]; then
                subdomain_exists=$(echo "$config" | yq eval ".subdomains[] | select(. == \"$clean_domain\")" - 2>/dev/null || true)
            fi
            
            if [[ -n "$subdomain_exists" ]]; then
                break
            else
                config=""
            fi
        fi
    done
    
    # 如果没有找到父域名配置，尝试精确匹配
    if [[ -z "$config" ]]; then
        config=$(yq eval ".domains[] | select(.domain == \"$clean_domain\")" "$DOMAINS_CONFIG")
    fi
    
    # 如果仍然没有找到，尝试匹配原始域名
    if [[ -z "$config" ]]; then
        config=$(yq eval ".domains[] | select(.domain == \"$domain\")" "$DOMAINS_CONFIG")
    fi
    
    echo "$config"
}

# 获取服务器配置
get_server_config() {
    local server_id="$1"
    yq eval ".servers[] | select(.server_id == \"$server_id\")" "$SERVERS_CONFIG"
}

# 获取DNS提供商配置
get_dns_provider_config() {
    local provider_id="$1"
    yq eval ".dns_providers.$provider_id" "$DNS_PROVIDERS_CONFIG"
}

# 获取子域名的部署配置
get_subdomain_deploy_config() {
    local domain="$1"
    local parent_domain="$2"
    local config_type="$3"  # deploy_dir, cert_filename, key_filename
    
    # 获取父域名配置
    local parent_config
    parent_config=$(get_domain_config "$parent_domain")
    
    if [[ -z "$parent_config" ]]; then
        echo ""
        return
    fi
    
    # 尝试获取新格式的子域名配置
    local config_value
    config_value=$(echo "$parent_config" | yq eval ".subdomains[] | select(.domain == \"$domain\") | .$config_type" - 2>/dev/null || true)
    
    if [[ -n "$config_value" && "$config_value" != "null" ]]; then
        echo "$config_value"
    else
        # 如果没有找到指定配置，返回空
        echo ""
    fi
}

# 获取子域名的部署目录（保持向后兼容）
get_subdomain_deploy_dir() {
    local domain="$1"
    local parent_domain="$2"
    get_subdomain_deploy_config "$domain" "$parent_domain" "deploy_dir"
}

# 检查域名的部署方式
check_deploy_method() {
    local domain="$1"
    local domain_config
    domain_config=$(get_domain_config "$domain")
    
    if [[ -z "$domain_config" ]]; then
        echo "auto"  # 默认为自动部署
        return
    fi
    
    local parent_domain_name
    parent_domain_name=$(echo "$domain_config" | yq eval '.domain' -)
    
    # 如果是子域名，检查子域名的deploy_method配置
    if [[ "$parent_domain_name" != "$domain" ]]; then
        local deploy_method
        deploy_method=$(get_subdomain_deploy_config "$domain" "$parent_domain_name" "deploy_method")
        
        if [[ -n "$deploy_method" && "$deploy_method" != "null" ]]; then
            echo "$deploy_method"
        else
            # 如果子域名没有配置deploy_method，使用全局默认值
            local global_default
            global_default=$(yq eval '.global.default_deploy_method' "$DOMAINS_CONFIG" 2>/dev/null || echo "auto")
            echo "$global_default"
        fi
    else
        # 如果是主域名，直接返回默认值（主域名通常自动部署）
        echo "auto"
    fi
}

# 设置DNS提供商环境变量
setup_dns_provider_env() {
    local provider_id="$1"
    local provider_config
    provider_config=$(get_dns_provider_config "$provider_id")
    
    if [[ -z "$provider_config" ]]; then
        log_error "DNS提供商配置不存在: $provider_id"
        return 1
    fi
    
    # 设置环境变量
    while IFS= read -r line; do
        if [[ "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*: ]]; then
            local key="${line%%:*}"
            local value="${line#*: }"
            # 移除引号
            value="${value//\"/}"
            export "$key"="$value"
            log_info "设置环境变量: $key=$value"
        fi
    done < <(echo "$provider_config" | yq eval '.env_vars | to_entries | .[] | .key + ": " + .value' -)
}

# 生成证书
generate_certificate() {
    local domain="$1"
    local force_flag="${2:-false}"
    
    log_info "开始生成证书: $domain"
    
    # 获取域名配置
    local domain_config
    domain_config=$(get_domain_config "$domain")
    
    if [[ -z "$domain_config" ]]; then
        log_error "域名配置不存在: $domain"
        return 1
    fi
    
    # 解析配置
    local dns_provider
    local wildcard
    local cert_type
    dns_provider=$(echo "$domain_config" | yq eval '.dns_provider' -)
    wildcard=$(echo "$domain_config" | yq eval '.wildcard' -)
    cert_type=$(echo "$domain_config" | yq eval '.cert_type' -)
    
    # 设置DNS提供商环境变量
    setup_dns_provider_env "$dns_provider"
    
    # 获取DNS提供商的acme类型
    local acme_dns_type
    acme_dns_type=$(get_dns_provider_config "$dns_provider" | yq eval '.acme_dns_type' -)
    
    # 构建acme.sh命令
    local acme_cmd="acme.sh --issue --dns $acme_dns_type"
    
    # 使用环境变量或默认密钥类型来避免架构兼容性问题
    local key_type="${ACME_KEY_TYPE:-rsa}"
    if [[ "$key_type" == "rsa" ]]; then
        acme_cmd="$acme_cmd --keylength 2048"
        log_info "使用RSA 2048位密钥（兼容性更好）"
    elif [[ "$key_type" == "ec" || "$key_type" == "ecc" ]]; then
        log_info "使用ECC密钥"
    else
        # 默认使用RSA以确保兼容性
        acme_cmd="$acme_cmd --keylength 2048"
        log_info "默认使用RSA 2048位密钥确保兼容性"
    fi
    
    # 处理域名格式，确保正确处理泛域名请求
    local base_domain="$domain"
    local is_wildcard_request=false
    
    # 检查是否为泛域名请求
    if [[ "$domain" == \*.* ]]; then
        is_wildcard_request=true
        base_domain="${domain#\*.}"
    fi
    
    if [[ "$wildcard" == "true" || "$cert_type" == "wildcard" ]]; then
        if [[ "$is_wildcard_request" == "true" ]]; then
            # 用户请求的是泛域名，生成泛域名证书
            acme_cmd="$acme_cmd -d $base_domain -d *.$base_domain"
        else
            # 用户请求的是普通域名，但配置要求泛域名证书
            acme_cmd="$acme_cmd -d $domain -d *.$domain"
        fi
    else
        acme_cmd="$acme_cmd -d $domain"
        
        # 添加子域名
        local subdomains
        # 尝试新格式（对象格式）
        subdomains=$(echo "$domain_config" | yq eval '.subdomains[]?.domain' - 2>/dev/null || true)
        
        # 如果新格式没有结果，尝试旧格式（字符串格式）
        if [[ -z "$subdomains" ]]; then
            subdomains=$(echo "$domain_config" | yq eval '.subdomains[]' - 2>/dev/null || true)
        fi
        
        if [[ -n "$subdomains" ]]; then
            while IFS= read -r subdomain; do
                if [[ -n "$subdomain" ]]; then
                    acme_cmd="$acme_cmd -d $subdomain"
                fi
            done <<< "$subdomains"
        fi
    fi
    
    # 添加强制标志
    if [[ "$force_flag" == "true" ]]; then
        acme_cmd="$acme_cmd --force"
    fi
    
    # 执行证书生成
    log_info "执行命令: $acme_cmd"
    
    if eval "$acme_cmd"; then
        log_success "证书生成成功: $domain"
        
        # 复制证书到存储目录
        local cert_storage_dir="${CERT_DIR}/${domain}"
        mkdir -p "$cert_storage_dir"
        
        local acme_cert_dir
        if [[ "$wildcard" == "true" || "$cert_type" == "wildcard" ]]; then
            acme_cert_dir="/root/.acme.sh/${domain}_ecc"
        else
            acme_cert_dir="/root/.acme.sh/${domain}"
        fi
        
        if [[ -d "$acme_cert_dir" ]]; then
            cp "$acme_cert_dir"/*.cer "$cert_storage_dir/" 2>/dev/null || true
            cp "$acme_cert_dir"/*.key "$cert_storage_dir/" 2>/dev/null || true
            log_info "证书已复制到存储目录: $cert_storage_dir"
        fi
        
        return 0
    else
        log_error "证书生成失败: $domain"
        return 1
    fi
}

# 部署证书
deploy_certificate() {
    local domain="$1"
    local server_id="$2"
    local custom_dir="$3"
    
    log_info "开始部署证书: $domain -> $server_id"
    
    # 获取域名和服务器配置
    local domain_config
    local server_config
    domain_config=$(get_domain_config "$domain")
    server_config=$(get_server_config "$server_id")
    
    if [[ -z "$domain_config" ]]; then
        log_error "域名配置不存在: $domain"
        return 1
    fi
    
    if [[ -z "$server_config" ]]; then
        log_error "服务器配置不存在: $server_id"
        return 1
    fi
    
    # 解析服务器配置
    local host port user ssl_cert_dir nginx_reload_cmd
    host=$(echo "$server_config" | yq eval '.host' -)
    port=$(echo "$server_config" | yq eval '.port' -)
    user=$(echo "$server_config" | yq eval '.user' -)
    ssl_cert_dir=$(echo "$server_config" | yq eval '.ssl_cert_dir' -)
    nginx_reload_cmd=$(echo "$server_config" | yq eval '.nginx_reload_cmd' -)
    
    # 确定证书存储域名（对于子域名，使用父域名的证书）
    local cert_domain="$domain"
    local parent_domain_name
    parent_domain_name=$(echo "$domain_config" | yq eval '.domain' -)
    
    # 如果找到的配置的域名与请求的域名不同，说明是子域名使用父域名配置
    if [[ "$parent_domain_name" != "$domain" ]]; then
        cert_domain="$parent_domain_name"
    fi
    
    # 调试信息
    log_info "请求部署域名: $domain"
    log_info "找到的配置域名: $parent_domain_name"
    log_info "使用的证书域名: $cert_domain"
    
    # 检查证书类型，如果是泛域名证书，使用通配符路径
    local cert_type
    cert_type=$(echo "$domain_config" | yq eval '.cert_type' -)
    local wildcard
    wildcard=$(echo "$domain_config" | yq eval '.wildcard' -)
    
    # 确定实际的证书存储目录
    local cert_storage_dir
    local key_file
    local cert_file
    
    if [[ "$cert_type" == "wildcard" || "$wildcard" == "true" ]]; then
        # 泛域名证书，按优先级尝试不同的目录格式
        local domain_dir="${CERT_DIR}/${cert_domain}"
        local domain_ecc_dir="${CERT_DIR}/${cert_domain}_ecc"
        local wildcard_dir_pattern="${CERT_DIR}/*.${cert_domain}"
        
        # 查找通配符目录
        local found_wildcard_dir=""
        for dir in $wildcard_dir_pattern; do
            if [[ -d "$dir" ]]; then
                found_wildcard_dir="$dir"
                break
            fi
        done
        
        # 优先级：普通域名目录 > ECC目录 > 通配符目录 > 包含域名的其他证书
        if [[ -d "$domain_dir" ]]; then
            cert_storage_dir="$domain_dir"
            key_file="${cert_storage_dir}/${cert_domain}.key"
            cert_file="${cert_storage_dir}/fullchain.cer"
            log_info "使用普通域名证书目录: $cert_storage_dir"
        elif [[ -d "$domain_ecc_dir" ]]; then
            cert_storage_dir="$domain_ecc_dir"
            key_file="${cert_storage_dir}/${cert_domain}.key"
            cert_file="${cert_storage_dir}/fullchain.cer"
            log_info "使用ECC证书目录: $cert_storage_dir"
        elif [[ -n "$found_wildcard_dir" ]]; then
            cert_storage_dir="$found_wildcard_dir"
            # 通配符目录中的文件名使用域名而不是目录名
            key_file="${cert_storage_dir}/${cert_domain}.key"
            cert_file="${cert_storage_dir}/fullchain.cer"
            log_info "使用泛域名证书目录: $cert_storage_dir"
        else
            # 尝试查找包含该域名的其他证书目录
            local found_cert_dir=""
            for cert_dir in "${CERT_DIR}"/*; do
                if [[ -d "$cert_dir" ]]; then
                    local cert_file_path="${cert_dir}/fullchain.cer"
                    if [[ -f "$cert_file_path" ]]; then
                        # 检查证书是否包含目标域名（支持通配符匹配）
                        if openssl x509 -in "$cert_file_path" -text -noout 2>/dev/null | grep -q "DNS:.*${domain}\|DNS:\*\.${domain#*.}"; then
                            found_cert_dir="$cert_dir"
                            break
                        fi
                    fi
                fi
            done
            
            if [[ -n "$found_cert_dir" ]]; then
                cert_storage_dir="$found_cert_dir"
                # 从目录名提取域名作为文件名前缀
                local dir_name=$(basename "$found_cert_dir")
                key_file="${cert_storage_dir}/${dir_name}.key"
                cert_file="${cert_storage_dir}/fullchain.cer"
                log_info "找到包含域名的证书目录: $cert_storage_dir"
            else
                # 都不存在，使用默认路径
                cert_storage_dir="$domain_dir"
                key_file="${cert_storage_dir}/${cert_domain}.key"
                cert_file="${cert_storage_dir}/fullchain.cer"
                log_info "使用默认证书目录: $cert_storage_dir"
            fi
        fi
    else
        # 先尝试 ECC 证书路径，再尝试 RSA 证书路径 - 优先使用完整证书链
        cert_file="${CERT_DIR}/${domain}_ecc/fullchain.cer"
        if [[ ! -f "$cert_file" ]]; then
            cert_file="${CERT_DIR}/${domain}/fullchain.cer"
            if [[ ! -f "$cert_file" ]]; then
                # 如果完整证书链不存在，尝试单个证书文件（但记录警告）
                cert_file="${CERT_DIR}/${domain}_ecc/${domain}.cer"
                if [[ ! -f "$cert_file" ]]; then
                    cert_file="${CERT_DIR}/${domain}/${domain}.cer"
                fi
                if [[ -f "$cert_file" ]]; then
                    log_warn "使用单个证书文件而非完整证书链: $cert_file"
                fi
            fi
        fi
    fi
    
    # 检查证书文件是否存在
    log_info "检查证书文件: $key_file"
    log_info "检查证书文件: $cert_file"
    
    if [[ ! -f "$key_file" ]] || [[ ! -f "$cert_file" ]]; then 
        log_error "证书文件不存在: $key_file 或 $cert_file"
        return 1
    fi
    
    # 验证证书链的完整性
    local cert_count
    cert_count=$(grep -c 'BEGIN CERTIFICATE' "$cert_file" 2>/dev/null || echo "0")
    if [[ $cert_count -lt 2 ]]; then
        log_warn "证书链不完整，只包含 $cert_count 个证书。建议使用完整证书链。"
        log_warn "当前证书文件: $cert_file"
        
        # 尝试查找完整证书链文件
        local fullchain_file="${cert_storage_dir}/fullchain.cer"
        if [[ -f "$fullchain_file" && "$cert_file" != "$fullchain_file" ]]; then
            local fullchain_count
            fullchain_count=$(grep -c 'BEGIN CERTIFICATE' "$fullchain_file" 2>/dev/null || echo "0")
            if [[ $fullchain_count -ge 2 ]]; then
                log_info "找到完整证书链文件，切换使用: $fullchain_file"
                cert_file="$fullchain_file"
            fi
        fi
    else
        log_info "证书链验证通过，包含 $cert_count 个证书"
    fi
    
    # 远程证书目录
    local remote_cert_dir
    if [[ -n "$custom_dir" ]]; then
        # 使用自定义目录
        remote_cert_dir="${ssl_cert_dir}/${custom_dir}"
        log_info "使用自定义目录: $custom_dir"
    else
        # 尝试从配置文件中获取子域名的部署目录
        local config_deploy_dir
        config_deploy_dir=$(get_subdomain_deploy_dir "$domain" "$parent_domain_name")
        
        if [[ -n "$config_deploy_dir" ]]; then
            # 使用配置文件中的部署目录
            remote_cert_dir="${ssl_cert_dir}/${config_deploy_dir}"
            log_info "使用配置的部署目录: $config_deploy_dir"
        else
            # 检查是否是父域名的子域名，如果是则使用父域名作为部署目录
            if [[ "$parent_domain_name" != "$domain" ]]; then
                # 对于子域名，使用父域名作为部署目录
                remote_cert_dir="${ssl_cert_dir}/${parent_domain_name}"
                log_info "使用父域名部署目录: $parent_domain_name"
            else
                # 使用默认目录（域名）
                remote_cert_dir="${ssl_cert_dir}/${domain}"
                log_info "使用默认目录: $domain"
            fi
        fi
    fi
    
    # 获取配置的文件名
    local remote_key_filename=""
    local remote_cert_filename=""
    
    # 获取子域名配置的文件名（即使是主域名也可能是自己的子域名配置）
    remote_key_filename=$(get_subdomain_deploy_config "$domain" "$parent_domain_name" "key_filename")
    remote_cert_filename=$(get_subdomain_deploy_config "$domain" "$parent_domain_name" "cert_filename")
    
    # 如果没有配置文件名，使用默认文件名
    if [[ -z "$remote_key_filename" ]]; then
        remote_key_filename="${domain}.key"
    fi
    
    if [[ -z "$remote_cert_filename" ]]; then
        # 默认使用 .cer 作为扩展名，但实际内容是完整证书链 (fullchain)
        remote_cert_filename="${domain}.cer"
    fi
    
    local remote_key_file="${remote_cert_dir}/${remote_key_filename}"
    local remote_cert_file="${remote_cert_dir}/${remote_cert_filename}"
    
    log_info "远程文件映射: 私钥 -> $remote_key_file"
    log_info "远程文件映射: 证书 -> $remote_cert_file (使用完整证书链)"
    
    # SSH选项
    local ssh_opts="-o ConnectTimeout=10 -o BatchMode=yes -o StrictHostKeyChecking=accept-new"
    
    # 创建远程目录
    if ssh $ssh_opts "${user}@${host}" "mkdir -p ${remote_cert_dir}"; then
        log_info "远程目录创建成功: ${remote_cert_dir}"
    else
        log_error "远程目录创建失败: ${remote_cert_dir}"
        return 1
    fi
    
    # 备份现有证书
    backup_remote_certificate "$host" "$user" "$remote_cert_dir"
    
    # 上传证书文件
    if scp $ssh_opts "$key_file" "${user}@${host}:${remote_key_file}"; then
        log_info "私钥文件上传成功"
    else
        log_error "私钥文件上传失败"
        return 1
    fi
    
    if scp $ssh_opts "$cert_file" "${user}@${host}:${remote_cert_file}"; then
        log_info "证书文件上传成功"
    else
        log_error "证书文件上传失败"
        return 1
    fi
    
    # 设置文件权限
    ssh $ssh_opts "${user}@${host}" "chmod 600 ${remote_key_file} ${remote_cert_file}"
    
    # 重启Nginx
    if ssh $ssh_opts "${user}@${host}" "$nginx_reload_cmd"; then
        log_success "Nginx重启成功"
    else
        log_error "Nginx重启失败"
        return 1
    fi
    
    # 验证部署
    sleep 5
    if verify_certificate_deployment "$domain" "$host"; then
        log_success "证书部署验证成功: $domain"
        return 0
    else
        log_warn "证书部署验证失败: $domain"
        return 1
    fi
}

# 验证证书部署
verify_certificate_deployment() {
    local domain="$1"
    local host="$2"
    
    log_info "验证证书部署状态: $domain"
    
    # 检查SSL证书基本信息
    local cert_info
    cert_info=$(echo | openssl s_client -servername "$domain" -connect "${host}:443" 2>/dev/null | openssl x509 -noout -dates 2>/dev/null || true)
    
    if [[ -n "$cert_info" ]]; then
        log_info "SSL证书基本验证通过: $domain"
        
        # 验证证书链完整性
        local cert_chain_count
        cert_chain_count=$(echo | openssl s_client -servername "$domain" -connect "${host}:443" -showcerts 2>/dev/null | grep -c 'BEGIN CERTIFICATE' || echo "0")
        
        if [[ $cert_chain_count -ge 2 ]]; then
            log_success "证书链验证通过: $domain (包含 $cert_chain_count 个证书)"
        elif [[ $cert_chain_count -eq 1 ]]; then
            log_warn "证书链不完整: $domain (只包含 $cert_chain_count 个证书)"
            log_warn "微信小程序等应用可能无法验证此证书"
        else
            log_error "无法获取证书链信息: $domain"
        fi
        
        # 验证证书链的有效性
        local verify_result
        verify_result=$(echo | openssl s_client -servername "$domain" -connect "${host}:443" -verify_return_error 2>/dev/null | grep "Verify return code" || echo "")
        
        if [[ "$verify_result" == *"Verify return code: 0 (ok)"* ]]; then
            log_success "证书链可信度验证通过: $domain"
        else
            log_warn "证书链可信度验证失败: $domain"
            log_warn "验证结果: $verify_result"
        fi
        
        return 0
    else
        log_warn "SSL证书验证失败: $domain"
        return 1
    fi
}

# 续期证书
renew_certificate() {
    local domain="$1"
    
    log_info "开始续期证书: $domain"
    
    # 检查证书是否需要续期
    if ! check_certificate_expiry "$domain"; then
        log_info "证书尚未到期，跳过续期: $domain"
        return 0
    fi
    
    # 生成新证书
    if generate_certificate "$domain" "true"; then
        log_info "证书续期成功: $domain"
        
        # 自动部署到所有配置的服务器
        local domain_config
        domain_config=$(get_domain_config "$domain")
        
        local servers
        servers=$(echo "$domain_config" | yq eval '.servers[]' - 2>/dev/null || true)
        
        if [[ -n "$servers" ]]; then
            while IFS= read -r server_id; do
                if [[ -n "$server_id" ]]; then
                    deploy_certificate "$domain" "$server_id"
                fi
            done <<< "$servers"
        fi
        
        return 0
    else
        log_error "证书续期失败: $domain"
        return 1
    fi
}

# 检查证书过期
check_certificate_expiry() {
    local domain="$1"
    local days_threshold="${2:-30}"
    
    # 先尝试 ECC 证书路径，再尝试 RSA 证书路径 - 优先使用完整证书链
    local cert_file="${CERT_DIR}/${domain}_ecc/fullchain.cer"
    if [[ ! -f "$cert_file" ]]; then
        cert_file="${CERT_DIR}/${domain}/fullchain.cer"
        if [[ ! -f "$cert_file" ]]; then
            # 如果完整证书链不存在，尝试单个证书文件（但记录警告）
            cert_file="${CERT_DIR}/${domain}_ecc/${domain}.cer"
            if [[ ! -f "$cert_file" ]]; then
                cert_file="${CERT_DIR}/${domain}/${domain}.cer"
            fi
            if [[ -f "$cert_file" ]]; then
                log_warn "使用单个证书文件而非完整证书链: $cert_file"
            fi
        fi
    fi
    
    if [[ ! -f "$cert_file" ]]; then
        log_warn "证书文件不存在: $cert_file"
        return 0
    fi
    
    local expiry_date
    expiry_date=$(openssl x509 -in "$cert_file" -noout -enddate 2>/dev/null | cut -d= -f2)
    
    if [[ -z "$expiry_date" ]]; then
        log_warn "无法获取证书过期时间: $domain"
        return 0
    fi
    
    # 使用 OpenSSL 的日期格式进行解析
    # 转换 "Oct 10 04:05:11 2025 GMT" 为 "2025-10-10 04:05:11"
    local expiry_timestamp
    
    # 解析日期各部分
    local month_str day hour_min_sec year tz
    read -r month_str day hour_min_sec year tz <<< "$expiry_date"
    
    # 月份映射
    local month_num
    case "$month_str" in
        "Jan") month_num="01" ;;
        "Feb") month_num="02" ;;
        "Mar") month_num="03" ;;
        "Apr") month_num="04" ;;
        "May") month_num="05" ;;
        "Jun") month_num="06" ;;
        "Jul") month_num="07" ;;
        "Aug") month_num="08" ;;
        "Sep") month_num="09" ;;
        "Oct") month_num="10" ;;
        "Nov") month_num="11" ;;
        "Dec") month_num="12" ;;
        *) month_num="00" ;;
    esac
    
    # 格式化日期
    local iso_date="${year}-${month_num}-${day} ${hour_min_sec}"
    expiry_timestamp=$(date -d "$iso_date" +%s 2>/dev/null || echo "0")
    
    if [[ "$expiry_timestamp" -eq "0" ]]; then
        log_warn "无法解析证书过期时间: $domain ($expiry_date)"
        return 0
    fi
    
    local current_timestamp
    current_timestamp=$(date +%s)
    local threshold_timestamp
    threshold_timestamp=$((current_timestamp + days_threshold * 86400))
    
    if [[ $expiry_timestamp -lt $threshold_timestamp ]]; then
        log_warn "证书即将过期: $domain (过期时间: $expiry_date)"
        return 0
    else
        log_info "证书有效期正常: $domain (过期时间: $expiry_date)"
        return 1
    fi
}

# 监控所有证书
monitor_certificates() {
    log_info "开始监控所有证书"
    
    local domains
    domains=$(yq eval '.domains[].domain' "$DOMAINS_CONFIG")
    
    local expired_count=0
    local total_count=0
    
    while IFS= read -r domain; do
        if [[ -n "$domain" ]]; then
            total_count=$((total_count + 1))
            
            if check_certificate_expiry "$domain"; then
                expired_count=$((expired_count + 1))
                
                # 发送告警通知
                send_notification "证书即将过期" "域名 $domain 的SSL证书即将过期，请及时续期。"
            fi
        fi
    done <<< "$domains"
    
    log_info "证书监控完成: 总计 $total_count 个域名，其中 $expired_count 个即将过期"
    
    # 更新监控统计
    update_monitoring_stats "$total_count" "$expired_count"
}

# 更新监控统计
update_monitoring_stats() {
    local total_count="$1"
    local expired_count="$2"
    
    local stats_file="${LOG_DIR}/monitoring_stats.json"
    
    cat > "$stats_file" << EOF
{
    "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
    "total_certificates": $total_count,
    "expiring_certificates": $expired_count,
    "healthy_certificates": $((total_count - expired_count))
}
EOF
}

# 生成并发送证书状态报告
generate_and_send_report() {
    log_info "开始生成证书状态报告"
    
    local domains
    domains=$(yq eval '.domains[].domain' "$DOMAINS_CONFIG")
    
    local report_file="${LOG_DIR}/certificate_report_$(date +%Y%m%d_%H%M%S).txt"
    local total_count=0
    local expired_count=0
    local healthy_count=0
    
    # 生成报告文件
    cat > "$report_file" << 'EOF'
SSL证书状态报告
=====================================

报告时间: $(date '+%Y-%m-%d %H:%M:%S')
报告生成: SSL证书自动管理系统

证书状态详情:
-------------------------------------
EOF
    
    # 替换模板中的变量
    sed -i "s/\$(date '+%Y-%m-%d %H:%M:%S')/$(date '+%Y-%m-%d %H:%M:%S')/g" "$report_file"
    
    # 检查每个域名的证书状态
    local report_content=""
    while IFS= read -r domain; do
        if [[ -n "$domain" ]]; then
            total_count=$((total_count + 1))
            
            # 检查证书是否存在 - 优先使用完整证书链
            local cert_file=""
            if [[ -f "${CERT_DIR}/${domain}_ecc/fullchain.cer" ]]; then
                cert_file="${CERT_DIR}/${domain}_ecc/fullchain.cer"
            elif [[ -f "${CERT_DIR}/${domain}/fullchain.cer" ]]; then
                cert_file="${CERT_DIR}/${domain}/fullchain.cer"
            elif [[ -f "${CERT_DIR}/${domain}_ecc/${domain}.cer" ]]; then
                cert_file="${CERT_DIR}/${domain}_ecc/${domain}.cer"
                log_warn "使用单个证书文件而非完整证书链: $cert_file"
            elif [[ -f "${CERT_DIR}/${domain}/${domain}.cer" ]]; then
                cert_file="${CERT_DIR}/${domain}/${domain}.cer"
                log_warn "使用单个证书文件而非完整证书链: $cert_file"
            fi
            
            if [[ -n "$cert_file" && -f "$cert_file" ]]; then
                # 获取证书过期时间
                local expiry_date
                expiry_date=$(openssl x509 -in "$cert_file" -noout -enddate 2>/dev/null | cut -d= -f2)
                
                if [[ -n "$expiry_date" ]]; then
                    # 计算天数
                    local expiry_timestamp current_timestamp days_remaining
                    expiry_timestamp=$(date -d "$expiry_date" +%s 2>/dev/null)
                    current_timestamp=$(date +%s)
                    days_remaining=$(( (expiry_timestamp - current_timestamp) / 86400 ))
                    
                    local status_icon status_text
                    if [[ $days_remaining -le 0 ]]; then
                        status_icon="❌"
                        status_text="已过期"
                        expired_count=$((expired_count + 1))
                    elif [[ $days_remaining -le 7 ]]; then
                        status_icon="⚠️"
                        status_text="即将过期"
                        expired_count=$((expired_count + 1))
                    elif [[ $days_remaining -le 30 ]]; then
                        status_icon="🔶"
                        status_text="需要关注"
                        healthy_count=$((healthy_count + 1))
                    else
                        status_icon="✅"
                        status_text="正常"
                        healthy_count=$((healthy_count + 1))
                    fi
                    
                    report_content="${report_content}${status_icon} ${domain}
   状态: ${status_text}
   过期时间: ${expiry_date}
   剩余天数: ${days_remaining}天

"
                else
                    report_content="${report_content}❓ ${domain}
   状态: 无法读取证书信息
   过期时间: 未知

"
                fi
            else
                report_content="${report_content}❌ ${domain}
   状态: 证书文件不存在
   过期时间: 未知

"
            fi
        fi
    done <<< "$domains"
    
    # 添加内容到报告文件
    echo "$report_content" >> "$report_file"
    
    # 添加统计信息
    cat >> "$report_file" << EOF
统计信息:
-------------------------------------
总证书数: $total_count
健康证书: $healthy_count
需要关注: $((total_count - healthy_count - expired_count))
即将过期: $expired_count

系统信息:
-------------------------------------
主机名: $(hostname)
系统时间: $(date '+%Y-%m-%d %H:%M:%S')
证书目录: $CERT_DIR
日志目录: $LOG_DIR

备注:
- 7天内过期的证书标记为"即将过期"
- 30天内过期的证书标记为"需要关注"
- 系统会自动续期即将过期的证书

====================================
SSL证书自动管理系统
报告生成完成
====================================
EOF
    
    # 发送报告通知
    local report_summary="SSL证书状态报告 - 总数:$total_count 健康:$healthy_count 预警:$expired_count"
    local report_message="证书状态报告已生成，详情请查看附件。

📊 证书统计:
• 总证书数: $total_count
• 健康证书: $healthy_count  
• 需要关注: $((total_count - healthy_count - expired_count))
• 即将过期: $expired_count

📁 报告文件: $report_file
🕐 生成时间: $(date '+%Y-%m-%d %H:%M:%S')"
    
    # 发送通知
    send_notification "$report_summary" "$report_message" "info"
    
    log_info "证书状态报告已生成: $report_file"
    log_info "报告统计 - 总数:$total_count 健康:$healthy_count 预警:$expired_count"
    
    # 输出报告内容到日志
    log_info "报告内容:"
    cat "$report_file"
    
    return 0
}

# 健康检查
health_check() {
    local exit_code=0
    
    # 检查配置文件
    if ! check_config_files; then
        exit_code=1
    fi
    
    # 检查依赖
    if ! check_dependencies; then
        exit_code=1
    fi
    
    # 检查日志目录
    if [[ ! -d "$LOG_DIR" ]]; then
        mkdir -p "$LOG_DIR"
    fi
    
    # 检查证书目录
    if [[ ! -d "$CERT_DIR" ]]; then
        mkdir -p "$CERT_DIR"
    fi
    
    if [[ $exit_code -eq 0 ]]; then
        log_info "健康检查通过"
        echo "OK"
    else
        log_error "健康检查失败"
        echo "FAIL"
    fi
    
    return $exit_code
}

# 验证所有域名的证书链完整性
verify_chains() {
    log_info "开始验证所有域名的证书链完整性"
    
    local domains
    domains=$(yq eval '.domains[].domain' "$DOMAINS_CONFIG")
    
    local total_count=0
    local complete_chains=0
    local incomplete_chains=0
    local missing_certs=0
    
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "📋 SSL证书链完整性验证报告"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    while IFS= read -r domain; do
        if [[ -n "$domain" ]]; then
            total_count=$((total_count + 1))
            
            # 检查本地证书文件
            local cert_file=""
            if [[ -f "${CERT_DIR}/${domain}_ecc/fullchain.cer" ]]; then
                cert_file="${CERT_DIR}/${domain}_ecc/fullchain.cer"
            elif [[ -f "${CERT_DIR}/${domain}/fullchain.cer" ]]; then
                cert_file="${CERT_DIR}/${domain}/fullchain.cer"
            elif [[ -f "${CERT_DIR}/${domain}_ecc/${domain}.cer" ]]; then
                cert_file="${CERT_DIR}/${domain}_ecc/${domain}.cer"
            elif [[ -f "${CERT_DIR}/${domain}/${domain}.cer" ]]; then
                cert_file="${CERT_DIR}/${domain}/${domain}.cer"
            fi
            
            if [[ -n "$cert_file" && -f "$cert_file" ]]; then
                # 检查证书链
                local cert_count
                cert_count=$(grep -c 'BEGIN CERTIFICATE' "$cert_file" 2>/dev/null || echo "0")
                
                if [[ $cert_count -ge 2 ]]; then
                    echo "✅ $domain: 完整证书链 ($cert_count 个证书) - $(basename "$cert_file")"
                    complete_chains=$((complete_chains + 1))
                elif [[ $cert_count -eq 1 ]]; then
                    echo "⚠️  $domain: 不完整证书链 ($cert_count 个证书) - $(basename "$cert_file")"
                    echo "   📝 建议: 使用 fullchain.cer 文件包含完整证书链"
                    incomplete_chains=$((incomplete_chains + 1))
                else
                    echo "❌ $domain: 证书文件损坏或格式错误 - $(basename "$cert_file")"
                    incomplete_chains=$((incomplete_chains + 1))
                fi
                
                # 获取证书过期时间
                local expiry_date
                expiry_date=$(openssl x509 -in "$cert_file" -noout -enddate 2>/dev/null | cut -d= -f2 || echo "未知")
                echo "   📅 过期时间: $expiry_date"
                
            else
                echo "❌ $domain: 证书文件不存在"
                missing_certs=$((missing_certs + 1))
            fi
            
            echo ""
        fi
    done <<< "$domains"
    
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "📊 统计结果:"
    echo "• 总域名数: $total_count"
    echo "• 完整证书链: $complete_chains"
    echo "• 不完整证书链: $incomplete_chains"
    echo "• 缺失证书: $missing_certs"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    if [[ $incomplete_chains -gt 0 || $missing_certs -gt 0 ]]; then
        echo ""
        echo "🔧 修复建议:"
        echo "1. 重新生成证书: docker exec acme-ssl-manager /scripts/cert-manager.sh generate <domain>"
        echo "2. 确保部署时使用完整证书链"
        echo "3. 验证微信小程序等应用的访问"
        echo ""
        log_warn "发现 $((incomplete_chains + missing_certs)) 个需要修复的证书问题"
        return 1
    else
        log_success "所有域名的证书链都完整正确"
        return 0
    fi
}

# 主函数
main() {
    # 检查参数
    if [[ $# -eq 0 ]]; then
        show_usage
        exit 1
    fi
    
    # 解析命令行参数
    local command="$1"
    shift
    
    case "$command" in
        "generate")
            if [[ $# -eq 0 ]]; then
                log_error "请指定域名"
                exit 1
            fi
            local force_flag="false"
            if [[ $# -gt 1 && ("$2" == "--force" || "$2" == "-f") ]]; then
                force_flag="true"
            fi
            generate_certificate "$1" "$force_flag"
            ;;
        "generate-all")
            local domains
            domains=$(yq eval '.domains[].domain' "$DOMAINS_CONFIG")
            while IFS= read -r domain; do
                if [[ -n "$domain" ]]; then
                    generate_certificate "$domain" "${1:-false}"
                fi
            done <<< "$domains"
            ;;
        "deploy")
            if [[ $# -lt 2 ]]; then
                log_error "请指定域名和服务器ID"
                exit 1
            fi
            deploy_certificate "$1" "$2" "${3:-}"
            ;;
        "deploy-all")
            local domains
            domains=$(yq eval '.domains[].domain' "$DOMAINS_CONFIG")
            local deployed_count=0
            local skipped_count=0
            
            while IFS= read -r domain; do
                if [[ -n "$domain" ]]; then
                    local domain_config
                    domain_config=$(get_domain_config "$domain")
                    local servers
                    servers=$(echo "$domain_config" | yq eval '.servers[]' - 2>/dev/null || true)
                    
                    if [[ -n "$servers" ]]; then
                        # 检查主域名的部署方式
                        local main_deploy_method
                        main_deploy_method=$(check_deploy_method "$domain")
                        
                        if [[ "$main_deploy_method" == "auto" ]]; then
                            # 部署主域名
                            while IFS= read -r server_id; do
                                if [[ -n "$server_id" ]]; then
                                    if deploy_certificate "$domain" "$server_id" ""; then
                                        deployed_count=$((deployed_count + 1))
                                    fi
                                fi
                            done <<< "$servers"
                        else
                            log_info "跳过手动部署域名: $domain (deploy_method: $main_deploy_method)"
                            skipped_count=$((skipped_count + 1))
                        fi
                        
                        # 部署子域名
                        local subdomains
                        # 尝试新格式（对象格式）
                        subdomains=$(echo "$domain_config" | yq eval '.subdomains[]?.domain' - 2>/dev/null || true)
                        
                        # 如果新格式没有结果，尝试旧格式（字符串格式）
                        if [[ -z "$subdomains" ]]; then
                            subdomains=$(echo "$domain_config" | yq eval '.subdomains[]' - 2>/dev/null || true)
                        fi
                        
                        if [[ -n "$subdomains" ]]; then
                            while IFS= read -r subdomain; do
                                if [[ -n "$subdomain" ]]; then
                                    # 检查子域名的部署方式
                                    local sub_deploy_method
                                    sub_deploy_method=$(check_deploy_method "$subdomain")
                                    
                                    if [[ "$sub_deploy_method" == "auto" ]]; then
                                        while IFS= read -r server_id; do
                                            if [[ -n "$server_id" ]]; then
                                                if deploy_certificate "$subdomain" "$server_id" ""; then
                                                    deployed_count=$((deployed_count + 1))
                                                fi
                                            fi
                                        done <<< "$servers"
                                    else
                                        log_info "跳过手动部署域名: $subdomain (deploy_method: $sub_deploy_method)"
                                        skipped_count=$((skipped_count + 1))
                                    fi
                                fi
                            done <<< "$subdomains"
                        fi
                    fi
                fi
            done <<< "$domains"
            
            log_info "批量部署完成: 已部署 $deployed_count 个域名，跳过 $skipped_count 个手动部署域名"
            ;;
        "renew")
            if [[ $# -eq 0 ]]; then
                log_error "请指定域名"
                exit 1
            fi
            renew_certificate "$1"
            ;;
        "renew-all")
            local domains
            domains=$(yq eval '.domains[].domain' "$DOMAINS_CONFIG")
            while IFS= read -r domain; do
                if [[ -n "$domain" ]]; then
                    renew_certificate "$domain"
                fi
            done <<< "$domains"
            ;;
        "monitor")
            monitor_certificates
            ;;
        "health-check")
            health_check
            ;;
        "status")
            if [[ $# -eq 0 ]]; then
                log_error "请指定域名"
                exit 1
            fi
            check_certificate_expiry "$1"
            ;;
        "status-all")
            local domains
            domains=$(yq eval '.domains[].domain' "$DOMAINS_CONFIG")
            while IFS= read -r domain; do
                if [[ -n "$domain" ]]; then
                    check_certificate_expiry "$domain" || true
                fi
            done <<< "$domains"
            ;;
        "report")
            generate_and_send_report
            ;;
        "list")
            log_info "已配置的域名:"
            yq eval '.domains[] | .domain + " (" + .description + ")"' "$DOMAINS_CONFIG"
            ;;
        "list-manual")
            log_info "需要手动部署的域名:"
            local domains
            domains=$(yq eval '.domains[].domain' "$DOMAINS_CONFIG")
            local manual_count=0
            
            while IFS= read -r domain; do
                if [[ -n "$domain" ]]; then
                    local domain_config
                    domain_config=$(get_domain_config "$domain")
                    
                    # 检查子域名
                    local subdomains
                    subdomains=$(echo "$domain_config" | yq eval '.subdomains[]?.domain' - 2>/dev/null || true)
                    
                    if [[ -n "$subdomains" ]]; then
                        while IFS= read -r subdomain; do
                            if [[ -n "$subdomain" ]]; then
                                local deploy_method
                                deploy_method=$(check_deploy_method "$subdomain")
                                
                                if [[ "$deploy_method" == "manual" ]]; then
                                    echo "  - $subdomain (手动部署到CDN)"
                                    manual_count=$((manual_count + 1))
                                fi
                            fi
                        done <<< "$subdomains"
                    fi
                fi
            done <<< "$domains"
            
            if [[ $manual_count -eq 0 ]]; then
                log_info "没有需要手动部署的域名"
            else
                log_info "共找到 $manual_count 个需要手动部署的域名"
            fi
            ;;
        "init")
            log_info "初始化证书管理系统"
            mkdir -p "$CERT_DIR" "$LOG_DIR" "$BACKUP_DIR"
            health_check
            ;;
        "help"|"-h"|"--help")
            show_usage
            ;;
        "verify-chains")
            verify_chains
            ;;
        *)
            log_error "未知命令: $command"
            show_usage
            exit 1
            ;;
    esac
}

# 脚本入口
main "$@" 
