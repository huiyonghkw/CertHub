#!/bin/bash
#
# SSL证书管理系统 Web服务器启动脚本
# 同时启动Web界面和API服务器
#

set -e

# 设置颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# 日志函数
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# 检查环境
check_environment() {
    log_info "检查运行环境..."
    
    # 检查Python
    if ! command -v python3 &> /dev/null; then
        log_error "Python3 未找到"
        exit 1
    fi
    
    # 检查Python包
    if ! python3 -c "import flask, flask_cors, yaml" &> /dev/null; then
        log_error "Python依赖包缺失"
        exit 1
    fi
    
    log_info "环境检查通过"
}

# 创建必要的目录
create_directories() {
    log_info "创建必要的目录..."
    
    mkdir -p /data/logs
    mkdir -p /data/certs
    mkdir -p /config
    
    # 设置权限
    chmod 755 /data/logs
    chmod 755 /data/certs
    chmod 755 /config
    
    log_info "目录创建完成"
}

# 配置Web服务器
configure_web_server() {
    log_info "配置Web服务器..."
    
    # 创建简单的Web服务器
    cat > /tmp/web_server.py << 'EOF'
#!/usr/bin/env python3
import os
import mimetypes
import requests
from flask import Flask, send_from_directory, request, jsonify, Response
from werkzeug.exceptions import NotFound

app = Flask(__name__)

# 静态文件目录
STATIC_DIR = "/web"
API_BASE_URL = "http://127.0.0.1:5000"

@app.route('/')
def index():
    return send_from_directory(STATIC_DIR, 'index.html')

@app.route('/health')
def health():
    """代理健康检查到API服务器"""
    try:
        response = requests.get(f"{API_BASE_URL}/health", timeout=5)
        return Response(response.content, 
                       status=response.status_code,
                       content_type=response.headers.get('content-type', 'application/json'))
    except:
        return jsonify({'error': 'API服务器不可用'}), 503

@app.route('/api/<path:path>', methods=['GET', 'POST', 'PUT', 'DELETE'])
def api_proxy(path):
    """代理API请求到API服务器"""
    try:
        url = f"{API_BASE_URL}/api/{path}"
        method = request.method
        
        if method == 'GET':
            response = requests.get(url, params=request.args, timeout=30)
        elif method == 'POST':
            response = requests.post(url, json=request.get_json(), timeout=30)
        elif method == 'PUT':
            response = requests.put(url, json=request.get_json(), timeout=30)
        elif method == 'DELETE':
            response = requests.delete(url, timeout=30)
        else:
            return jsonify({'error': 'Method not allowed'}), 405
        
        return Response(response.content, 
                       status=response.status_code,
                       content_type=response.headers.get('content-type', 'application/json'))
    except requests.exceptions.RequestException as e:
        return jsonify({'error': f'API请求失败: {str(e)}'}), 503

@app.route('/<path:filename>')
def static_files(filename):
    try:
        return send_from_directory(STATIC_DIR, filename)
    except NotFound:
        # 对于SPA，返回index.html
        return send_from_directory(STATIC_DIR, 'index.html')

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=80, debug=False)
EOF
    
    chmod +x /tmp/web_server.py
    log_info "Web服务器配置成功"
}

# 启动API服务器
start_api_server() {
    log_info "启动API服务器..."
    
    cd /web
    
    # 启动Flask应用
    python3 api_server.py &
    API_PID=$!
    
    # 等待API服务器启动
    sleep 5
    
    # 检查API服务器是否启动成功
    if curl -f -s http://127.0.0.1:5000/health > /dev/null; then
        log_info "API服务器启动成功 (PID: $API_PID)"
        echo $API_PID > /var/run/api_server.pid
    else
        log_error "API服务器启动失败"
        exit 1
    fi
}

# 启动Web服务器
start_web_server() {
    log_info "启动Web服务器..."
    
    # 启动Web服务器
    python3 /tmp/web_server.py &
    WEB_PID=$!
    
    # 等待Web服务器启动
    sleep 3
    
    # 检查Web服务器是否启动成功
    if kill -0 $WEB_PID 2>/dev/null; then
        log_info "Web服务器启动成功 (PID: $WEB_PID)"
        echo $WEB_PID > /var/run/web_server.pid
    else
        log_error "Web服务器启动失败"
        exit 1
    fi
}

# 停止服务
stop_services() {
    log_info "停止服务..."
    
    # 停止API服务器
    if [[ -f /var/run/api_server.pid ]]; then
        API_PID=$(cat /var/run/api_server.pid)
        if kill -0 $API_PID 2>/dev/null; then
            kill $API_PID
            log_info "API服务器已停止"
        fi
        rm -f /var/run/api_server.pid
    fi
    
    # 停止Web服务器
    if [[ -f /var/run/web_server.pid ]]; then
        WEB_PID=$(cat /var/run/web_server.pid)
        if kill -0 $WEB_PID 2>/dev/null; then
            kill $WEB_PID
            log_info "Web服务器已停止"
        fi
        rm -f /var/run/web_server.pid
    fi
}

# 信号处理
trap stop_services SIGTERM SIGINT

# 显示状态
show_status() {
    log_info "SSL证书管理系统状态:"
    echo ""
    echo "🌐 Web界面: http://localhost:8080"
    echo "🔌 API服务器: http://localhost:5000"
    echo "❤️  健康检查: http://localhost:8080/health"
    echo ""
    echo "📁 数据目录: /data"
    echo "⚙️  配置目录: /config"
    echo "📄 日志目录: /data/logs"
    echo "🔐 证书目录: /data/certs"
    echo ""
    echo "按 Ctrl+C 停止服务"
}

# 主函数
main() {
    log_info "启动SSL证书管理系统Web服务器..."
    
    # 检查环境
    check_environment
    
    # 创建目录
    create_directories
    
    # 配置Web服务器
    configure_web_server
    
    # 启动API服务器
    start_api_server
    
    # 启动Web服务器
    start_web_server
    
    # 显示状态
    show_status
    
    # 保持运行
    while true; do
        # 检查API服务器
        if ! curl -f -s http://127.0.0.1:5000/health > /dev/null; then
            log_error "API服务器已停止，正在重启..."
            start_api_server
        fi
        
        # 检查Web服务器
        if [[ -f /var/run/web_server.pid ]]; then
            WEB_PID=$(cat /var/run/web_server.pid)
            if ! kill -0 $WEB_PID 2>/dev/null; then
                log_error "Web服务器已停止，正在重启..."
                start_web_server
            fi
        else
            log_error "Web服务器PID文件不存在，正在重启..."
            start_web_server
        fi
        
        sleep 30
    done
}

# 执行主函数
main "$@" 
