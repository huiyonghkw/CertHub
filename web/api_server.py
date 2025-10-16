#!/usr/bin/env python3
"""
SSL证书管理系统 API服务器
提供Web界面的后端API服务
"""

import os
import json
import subprocess
import yaml
import logging
from datetime import datetime, timedelta
from flask import Flask, request, jsonify, send_file
from flask_cors import CORS
import tempfile
import zipfile
import glob
from pathlib import Path

# 配置日志
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s',
    handlers=[
        logging.FileHandler('/data/logs/api_server.log'),
        logging.StreamHandler()
    ]
)
logger = logging.getLogger(__name__)

# 创建Flask应用
app = Flask(__name__)
CORS(app)  # 启用跨域请求

# 配置路径
BASE_DIR = "/config"
DATA_DIR = "/data"
SCRIPTS_DIR = "/scripts"
LOG_DIR = "/data/logs"
CERT_DIR = "/data/certs"

# 配置文件路径
DOMAINS_CONFIG = os.path.join(BASE_DIR, "domains.yml")
DNS_CONFIG = os.path.join(BASE_DIR, "dns-providers.yml")
SERVERS_CONFIG = os.path.join(BASE_DIR, "servers.yml")
NOTIFY_CONFIG = os.path.join(BASE_DIR, "notify.yml")

