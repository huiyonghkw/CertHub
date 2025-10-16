#!/bin/bash

# 通知工具脚本
# 支持多种通知方式：邮件、钉钉、Webhook等
# 版本：1.0.0

# 导入日志工具
UTILS_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${UTILS_SCRIPT_DIR}/logger.sh"

# 配置文件路径
CONFIG_DIR="${CONFIG_DIR:-/config}"
NOTIFY_CONFIG="${CONFIG_DIR}/notify.yml"

# 默认通知配置
DEFAULT_NOTIFY_ENABLED=true
DEFAULT_NOTIFY_METHODS=("log")

# 发送通知主函数
send_notification() {
    local title="$1"
    local message="$2"
    local level="${3:-info}"
    local force="${4:-false}"
    
    # 检查通知是否启用
    if ! is_notification_enabled && [[ "$force" != "true" ]]; then
        log_debug "通知功能未启用，跳过发送"
        return 0
    fi
    
    log_info "发送通知: $title"
    
    # 获取启用的通知方式
    local notify_methods
    notify_methods=$(get_notify_methods)
    
    # 遍历通知方式
    while IFS= read -r method; do
        if [[ -n "$method" ]]; then
            case "$method" in
                "email")
                    send_email_notification "$title" "$message" "$level"
                    ;;
                "dingtalk")
                    send_dingtalk_notification "$title" "$message" "$level"
                    ;;
                "webhook")
                    send_webhook_notification "$title" "$message" "$level"
                    ;;
                "slack")
                    send_slack_notification "$title" "$message" "$level"
                    ;;
                "sms")
                    send_sms_notification "$title" "$message" "$level"
                    ;;
                "log")
                    log_notification "$title" "$message" "$level"
                    ;;
                *)
                    log_warn "不支持的通知方式: $method"
                    ;;
            esac
        fi
    done <<< "$notify_methods"
}

# 检查通知是否启用
is_notification_enabled() {
    if [[ -f "$NOTIFY_CONFIG" ]]; then
        local enabled
        enabled=$(yq eval '.global.enabled' "$NOTIFY_CONFIG" 2>/dev/null)
        [[ "$enabled" == "true" ]]
    else
        [[ "$DEFAULT_NOTIFY_ENABLED" == "true" ]]
    fi
}

# 获取通知方式列表
get_notify_methods() {
    if [[ -f "$NOTIFY_CONFIG" ]]; then
        yq eval '.global.methods[]' "$NOTIFY_CONFIG" 2>/dev/null
    else
        printf '%s\n' "${DEFAULT_NOTIFY_METHODS[@]}"
    fi
}

# 获取通知配置
get_notify_config() {
    local method="$1"
    if [[ -f "$NOTIFY_CONFIG" ]]; then
        yq eval ".methods.$method" "$NOTIFY_CONFIG" 2>/dev/null
    else
        echo "{}"
    fi
}

# 日志通知（默认方式）
log_notification() {
    local title="$1"
    local message="$2"
    local level="$3"
    
    case "$level" in
        "error")
            log_error "通知: $title - $message"
            ;;
        "warn")
            log_warn "通知: $title - $message"
            ;;
        "success")
            log_success "通知: $title - $message"
            ;;
        *)
            log_info "通知: $title - $message"
            ;;
    esac
}

