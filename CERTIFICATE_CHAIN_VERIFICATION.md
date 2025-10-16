# SSL 证书链完整性验证系统

## 📋 概述

本文档说明了 SSL 证书链完整性验证系统的实现，这是为了解决微信小程序等应用的 SSL 证书信任问题而开发的功能。

## 🚨 问题背景

### 微信小程序 SSL 证书验证失败

**错误信息**：

```
MiniProgramError {"errno":600001,"errMsg":"request:fail errcode:-202 cronet_error_code:-202 error_msg:net::ERR_CERT_AUTHORITY_INVALID"}
```

**问题原因**：

- 服务器部署的 SSL 证书缺少中间证书
- 证书链不完整，导致客户端无法验证证书的可信度
- 微信小程序对 SSL 证书有严格的验证要求

## 🔧 解决方案

### 1. 系统级改进

#### 1.1 部署脚本增强

**部署前验证**：

```bash
# 验证证书链的完整性
local cert_count
cert_count=$(grep -c 'BEGIN CERTIFICATE' "$cert_file" 2>/dev/null || echo "0")
if [[ $cert_count -lt 2 ]]; then
    log_warn "证书链不完整，只包含 $cert_count 个证书"
    # 自动查找并使用完整证书链
fi
```

**部署后验证**：

```bash
# 验证远程服务器的证书链
local cert_chain_count
cert_chain_count=$(echo | openssl s_client -servername "$domain" -connect "${host}:443" -showcerts 2>/dev/null | grep -c 'BEGIN CERTIFICATE')
```

#### 1.2 文件优先级调整

**优先使用完整证书链**：

```bash
# 优先顺序：fullchain.cer > domain.cer
if [[ -f "${CERT_DIR}/${domain}_ecc/fullchain.cer" ]]; then
    cert_file="${CERT_DIR}/${domain}_ecc/fullchain.cer"
elif [[ -f "${CERT_DIR}/${domain}/fullchain.cer" ]]; then
    cert_file="${CERT_DIR}/${domain}/fullchain.cer"
# 其他作为备选
fi
```

### 2. 新增验证命令

#### 2.1 完整版验证

```bash
docker exec acme-ssl-manager /scripts/cert-manager.sh verify-chains
```

**输出示例**：

```
📋 SSL证书链完整性验证报告
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
✅ zhengcetongban.com: 完整证书链 (2 个证书) - fullchain.cer
   📅 过期时间: Oct 10 04:05:11 2025 GMT

⚠️  example.com: 不完整证书链 (1 个证书) - example.com.cer
   📝 建议: 使用 fullchain.cer 文件包含完整证书链

📊 统计结果:
• 总域名数: 12
• 完整证书链: 7
• 不完整证书链: 0
• 缺失证书: 5
```

#### 2.2 简化版验证

```bash
docker exec acme-ssl-manager /scripts/cert-manager-simple.sh verify-chains
```

**输出示例**：

```
✅ zhengcetongban.com_ecc: 完整证书链 (2 个证书)
❌ example.com: 缺少 fullchain.cer 文件
```

### 3. 自动修复机制

#### 3.1 部署时自动切换

```bash
# 如果检测到证书链不完整，自动查找完整证书链
if [[ $cert_count -lt 2 ]]; then
    local fullchain_file="${cert_storage_dir}/fullchain.cer"
    if [[ -f "$fullchain_file" && "$cert_file" != "$fullchain_file" ]]; then
        local fullchain_count
        fullchain_count=$(grep -c 'BEGIN CERTIFICATE' "$fullchain_file" 2>/dev/null || echo "0")
        if [[ $fullchain_count -ge 2 ]]; then
            log_info "找到完整证书链文件，切换使用: $fullchain_file"
            cert_file="$fullchain_file"
        fi
    fi
fi
```

#### 3.2 警告和日志记录

```bash
# 使用单个证书时记录警告
if [[ -f "$cert_file" ]]; then
    log_warn "使用单个证书文件而非完整证书链: $cert_file"
fi
```

## 🧪 测试验证

### 1. 本地验证

```bash
# 检查证书链数量
docker exec acme-ssl-manager grep -c 'BEGIN CERTIFICATE' /data/certs/domain_ecc/fullchain.cer
# 应该返回 2 或更多

# 检查证书信息
docker exec acme-ssl-manager openssl x509 -in /data/certs/domain_ecc/fullchain.cer -text -noout | grep -A 2 "Subject Alternative Name"
```

### 2. 远程验证

```bash
# 检查远程服务器的证书链
echo | openssl s_client -connect api.zhengcetongban.com:443 -showcerts 2>/dev/null | grep -c 'BEGIN CERTIFICATE'
# 应该返回 2 或更多

# 检查证书信任
echo | openssl s_client -connect api.zhengcetongban.com:443 -verify_return_error 2>/dev/null | grep "Verify return code"
# 应该返回 "Verify return code: 0 (ok)"
```

### 3. 微信小程序测试

- 在微信开发者工具中测试 API 请求
- 确保不再出现 `ERR_CERT_AUTHORITY_INVALID` 错误
- 验证 HTTPS 请求可以正常完成

## 🔄 维护流程

### 1. 定期检查

```bash
# 每周检查证书链状态
docker exec acme-ssl-manager /scripts/cert-manager.sh verify-chains

# 检查即将过期的证书
docker exec acme-ssl-manager /scripts/cert-manager.sh status-all
```

### 2. 问题修复

```bash
# 发现证书链不完整时
docker exec acme-ssl-manager /scripts/cert-manager.sh generate domain.com
docker exec acme-ssl-manager /scripts/cert-manager.sh deploy domain.com server_id
```

### 3. 监控指标

- 完整证书链数量
- 不完整证书链数量
- 缺失证书数量
- 证书过期预警

## 📊 系统架构

```
证书生成 → 本地验证 → 部署前检查 → 远程部署 → 部署后验证 → 监控报告
    ↓           ↓           ↓           ↓           ↓           ↓
acme.sh → fullchain.cer → 链完整性 → scp上传 → 远程验证 → 定期检查
```

## 🎯 最佳实践

### 1. 证书生成

- 始终使用 `fullchain.cer` 文件
- 验证证书包含完整链（2 个或更多证书）

### 2. 证书部署

- 部署前验证证书链完整性
- 部署后验证远程服务器状态
- 记录详细的部署日志

### 3. 证书监控

- 定期检查证书链状态
- 监控证书过期时间
- 自动化修复流程

## 🔗 相关文档

- [SSL 证书管理系统文档](README.md)
- [故障排除指南](README.md#故障排除)
- [API 文档](README.md#api接口)

## 📝 更新日志

### v1.1.0 (2025-07-17)

- ✅ 新增证书链完整性验证功能
- ✅ 增强部署脚本，自动检查证书链
- ✅ 添加 `verify-chains` 命令
- ✅ 修复微信小程序 SSL 验证问题
- ✅ 改进日志记录和错误处理

### v1.0.0 (2025-07-12)

- ✅ 基础 SSL 证书管理功能
- ✅ 自动生成和部署证书
- ✅ 支持多 DNS 提供商
- ✅ 自动续期功能

---

**💡 重要提示**: 完整的证书链对于移动应用、微信小程序等客户端的 SSL 验证至关重要。始终确保使用 `fullchain.cer` 文件进行部署。