class CertificateManager:
    """证书管理器类"""
    
    def __init__(self):
        self.cert_script = os.path.join(SCRIPTS_DIR, "cert-manager.sh")
        self.simple_script = os.path.join(SCRIPTS_DIR, "cert-manager-simple.sh")
    
    def run_command(self, cmd, timeout=300):
        """执行shell命令"""
        try:
            logger.info(f"执行命令: {cmd}")
            result = subprocess.run(
                cmd,
                shell=True,
                capture_output=True,
                text=True,
                timeout=timeout
            )
            return {
                'success': result.returncode == 0,
                'stdout': result.stdout,
                'stderr': result.stderr,
                'returncode': result.returncode
            }
        except subprocess.TimeoutExpired:
            return {
                'success': False,
                'error': 'Command timeout',
                'stdout': '',
                'stderr': 'Command execution timeout'
            }
        except Exception as e:
            return {
                'success': False,
                'error': str(e),
                'stdout': '',
                'stderr': str(e)
            }
    
    def get_certificates(self):
        """获取所有证书信息"""
        certificates = []
        
        # 读取域名配置
        domains_config = self._load_domains_config()
        if not domains_config:
            return []
        
        for domain_config in domains_config:
            domain = domain_config['domain']
            cert_info = self._get_certificate_info(domain)
            
            # 添加自定义配置信息
            cert_info['custom_configs'] = {}
            
            # 检查是否有子域名的自定义配置
            subdomains = domain_config.get('subdomains', [])
            for subdomain in subdomains:
                if isinstance(subdomain, dict) and subdomain.get('domain'):
                    subdomain_name = subdomain['domain']
                    cert_info['custom_configs'][subdomain_name] = {
                        'deploy_dir': subdomain.get('deploy_dir', ''),
                        'cert_filename': subdomain.get('cert_filename', ''),
                        'key_filename': subdomain.get('key_filename', ''),
                        'deploy_method': subdomain.get('deploy_method', 'auto')
                    }
                    
            certificates.append(cert_info)
        
        return certificates

    def _load_domains_config(self):
        """加载域名配置文件"""
        config_file = os.path.join(BASE_DIR, 'domains.yml')
        if not os.path.exists(config_file):
            return None
            
        try:
            with open(config_file, 'r', encoding='utf-8') as f:
                config = yaml.safe_load(f)
                return config.get('domains', [])
        except Exception as e:
            logger.error(f"Failed to load domains config: {e}")
            return None
    
    def _get_certificate_info(self, domain):
        """获取单个域名的证书信息"""
        # 尝试不同的证书文件路径
        # 优先查找实际证书文件（通常在不带星号的目录）
        cert_patterns = [
            # 优先：普通域名 ECC证书（acme.sh 实际存储证书的位置）
            os.path.join(CERT_DIR, f"{domain}_ecc", "fullchain.cer"),
            os.path.join(CERT_DIR, f"{domain}_ecc", f"{domain}.cer"),
            # 优先：普通域名 RSA证书
            os.path.join(CERT_DIR, f"{domain}", "fullchain.cer"),
            os.path.join(CERT_DIR, f"{domain}", f"{domain}.cer"),
            # 备用：泛域名 ECC证书目录（可能是符号链接）
            os.path.join(CERT_DIR, f"*.{domain}_ecc", "fullchain.cer"),
            os.path.join(CERT_DIR, f"*.{domain}_ecc", f"*.{domain}.cer"),
            # 备用：泛域名 RSA证书目录
            os.path.join(CERT_DIR, f"*.{domain}", "fullchain.cer"),
            os.path.join(CERT_DIR, f"*.{domain}", f"*.{domain}.cer")
        ]

        cert_file = None
        for pattern in cert_patterns:
            matches = glob.glob(pattern)
            if matches:
                cert_file = matches[0]  # 使用第一个匹配的文件
                break

        if not cert_file:
            return {
                'domain': domain,
                'status': 'not_found',
                'error': '证书文件不存在',
                'type': 'single',
                'expiryDate': 'undefined',
                'daysRemaining': 'undefined',
                'algorithm': 'undefined'
            }
        
        # 获取证书信息
        cmd = f"openssl x509 -in '{cert_file}' -noout -enddate -subject -issuer"
        result = self.run_command(cmd)
        
        if not result['success']:
            return {
                'domain': domain,
                'status': 'error',
                'error': '无法读取证书信息',
                'type': 'single',
                'expiryDate': 'undefined',
                'daysRemaining': 'undefined',
                'algorithm': 'undefined'
            }
        
        # 解析证书信息
        lines = result['stdout'].strip().split('\n')
        # 从证书文件路径判断类型和算法
        is_wildcard = ('*.' in cert_file) or ('wildcard' in cert_file.lower())
        cert_info = {
            'domain': domain,
            'type': 'wildcard' if is_wildcard else 'single',
            'algorithm': 'ECC' if '_ecc' in cert_file else 'RSA',
            'expiryDate': 'undefined',
            'daysRemaining': 'undefined',
            'status': 'unknown'
        }
        
        for line in lines:
            if line.startswith('notAfter='):
                expiry_str = line.split('=', 1)[1]
                # 解析过期时间
                try:
                    expiry_date = datetime.strptime(expiry_str, '%b %d %H:%M:%S %Y %Z')
                    cert_info['expiryDate'] = expiry_date.strftime('%Y-%m-%d')
                    
                    # 计算剩余天数
                    days_remaining = (expiry_date - datetime.now()).days
                    cert_info['daysRemaining'] = days_remaining
                    
                    # 确定状态
                    if days_remaining <= 0:
                        cert_info['status'] = 'expired'
                    elif days_remaining <= 30:
                        cert_info['status'] = 'warning'
                    else:
                        cert_info['status'] = 'healthy'
                        
                except ValueError:
                    cert_info['expiryDate'] = expiry_str
                    cert_info['daysRemaining'] = 'unknown'
                    cert_info['status'] = 'unknown'
                break
        
        return cert_info
    
    def generate_certificate(self, domain, cert_type, dns_provider):
        """生成证书"""
        try:
            # 构建命令
            if cert_type == 'wildcard':
                domain_arg = f"*.{domain}"
            else:
                domain_arg = domain
            
            cmd = f"{self.cert_script} generate '{domain_arg}'"
            
            # 设置DNS提供商环境变量
            env_vars = self._get_dns_env_vars(dns_provider)
            if env_vars:
                env_cmd = ' '.join([f"export {k}='{v}'" for k, v in env_vars.items()])
                cmd = f"{env_cmd} && {cmd}"
            
            result = self.run_command(cmd, timeout=600)  # 10分钟超时
            
            if result['success']:
                logger.info(f"证书生成成功: {domain}")
                return {'success': True, 'message': '证书生成成功'}
            else:
                logger.error(f"证书生成失败: {domain}, 错误: {result['stderr']}")
                return {'success': False, 'message': result['stderr']}
                
        except Exception as e:
            logger.error(f"生成证书异常: {e}")
            return {'success': False, 'message': str(e)}
    
    def renew_certificate(self, domain):
        """续期证书"""
        try:
            cmd = f"{self.cert_script} renew '{domain}'"
            result = self.run_command(cmd, timeout=600)
            
            if result['success']:
                logger.info(f"证书续期成功: {domain}")
                return {'success': True, 'message': '证书续期成功'}
            else:
                logger.error(f"证书续期失败: {domain}, 错误: {result['stderr']}")
                return {'success': False, 'message': result['stderr']}
                
        except Exception as e:
            logger.error(f"续期证书异常: {e}")
            return {'success': False, 'message': str(e)}
    
    def delete_certificate(self, domain):
        """删除证书"""
        try:
            # 删除证书文件 - 支持泛域名目录
            cert_patterns = [
                # 优先：普通域名目录（acme.sh 实际存储证书的位置）
                os.path.join(CERT_DIR, f"{domain}_ecc"),
                os.path.join(CERT_DIR, domain),
                # 备用：泛域名目录（可能是符号链接或占位目录）
                os.path.join(CERT_DIR, f"*.{domain}_ecc"),
                os.path.join(CERT_DIR, f"*.{domain}")
            ]

            deleted = False
            for pattern in cert_patterns:
                matches = glob.glob(pattern)
                for cert_dir in matches:
                    if os.path.exists(cert_dir) and os.path.isdir(cert_dir):
                        import shutil
                        shutil.rmtree(cert_dir)
                        deleted = True
                        logger.info(f"删除证书目录: {cert_dir}")

            if deleted:
                return {'success': True, 'message': '证书删除成功'}
            else:
                return {'success': False, 'message': '证书文件不存在'}

        except Exception as e:
            logger.error(f"删除证书异常: {e}")
            return {'success': False, 'message': str(e)}
    
    def download_certificate(self, domain):
        """下载证书"""
        try:
            # 查找证书目录 - 支持泛域名目录
            cert_patterns = [
                # 优先：普通域名目录（acme.sh 实际存储证书的位置）
                os.path.join(CERT_DIR, f"{domain}_ecc"),
                os.path.join(CERT_DIR, domain),
                # 备用：泛域名目录（可能是符号链接或占位目录）
                os.path.join(CERT_DIR, f"*.{domain}_ecc"),
                os.path.join(CERT_DIR, f"*.{domain}")
            ]

            cert_dir = None
            for pattern in cert_patterns:
                matches = glob.glob(pattern)
                if matches:
                    cert_dir = matches[0]  # 使用第一个匹配的目录
                    break

            if not cert_dir:
                return None

            # 创建临时zip文件
            temp_file = tempfile.NamedTemporaryFile(suffix='.zip', delete=False)

            with zipfile.ZipFile(temp_file, 'w') as zipf:
                for root, dirs, files in os.walk(cert_dir):
                    for file in files:
                        file_path = os.path.join(root, file)
                        arcname = os.path.relpath(file_path, cert_dir)
                        zipf.write(file_path, arcname)

            temp_file.close()
            return temp_file.name

        except Exception as e:
            logger.error(f"下载证书异常: {e}")
            return None
    
    def _get_dns_env_vars(self, dns_provider):
        """获取DNS提供商环境变量"""
        try:
            if not os.path.exists(DNS_CONFIG):
                return {}
            
            with open(DNS_CONFIG, 'r', encoding='utf-8') as f:
                dns_data = yaml.safe_load(f)
                providers = dns_data.get('dns_providers', {})
                
                if dns_provider in providers:
                    return providers[dns_provider].get('env_vars', {})
                
        except Exception as e:
            logger.error(f"获取DNS环境变量失败: {e}")
        
        return {}
    
    def get_system_status(self):
        """获取系统状态"""
        try:
            # 运行健康检查
            cmd = f"{self.simple_script} health-check"
            result = self.run_command(cmd)
            
            status = {
                'healthy': result['success'],
                'message': result['stdout'] if result['success'] else result['stderr'],
                'timestamp': datetime.now().isoformat()
            }
            
            return status
            
        except Exception as e:
            logger.error(f"获取系统状态失败: {e}")
            return {
                'healthy': False,
                'message': str(e),
                'timestamp': datetime.now().isoformat()
            }