# 邮件通知
send_email_notification() {
    local title="$1"
    local message="$2"
    local level="$3"
    
    local email_config
    email_config=$(get_notify_config "email")
    
    if [[ "$email_config" == "{}" ]]; then
        log_warn "邮件通知配置不存在，跳过发送"
        return 1
    fi
    
    # 解析邮件配置
    local smtp_host smtp_port smtp_user smtp_pass from_email to_emails
    smtp_host=$(echo "$email_config" | yq eval '.smtp.host' -)
    smtp_port=$(echo "$email_config" | yq eval '.smtp.port' -)
    smtp_user=$(echo "$email_config" | yq eval '.smtp.user' -)
    smtp_pass=$(echo "$email_config" | yq eval '.smtp.password' -)
    from_email=$(echo "$email_config" | yq eval '.from' -)
    to_emails=$(echo "$email_config" | yq eval '.to[]' -)
    
    # 构建邮件内容
    local email_subject="[SSL证书管理] $title"
    local email_body="$message

时间: $(date '+%Y-%m-%d %H:%M:%S')
级别: $level
主机: $(hostname)

---
此邮件由SSL证书管理系统自动发送"
    
    # 发送邮件
    while IFS= read -r to_email; do
        if [[ -n "$to_email" ]]; then
            send_email_via_smtp "$smtp_host" "$smtp_port" "$smtp_user" "$smtp_pass" \
                               "$from_email" "$to_email" "$email_subject" "$email_body"
        fi
    done <<< "$to_emails"
}

# 通过SMTP发送邮件
send_email_via_smtp() {
    local smtp_host="$1"
    local smtp_port="$2"
    local smtp_user="$3"
    local smtp_pass="$4"
    local from_email="$5"
    local to_email="$6"
    local subject="$7"
    local body="$8"
    
    # 使用Python发送邮件
    python3 << EOF
import smtplib
from email.mime.text import MIMEText
from email.mime.multipart import MIMEMultipart
import sys

try:
    # 创建邮件对象
    msg = MIMEMultipart()
    msg['From'] = '$from_email'
    msg['To'] = '$to_email'
    msg['Subject'] = '$subject'
    
    # 添加邮件正文
    msg.attach(MIMEText('$body', 'plain', 'utf-8'))
    
    # 连接SMTP服务器
    server = smtplib.SMTP('$smtp_host', $smtp_port)
    server.starttls()
    server.login('$smtp_user', '$smtp_pass')
    
    # 发送邮件
    server.send_message(msg)
    server.quit()
    
    print("邮件发送成功: $to_email")
    
except Exception as e:
    print(f"邮件发送失败: {e}")
    sys.exit(1)
EOF
    
    local result=$?
    if [[ $result -eq 0 ]]; then
        log_info "邮件发送成功: $to_email"
    else
        log_error "邮件发送失败: $to_email"
    fi
    
    return $result
}

# 钉钉通知
send_dingtalk_notification() {
    local title="$1"
    local message="$2"
    local level="$3"
    
    local dingtalk_config
    dingtalk_config=$(get_notify_config "dingtalk")
    
    if [[ "$dingtalk_config" == "{}" ]]; then
        log_warn "钉钉通知配置不存在，跳过发送"
        return 1
    fi
    
    # 解析钉钉配置
    local webhook_url access_token secret
    webhook_url=$(echo "$dingtalk_config" | yq eval '.webhook_url' -)
    access_token=$(echo "$dingtalk_config" | yq eval '.access_token' -)
    secret=$(echo "$dingtalk_config" | yq eval '.secret' -)
    
    # 构建钉钉消息
    local timestamp
    timestamp=$(date +%s)000
    
    local sign=""
    if [[ -n "$secret" ]]; then
        sign=$(echo -n "${timestamp}\n${secret}" | openssl dgst -sha256 -hmac "$secret" -binary | base64)
    fi
    
    # 根据级别设置颜色
    local color
    case "$level" in
        "error")
            color="red"
            ;;
        "warn")
            color="orange"
            ;;
        "success")
            color="green"
            ;;
        *)
            color="blue"
            ;;
    esac
    
    # 构建请求URL
    local url="$webhook_url"
    if [[ -n "$access_token" ]]; then
        url="${url}?access_token=${access_token}"
    fi
    if [[ -n "$sign" ]]; then
        url="${url}&timestamp=${timestamp}&sign=${sign}"
    fi
    
    # 构建消息内容
    local json_data
    json_data=$(cat << EOF
{
    "msgtype": "markdown",
    "markdown": {
        "title": "$title",
        "text": "## $title\n\n$message\n\n**时间:** $(date '+%Y-%m-%d %H:%M:%S')\n\n**级别:** $level\n\n**主机:** $(hostname)"
    }
}
EOF
)
    
    # 发送钉钉消息
    local response
    response=$(curl -s -X POST "$url" \
        -H "Content-Type: application/json" \
        -d "$json_data")
    
    if [[ $? -eq 0 ]]; then
        local errcode
        errcode=$(echo "$response" | jq -r '.errcode' 2>/dev/null)
        if [[ "$errcode" == "0" ]]; then
            log_info "钉钉通知发送成功"
        else
            log_error "钉钉通知发送失败: $response"
        fi
    else
        log_error "钉钉通知发送失败: 网络错误"
    fi
}

