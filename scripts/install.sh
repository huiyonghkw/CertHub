#!/bin/bash

# SSL证书管理系统一键安装脚本
# 版本：1.0.0

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 配置变量
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ACME_DIR="$(dirname "$SCRIPT_DIR")"
PROJECT_ROOT="$(dirname "$ACME_DIR")"

# 日志函数
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# 显示欢迎信息
show_welcome() {
    clear
    cat << 'EOF'
 ___ ___ _           ___ ___ ___ _____   __  __               
/ __/ __| |         / __| __| _ \_   _| |  \/  |__ _ _ _  __ _ 
\__ \__ \ |__      | (__| _||   / | |   | |\/| / _` | ' \/ _` |
|___/___/____|      \___|___|_|_\ |_|   |_|  |_\__,_|_||_\__,_|
                                                              
          SSL证书自动管理系统 - 一键安装脚本
          
EOF
    echo -e "${GREEN}欢迎使用SSL证书自动管理系统安装脚本！${NC}"
    echo -e "${BLUE}此脚本将帮助您快速设置和配置SSL证书管理系统。${NC}"
    echo ""
}

# 检查系统要求
check_requirements() {
    log_info "检查系统要求..."
    
    # 检查Docker
    if ! command -v docker &> /dev/null; then
        log_error "Docker未安装，请先安装Docker"
        exit 1
    fi
    
    # 检查Docker Compose
    if ! command -v docker-compose &> /dev/null; then
        log_error "Docker Compose未安装，请先安装Docker Compose"
        exit 1
    fi
    
    # 检查yq
    if ! command -v yq &> /dev/null; then
        log_warn "yq未安装，建议安装yq以便更好地处理YAML文件"
    fi
    
    # 检查jq
    if ! command -v jq &> /dev/null; then
        log_warn "jq未安装，建议安装jq以便更好地处理JSON文件"
    fi
    
    log_success "系统要求检查完成"
}

# 创建目录结构
create_directories() {
    log_info "创建目录结构..."
    
    # 创建必要目录
    mkdir -p "$ACME_DIR/data/certs"
    mkdir -p "$ACME_DIR/data/logs"
    mkdir -p "$ACME_DIR/data/backups"
    mkdir -p "$ACME_DIR/config"
    mkdir -p "$ACME_DIR/web"
    
    log_success "目录结构创建完成"
}

# 复制配置文件
copy_config_files() {
    log_info "复制配置文件..."
    
    # 复制配置文件模板
    if [[ ! -f "$ACME_DIR/config/domains.yml" ]]; then
        cp "$ACME_DIR/config/domains.yml.example" "$ACME_DIR/config/domains.yml"
        log_info "已复制域名配置文件模板"
    fi
    
    if [[ ! -f "$ACME_DIR/config/servers.yml" ]]; then
        cp "$ACME_DIR/config/servers.yml.example" "$ACME_DIR/config/servers.yml"
        log_info "已复制服务器配置文件模板"
    fi
    
    if [[ ! -f "$ACME_DIR/config/dns-providers.yml" ]]; then
        cp "$ACME_DIR/config/dns-providers.yml.example" "$ACME_DIR/config/dns-providers.yml"
        log_info "已复制DNS提供商配置文件模板"
    fi
    
    log_success "配置文件复制完成"
}

# 交互式配置
interactive_config() {
    log_info "开始交互式配置..."
    
    echo ""
    echo -e "${YELLOW}请回答以下问题来配置系统：${NC}"
    echo ""
    
    # 配置DNS提供商
    read -p "选择DNS提供商 (1: 阿里云, 2: 腾讯云): " dns_choice
    case $dns_choice in
        1)
            dns_provider="aliyun"
            read -p "请输入阿里云AccessKey ID: " ali_key
            read -p "请输入阿里云AccessKey Secret: " ali_secret
            ;;
        2)
            dns_provider="tencent"
            read -p "请输入腾讯云SecretId: " tencent_id
            read -p "请输入腾讯云SecretKey: " tencent_key
            ;;
        *)
            log_warn "无效选择，跳过DNS配置"
            ;;
    esac
    
    # 配置域名
    echo ""
    read -p "请输入要管理的域名 (例如: example.com): " domain
    read -p "请输入子域名 (例如: api.example.com，多个用逗号分隔): " subdomains
    
    # 配置服务器
    echo ""
    read -p "请输入目标服务器IP地址: " server_ip
    read -p "请输入SSH用户名 (默认: root): " ssh_user
    ssh_user=${ssh_user:-root}
    read -p "请输入SSL证书存储目录 (默认: /opt/docker/nginx/ssl): " ssl_dir
    ssl_dir=${ssl_dir:-/opt/docker/nginx/ssl}
    
    # 写入配置
    update_config_files
    
    log_success "交互式配置完成"
}