# 创建证书管理器实例
cert_manager = CertificateManager()

@app.route('/api/dashboard', methods=['GET'])
def get_dashboard():
    """获取仪表盘数据"""
    try:
        # 获取证书信息
        cert_result = cert_manager.get_certificates()
        
        if cert_result:
            total_certs = len(cert_result)
            healthy_certs = len([c for c in cert_result if c.get('status') == 'healthy'])
            expiring_certs = len([c for c in cert_result if c.get('status') in ['warning', 'expired']])
        else:
            total_certs = 0
            healthy_certs = 0
            expiring_certs = 0
        
        # 获取系统状态
        system_status = cert_manager.get_system_status()
        
        return jsonify({
            'totalCerts': total_certs,
            'healthyCerts': healthy_certs,
            'expiringCerts': expiring_certs,
            'systemStatus': system_status
        })
    
    except Exception as e:
        logger.error(f"获取仪表盘数据失败: {e}")
        return jsonify({'error': str(e)}), 500

@app.route('/api/certificates', methods=['GET'])
def get_certificates():
    """获取证书列表"""
    try:
        cert_manager = CertificateManager()
        certificates = cert_manager.get_certificates()
        
        return jsonify({
            'success': True,
            'certificates': certificates
        })
    except Exception as e:
        logger.error(f"获取证书列表失败: {e}")
        return jsonify({
            'success': False,
            'error': str(e)
        }), 500

