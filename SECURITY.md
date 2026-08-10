# CertHub Community 安全说明

CertHub Community 面向自托管环境，公开仓库只包含 CLI、YAML 工作流和只读健康检查。

## 必须遵守

1. 不要提交 `dns-providers.yml`、`servers.yml`、真实域名配置、通知凭据、证书私钥或 SSH 私钥。
2. 生产环境只挂载 CertHub 部署所需的专用 SSH 密钥，并使用最小权限账号。
3. `8080` 端口只提供 `GET /health`；其他路径均应返回 404。
4. 定期更新基础镜像、acme.sh 和系统依赖。

## 能力边界

- 自动部署指 SSH/SCP 推送与远端 reload。
- 手动部署指生成 ZIP 后由操作者上传 CDN 或云控制台。
- DNS-01 接口用于域名验证，不等同于云厂商证书上传接口。
- Community 不包含 Web 管理控制台和完整 REST API。

## 报告安全问题

请通过 GitHub Security Advisory 私下报告，不要在公开 Issue 中粘贴密钥、证书、服务器地址或利用细节。