# 更新配置文件
update_config_files() {
    log_info "更新配置文件..."
    
    # 更新DNS配置
    if [[ -n "$dns_provider" ]]; then
        local dns_config_file="$ACME_DIR/config/dns-providers.yml"
        
        case $dns_provider in
            "aliyun")
                if [[ -n "$ali_key" && -n "$ali_secret" ]]; then
                    sed -i "s/YOUR_ALIYUN_ACCESS_KEY_ID/$ali_key/g" "$dns_config_file"
                    sed -i "s/YOUR_ALIYUN_ACCESS_KEY_SECRET/$ali_secret/g" "$dns_config_file"
                    log_info "已更新阿里云DNS配置"
                fi
                ;;
            "tencent")
                if [[ -n "$tencent_id" && -n "$tencent_key" ]]; then
                    sed -i "s/YOUR_TENCENT_SECRET_ID/$tencent_id/g" "$dns_config_file"
                    sed -i "s/YOUR_TENCENT_SECRET_KEY/$tencent_key/g" "$dns_config_file"
                    log_info "已更新腾讯云DNS配置"
                fi
                ;;
        esac
    fi
    
    # 更新域名配置
    if [[ -n "$domain" ]]; then
        local domain_config_file="$ACME_DIR/config/domains.yml"
        
        # 创建临时配置
        cat > "$domain_config_file" << EOF
# SSL证书域名配置文件
domains:
  - domain: $domain
    subdomains:
EOF
        
        # 添加子域名
        if [[ -n "$subdomains" ]]; then
            IFS=',' read -ra subdomain_array <<< "$subdomains"
            for subdomain in "${subdomain_array[@]}"; do
                echo "      - $(echo $subdomain | xargs)" >> "$domain_config_file"
            done
        fi
        
        cat >> "$domain_config_file" << EOF
    wildcard: true
    dns_provider: $dns_provider
    servers:
      - custom_server
    cert_type: wildcard
    auto_renew: true
    renew_before_days: 30
    description: "自动配置的域名"

global:
  check_interval: 24
  default_renew_before_days: 30
  cert_base_dir: "/data/certs"
  log_level: INFO
  max_concurrent_tasks: 3
  retry_count: 3
  retry_interval: 30
EOF
        
        log_info "已更新域名配置"
    fi
    
    # 更新服务器配置
    if [[ -n "$server_ip" ]]; then
        local server_config_file="$ACME_DIR/config/servers.yml"
        
        cat > "$server_config_file" << EOF
# SSL证书服务器配置文件
servers:
  - server_id: custom_server
    host: $server_ip
    port: 22
    user: $ssh_user
    ssh_key_path: ~/.ssh/id_rsa
    ssl_cert_dir: $ssl_dir
    nginx_container: higgses-nginx
    nginx_reload_cmd: docker restart higgses-nginx
    backup_dir: $ssl_dir/backups
    connection_timeout: 10
    max_retry: 3
    description: "自动配置的服务器"
    environment: production

global:
  ssh:
    ssh_options:
      - "-o ConnectTimeout=10"
      - "-o BatchMode=yes"
      - "-o StrictHostKeyChecking=accept-new"
    scp_options:
      - "-q"
      - "-o ConnectTimeout=10"
      - "-o BatchMode=yes"
      - "-o StrictHostKeyChecking=accept-new"
  cert_permissions:
    key_file: "600"
    cert_file: "644"
    directory: "755"
  failure_handling:
    auto_restore_backup: true
    send_failure_notification: true
    retry_interval: 60
    max_global_retry: 5
EOF
        
        log_info "已更新服务器配置"
    fi
    
    log_success "配置文件更新完成"
}