@app.route('/api/certificates', methods=['POST'])
def create_certificate():
    """创建新证书"""
    try:
        data = request.get_json()
        domain = data.get('domain')
        cert_type = data.get('certType', 'single')
        dns_provider = data.get('dnsProvider', 'aliyun')
        
        if not domain:
            return jsonify({'success': False, 'message': '域名不能为空'}), 400
        
        result = cert_manager.generate_certificate(domain, cert_type, dns_provider)
        
        if result['success']:
            return jsonify(result)
        else:
            return jsonify(result), 500
            
    except Exception as e:
        logger.error(f"创建证书失败: {e}")
        return jsonify({'success': False, 'message': str(e)}), 500

@app.route('/api/certificates/<domain>/renew', methods=['POST'])
def renew_certificate(domain):
    """续期证书"""
    try:
        result = cert_manager.renew_certificate(domain)
        
        if result['success']:
            return jsonify(result)
        else:
            return jsonify(result), 500
            
    except Exception as e:
        logger.error(f"续期证书失败: {e}")
        return jsonify({'success': False, 'message': str(e)}), 500

@app.route('/api/certificates/<domain>', methods=['DELETE'])
def delete_certificate(domain):
    """删除证书"""
    try:
        result = cert_manager.delete_certificate(domain)
        
        if result['success']:
            return jsonify(result)
        else:
            return jsonify(result), 500
            
    except Exception as e:
        logger.error(f"删除证书失败: {e}")
        return jsonify({'success': False, 'message': str(e)}), 500

@app.route('/api/certificates/<domain>/download', methods=['GET'])
def download_certificate(domain):
    """下载证书"""
    try:
        zip_file = cert_manager.download_certificate(domain)
        
        if zip_file:
            return send_file(
                zip_file,
                as_attachment=True,
                download_name=f"{domain}_certificate.zip",
                mimetype='application/zip'
            )
        else:
            return jsonify({'error': '证书文件不存在'}), 404
            
    except Exception as e:
        logger.error(f"下载证书失败: {e}")
        return jsonify({'error': str(e)}), 500

@app.route('/api/logs/<log_type>', methods=['GET'])
def get_logs(log_type):
    """获取日志"""
    try:
        log_files = {
            'cert-manager': os.path.join(LOG_DIR, 'cert-manager.log'),
            'error': os.path.join(LOG_DIR, 'cert-manager-error.log'),
            'cron': os.path.join(LOG_DIR, 'cron.log')
        }
        
        log_file = log_files.get(log_type)
        if not log_file or not os.path.exists(log_file):
            return jsonify({'content': '日志文件不存在'})
        
        # 读取最后1000行日志
        cmd = f"tail -n 1000 '{log_file}'"
        result = cert_manager.run_command(cmd)
        
        if result['success']:
            return jsonify({'content': result['stdout']})
        else:
            return jsonify({'content': '读取日志失败'})
            
    except Exception as e:
        logger.error(f"获取日志失败: {e}")
        return jsonify({'content': f'获取日志失败: {str(e)}'})