# Webhook通知
send_webhook_notification() {
    local title="$1"
    local message="$2"
    local level="$3"
    
    local webhook_config
    webhook_config=$(get_notify_config "webhook")
    
    if [[ "$webhook_config" == "{}" ]]; then
        log_warn "Webhook通知配置不存在，跳过发送"
        return 1
    fi
    
    # 解析Webhook配置
    local webhook_url method headers
    webhook_url=$(echo "$webhook_config" | yq eval '.url' -)
    method=$(echo "$webhook_config" | yq eval '.method' -)
    headers=$(echo "$webhook_config" | yq eval '.headers' -)
    
    # 默认方法为POST
    method="${method:-POST}"
    
    # 构建请求数据
    local json_data
    json_data=$(cat << EOF
{
    "title": "$title",
    "message": "$message",
    "level": "$level",
    "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
    "hostname": "$(hostname)",
    "service": "ssl-cert-manager"
}
EOF
)
    
    # 构建curl命令
    local curl_cmd="curl -s -X $method"
    
    # 添加请求头
    if [[ "$headers" != "null" ]]; then
        while IFS= read -r header; do
            if [[ -n "$header" ]]; then
                curl_cmd="$curl_cmd -H '$header'"
            fi
        done < <(echo "$headers" | yq eval 'to_entries | .[] | .key + ": " + .value' -)
    fi
    
    # 添加Content-Type
    curl_cmd="$curl_cmd -H 'Content-Type: application/json'"
    
    # 添加数据和URL
    curl_cmd="$curl_cmd -d '$json_data' '$webhook_url'"
    
    # 发送请求
    local response
    response=$(eval "$curl_cmd")
    
    if [[ $? -eq 0 ]]; then
        log_info "Webhook通知发送成功: $webhook_url"
    else
        log_error "Webhook通知发送失败: $webhook_url"
    fi
}

# Slack通知
send_slack_notification() {
    local title="$1"
    local message="$2"
    local level="$3"
    
    local slack_config
    slack_config=$(get_notify_config "slack")
    
    if [[ "$slack_config" == "{}" ]]; then
        log_warn "Slack通知配置不存在，跳过发送"
        return 1
    fi
    
    # 解析Slack配置
    local webhook_url channel username
    webhook_url=$(echo "$slack_config" | yq eval '.webhook_url' -)
    channel=$(echo "$slack_config" | yq eval '.channel' -)
    username=$(echo "$slack_config" | yq eval '.username' -)
    
    # 根据级别设置颜色
    local color
    case "$level" in
        "error")
            color="danger"
            ;;
        "warn")
            color="warning"
            ;;
        "success")
            color="good"
            ;;
        *)
            color="#36a64f"
            ;;
    esac
    
    # 构建Slack消息
    local json_data
    json_data=$(cat << EOF
{
    "channel": "$channel",
    "username": "$username",
    "attachments": [
        {
            "color": "$color",
            "title": "$title",
            "text": "$message",
            "fields": [
                {
                    "title": "时间",
                    "value": "$(date '+%Y-%m-%d %H:%M:%S')",
                    "short": true
                },
                {
                    "title": "级别",
                    "value": "$level",
                    "short": true
                },
                {
                    "title": "主机",
                    "value": "$(hostname)",
                    "short": true
                }
            ]
        }
    ]
}
EOF
)
    
    # 发送Slack消息
    local response
    response=$(curl -s -X POST "$webhook_url" \
        -H "Content-Type: application/json" \
        -d "$json_data")
    
    if [[ $? -eq 0 ]]; then
        if [[ "$response" == "ok" ]]; then
            log_info "Slack通知发送成功"
        else
            log_error "Slack通知发送失败: $response"
        fi
    else
        log_error "Slack通知发送失败: 网络错误"
    fi
}