# 设置文件权限
set_permissions() {
    log_info "设置文件权限..."
    
    # 设置脚本执行权限
    chmod +x "$ACME_DIR/scripts"/*.sh
    chmod +x "$ACME_DIR/scripts/utils"/*.sh
    
    # 设置配置文件权限
    chmod 600 "$ACME_DIR/config/dns-providers.yml"
    chmod 644 "$ACME_DIR/config/domains.yml"
    chmod 644 "$ACME_DIR/config/servers.yml"
    
    # 设置数据目录权限
    chmod 755 "$ACME_DIR/data"
    chmod 755 "$ACME_DIR/data/certs"
    chmod 755 "$ACME_DIR/data/logs"
    chmod 755 "$ACME_DIR/data/backups"
    
    log_success "文件权限设置完成"
}

# 构建Docker镜像
build_docker_image() {
    log_info "构建Docker镜像..."
    
    cd "$ACME_DIR"
    
    if docker build -t acme-ssl-manager:latest .; then
        log_success "Docker镜像构建成功"
    else
        log_error "Docker镜像构建失败"
        exit 1
    fi
}

# 启动服务
start_services() {
    log_info "启动SSL证书管理服务..."
    
    cd "$ACME_DIR"
    
    # 选择启动方式
    echo ""
    echo -e "${YELLOW}选择启动方式：${NC}"
    echo "1. 独立启动 (使用独立的docker-compose.yml)"
    echo "2. 集成启动 (集成到现有的production-docker-compose.yml)"
    read -p "请选择 (1 或 2): " start_choice
    
    case $start_choice in
        1)
            if docker-compose up -d; then
                log_success "服务启动成功"
            else
                log_error "服务启动失败"
                exit 1
            fi
            ;;
        2)
            cd "$PROJECT_ROOT"
            if docker-compose -f production-docker-compose.yml -f acme-integration-docker-compose.yml up -d; then
                log_success "服务启动成功"
            else
                log_error "服务启动失败"
                exit 1
            fi
            ;;
        *)
            log_warn "无效选择，跳过服务启动"
            ;;
    esac
}

# 验证安装
verify_installation() {
    log_info "验证安装..."
    
    # 等待服务启动
    sleep 10
    
    # 检查容器状态
    if docker ps | grep -q "acme-ssl-manager"; then
        log_success "SSL证书管理容器运行正常"
    else
        log_error "SSL证书管理容器未正常运行"
        return 1
    fi
    
    # 检查健康状态
    if docker exec higgses-acme-ssl-manager /scripts/cert-manager.sh health-check &>/dev/null; then
        log_success "系统健康检查通过"
    else
        log_warn "系统健康检查未通过，请检查配置"
    fi
    
    log_success "安装验证完成"
}

# 显示安装结果
show_installation_result() {
    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}     SSL证书管理系统安装完成！${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo ""
    echo -e "${BLUE}系统信息：${NC}"
    echo "- 服务名称: higgses-acme-ssl-manager"
    echo "- Web界面: http://localhost:8089 (如果启用)"
    echo "- 健康检查: http://localhost:8088/health"
    echo ""
    echo -e "${BLUE}常用命令：${NC}"
    echo "# 查看服务状态"
    echo "docker ps | grep acme"
    echo ""
    echo "# 查看日志"
    echo "docker logs higgses-acme-ssl-manager"
    echo ""
    echo "# 生成证书"
    echo "docker exec higgses-acme-ssl-manager /scripts/cert-manager.sh generate $domain"
    echo ""
    echo "# 部署证书"
    echo "docker exec higgses-acme-ssl-manager /scripts/cert-manager.sh deploy-all"
    echo ""
    echo "# 监控证书"
    echo "docker exec higgses-acme-ssl-manager /scripts/cert-manager.sh monitor"
    echo ""
    echo -e "${BLUE}配置文件位置：${NC}"
    echo "- 域名配置: $ACME_DIR/config/domains.yml"
    echo "- 服务器配置: $ACME_DIR/config/servers.yml"
    echo "- DNS配置: $ACME_DIR/config/dns-providers.yml"
    echo ""
    echo -e "${BLUE}文档：${NC}"
    echo "- 快速开始: $ACME_DIR/QUICK_START.md"
    echo "- 详细文档: $ACME_DIR/README.md"
    echo ""
    echo -e "${YELLOW}下一步：${NC}"
    echo "1. 检查和完善配置文件"
    echo "2. 测试证书生成和部署"
    echo "3. 设置监控和通知"
    echo ""
    echo -e "${GREEN}感谢使用SSL证书管理系统！${NC}"
}

# 主函数
main() {
    show_welcome
    
    # 检查是否以root权限运行
    if [[ $EUID -ne 0 ]]; then
        log_warn "建议以root权限运行此脚本"
        read -p "是否继续？(y/n): " continue_choice
        if [[ $continue_choice != "y" ]]; then
            exit 0
        fi
    fi
    
    # 询问是否进行交互式配置
    read -p "是否进行交互式配置？(y/n): " config_choice
    
    # 执行安装步骤
    check_requirements
    create_directories
    copy_config_files
    
    if [[ $config_choice == "y" ]]; then
        interactive_config
    fi
    
    set_permissions
    build_docker_image
    start_services
    verify_installation
    show_installation_result
    
    log_success "安装完成！"
}

# 脚本入口
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi 