@app.route('/api/logs/<log_type>', methods=['DELETE'])
def clear_logs(log_type):
    """清空日志"""
    try:
        log_files = {
            'cert-manager': os.path.join(LOG_DIR, 'cert-manager.log'),
            'error': os.path.join(LOG_DIR, 'cert-manager-error.log'),
            'cron': os.path.join(LOG_DIR, 'cron.log')
        }
        
        log_file = log_files.get(log_type)
        if not log_file:
            return jsonify({'success': False, 'message': '无效的日志类型'}), 400
        
        # 清空日志文件
        if os.path.exists(log_file):
            with open(log_file, 'w') as f:
                f.write('')
        
        return jsonify({'success': True, 'message': '日志清空成功'})
        
    except Exception as e:
        logger.error(f"清空日志失败: {e}")
        return jsonify({'success': False, 'message': str(e)}), 500

@app.route('/api/monitoring', methods=['GET'])
def get_monitoring():
    """获取监控数据"""
    try:
        # 获取系统运行时间
        uptime_result = cert_manager.run_command('uptime')
        uptime = uptime_result['stdout'].strip() if uptime_result['success'] else '未知'
        
        # 获取最后检查时间
        last_check_file = os.path.join(LOG_DIR, 'last_check.txt')
        if os.path.exists(last_check_file):
            with open(last_check_file, 'r') as f:
                last_check = f.read().strip()
        else:
            last_check = '未知'
        
        # 获取证书更新次数（模拟数据）
        cert_updates = len(glob.glob(os.path.join(CERT_DIR, '*')))
        
        return jsonify({
            'uptime': uptime,
            'lastCheck': last_check,
            'certUpdates': cert_updates,
            'charts': {}
        })
        
    except Exception as e:
        logger.error(f"获取监控数据失败: {e}")
        return jsonify({'error': str(e)}), 500

@app.route('/api/config/<config_type>', methods=['GET'])
def get_config(config_type):
    """获取配置"""
    try:
        config_files = {
            'domains': DOMAINS_CONFIG,
            'dns': DNS_CONFIG,
            'servers': SERVERS_CONFIG,
            'notification': NOTIFY_CONFIG
        }
        
        config_file = config_files.get(config_type)
        if not config_file or not os.path.exists(config_file):
            return jsonify({'content': '配置文件不存在'})
        
        with open(config_file, 'r', encoding='utf-8') as f:
            content = f.read()
        
        return jsonify({'content': content})
        
    except Exception as e:
        logger.error(f"获取配置失败: {e}")
        return jsonify({'content': f'获取配置失败: {str(e)}'})

@app.route('/api/config/<config_type>', methods=['POST'])
def save_config(config_type):
    """保存配置"""
    try:
        config_files = {
            'domains': DOMAINS_CONFIG,
            'dns': DNS_CONFIG,
            'servers': SERVERS_CONFIG,
            'notification': NOTIFY_CONFIG
        }
        
        config_file = config_files.get(config_type)
        if not config_file:
            return jsonify({'success': False, 'message': '无效的配置类型'}), 400
        
        data = request.get_json()
        content = data.get('content', '')
        
        # 验证YAML格式
        try:
            yaml.safe_load(content)
        except yaml.YAMLError as e:
            return jsonify({'success': False, 'message': f'YAML格式错误: {str(e)}'}), 400
        
        # 备份原文件
        if os.path.exists(config_file):
            backup_file = f"{config_file}.backup.{datetime.now().strftime('%Y%m%d%H%M%S')}"
            import shutil
            shutil.copy2(config_file, backup_file)
        
        # 保存新配置
        with open(config_file, 'w', encoding='utf-8') as f:
            f.write(content)
        
        return jsonify({'success': True, 'message': '配置保存成功'})
        
    except Exception as e:
        logger.error(f"保存配置失败: {e}")
        return jsonify({'success': False, 'message': str(e)}), 500