# SMS通知
send_sms_notification() {
    local title="$1"
    local message="$2"
    local level="$3"
    
    local sms_config
    sms_config=$(get_notify_config "sms")
    
    if [[ "$sms_config" == "{}" ]]; then
        log_warn "SMS通知配置不存在，跳过发送"
        return 1
    fi
    
    # 解析SMS配置
    local provider api_key api_secret phone_numbers
    provider=$(echo "$sms_config" | yq eval '.provider' -)
    api_key=$(echo "$sms_config" | yq eval '.api_key' -)
    api_secret=$(echo "$sms_config" | yq eval '.api_secret' -)
    phone_numbers=$(echo "$sms_config" | yq eval '.phone_numbers[]' -)
    
    # 构建SMS内容
    local sms_content="[SSL证书管理] $title - $message"
    
    # 根据提供商发送SMS
    case "$provider" in
        "aliyun")
            send_aliyun_sms "$api_key" "$api_secret" "$phone_numbers" "$sms_content"
            ;;
        "tencent")
            send_tencent_sms "$api_key" "$api_secret" "$phone_numbers" "$sms_content"
            ;;
        *)
            log_warn "不支持的SMS提供商: $provider"
            ;;
    esac
}

# 发送阿里云短信
send_aliyun_sms() {
    local api_key="$1"
    local api_secret="$2"
    local phone_numbers="$3"
    local content="$4"
    
    log_info "发送阿里云短信通知"
    # 这里可以集成阿里云SMS SDK
    # 由于复杂性，这里只是示例
    log_warn "阿里云短信功能需要进一步集成SDK"
}

# 测试通知功能
test_notification() {
    local method="${1:-all}"
    
    log_info "测试通知功能: $method"
    
    local test_title="SSL证书管理系统测试"
    local test_message="这是一条测试通知消息，用于验证通知功能是否正常工作。"
    
    if [[ "$method" == "all" ]]; then
        send_notification "$test_title" "$test_message" "info" "true"
    else
        case "$method" in
            "email")
                send_email_notification "$test_title" "$test_message" "info"
                ;;
            "dingtalk")
                send_dingtalk_notification "$test_title" "$test_message" "info"
                ;;
            "webhook")
                send_webhook_notification "$test_title" "$test_message" "info"
                ;;
            "slack")
                send_slack_notification "$test_title" "$test_message" "info"
                ;;
            "sms")
                send_sms_notification "$test_title" "$test_message" "info"
                ;;
            *)
                log_error "不支持的通知方式: $method"
                ;;
        esac
    fi
}

# 如果作为独立脚本运行，提供命令行接口
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    case "${1:-}" in
        "send")
            send_notification "$2" "$3" "${4:-info}" "${5:-false}"
            ;;
        "test")
            test_notification "${2:-all}"
            ;;
        *)
            cat << EOF
通知工具使用说明:

用法: $0 [命令] [参数]

命令:
    send <标题> <消息> [级别] [强制]     发送通知
    test [方式]                         测试通知功能

参数:
    标题: 通知标题
    消息: 通知内容
    级别: info|warn|error|success
    强制: true|false (忽略通知开关)
    方式: all|email|dingtalk|webhook|slack|sms

示例:
    $0 send "证书过期提醒" "域名example.com的证书将在7天后过期" "warn"
    $0 test dingtalk
    $0 test all
EOF
            ;;
    esac
fi 