@app.route('/api/certificates/manual', methods=['GET'])
def get_manual_domains():
    """获取所有需要手动部署的域名"""
    try:
        cert_manager = CertificateManager()
        domains_config = cert_manager._load_domains_config()
        
        if not domains_config:
            return jsonify({'domains': []})
        
        manual_domains = []
        
        for domain_config in domains_config:
            domain = domain_config['domain']
            subdomains = domain_config.get('subdomains', [])
            
            for subdomain in subdomains:
                if isinstance(subdomain, dict) and subdomain.get('domain'):
                    subdomain_name = subdomain['domain']
                    deploy_method = subdomain.get('deploy_method', 'auto')
                    
                    if deploy_method == 'manual':
                        cert_info = cert_manager._get_certificate_info(domain)
                        manual_domains.append({
                            'domain': subdomain_name,
                            'parent_domain': domain,
                            'deploy_method': deploy_method,
                            'cert_exists': cert_info['exists'],
                            'expires': cert_info.get('expires', ''),
                            'status': cert_info.get('status', 'unknown'),
                            'cert_dir': cert_info.get('cert_dir', ''),
                            'description': f"手动部署域名 - {subdomain_name}"
                        })
        
        return jsonify({'domains': manual_domains})
    
    except Exception as e:
        logger.error(f"获取手动部署域名失败: {e}")
        return jsonify({'error': str(e)}), 500

@app.route('/api/certificates/manual/<domain>/download', methods=['GET'])
def download_manual_certificate(domain):
    """下载手动部署域名的证书文件"""
    try:
        cert_manager = CertificateManager()
        
        # 查找父域名
        domains_config = cert_manager._load_domains_config()
        parent_domain = None
        
        for domain_config in domains_config:
            subdomains = domain_config.get('subdomains', [])
            for subdomain in subdomains:
                if isinstance(subdomain, dict) and subdomain.get('domain') == domain:
                    if subdomain.get('deploy_method') == 'manual':
                        parent_domain = domain_config['domain']
                        break
            if parent_domain:
                break
        
        if not parent_domain:
            return jsonify({'error': '未找到手动部署的域名配置'}), 404
        
        cert_info = cert_manager._get_certificate_info(parent_domain)
        
        if not cert_info['exists']:
            return jsonify({'error': '证书不存在'}), 404
        
        # 创建临时ZIP文件
        temp_dir = tempfile.mkdtemp()
        zip_path = os.path.join(temp_dir, f'{domain}_certificates.zip')
        
        with zipfile.ZipFile(zip_path, 'w') as zipf:
            cert_dir = cert_info['cert_dir']
            for root, dirs, files in os.walk(cert_dir):
                for file in files:
                    file_path = os.path.join(root, file)
                    arcname = os.path.relpath(file_path, cert_dir)
                    zipf.write(file_path, arcname)
        
        return send_file(zip_path, 
                        as_attachment=True,
                        download_name=f'{domain}_certificates.zip',
                        mimetype='application/zip')
    
    except Exception as e:
        logger.error(f"下载手动部署证书失败: {e}")
        return jsonify({'error': str(e)}), 500

@app.route('/health', methods=['GET'])
def health_check():
    """健康检查"""
    return jsonify({
        'status': 'ok',
        'timestamp': datetime.now().isoformat(),
        'version': '1.0.0'
    })

@app.errorhandler(404)
def not_found(error):
    return jsonify({'error': 'API endpoint not found'}), 404

@app.errorhandler(500)
def internal_error(error):
    return jsonify({'error': 'Internal server error'}), 500

if __name__ == '__main__':
    # 确保必要的目录存在
    os.makedirs(LOG_DIR, exist_ok=True)
    os.makedirs(CERT_DIR, exist_ok=True)
    
    logger.info("启动SSL证书管理系统API服务器")
    logger.info(f"数据目录: {DATA_DIR}")
    logger.info(f"配置目录: {BASE_DIR}")
    logger.info(f"脚本目录: {SCRIPTS_DIR}")
    
    # 启动Flask应用
    app.run(
        host='0.0.0.0',
        port=5000,
        debug=False,
        threaded=True
    ) 
