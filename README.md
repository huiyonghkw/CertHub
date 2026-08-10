# CertHub Community

<div align="center">

![CertHub Logo](docs/images/certhub-logo.svg)

[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE.md)
[![Docker](https://img.shields.io/badge/docker-ready-brightgreen.svg)](https://www.docker.com/)
[![ACME](https://img.shields.io/badge/ACME-Let's%20Encrypt-orange.svg)](https://letsencrypt.org/)

**自托管的 SSL/TLS 证书签发、续期、部署与完整链校验工具。**

</div>

CertHub Community 基于 Docker、acme.sh 和 DNS-01，把证书申请、自动续期、SSH 部署、手动 ZIP 打包以及完整证书链校验放进同一套 CLI + YAML 工作流。

## Community 能力

- 单域名与泛域名证书申请
- 阿里云、腾讯云、华为云 DNS-01
- ECC 与 RSA 证书
- 定时续期与到期提醒
- SSH/SCP 自动部署及 nginx reload
- 为 CDN 等控制台上传场景生成手动 ZIP
- 完整证书链校验
- 邮件、钉钉、Webhook、Slack 通知
- Docker 健康检查与只读 `GET /health`

> Community 仓库不包含 Web 管理控制台和完整 REST API。它们属于 CertHub Pro，且在独立的私有交付包中维护。

## 快速开始

### 1. 准备配置

```bash
cp config/domains.yml.example config/domains.yml
cp config/dns-providers.yml.example config/dns-providers.yml
cp config/servers.yml.example config/servers.yml
cp config/notify.yml.example config/notify.yml
```

真实 DNS 密钥、服务器信息和通知凭据已被 `.gitignore` 排除，请勿提交。

### 2. 启动服务

```bash
docker compose up -d acme-manager acme-health
```

### 3. 检查状态

```bash
docker compose ps
curl http://localhost:8080/health
docker exec acme-ssl-manager /scripts/cert-manager-simple.sh health-check
```

健康接口只返回 Community 服务状态，不提供证书、配置、日志或写操作。

## 配置结构

### DNS 提供商

在 `config/dns-providers.yml` 中配置 acme.sh 所需的环境变量。参考：

```yaml
dns_providers:
  aliyun:
    provider_name: "阿里云 DNS"
    dns_api: dns_ali
    credentials:
      Ali_Key: "your-key"
      Ali_Secret: "your-secret"
```

### 域名

```yaml
domains:
  - domain: example.com
    wildcard: true
    dns_provider: aliyun
    servers:
      - server_prod_01
    subdomains:
      - domain: api.example.com
        deploy_method: auto
      - domain: cdn.example.com
        deploy_method: manual
```

### 部署服务器

```yaml
servers:
  - server_id: server_prod_01
    host: 192.0.2.10
    port: 22
    user: deploy
    ssl_cert_dir: /etc/nginx/ssl
    nginx_reload_cmd: sudo nginx -s reload
```

生产环境建议只挂载专用部署密钥，不要把整个个人 SSH 目录交给容器。

## 常用命令

```bash
# 查看帮助
docker exec acme-ssl-manager /scripts/cert-manager.sh help

# 检查全部证书状态
docker exec acme-ssl-manager /scripts/cert-manager.sh status-all

# 续期即将到期的证书
docker exec acme-ssl-manager /scripts/cert-manager.sh renew-all

# 查看需要人工上传的域名
docker exec acme-ssl-manager /scripts/cert-manager.sh list-manual

# 为手动部署目标打包
docker exec acme-ssl-manager /scripts/cert-manager.sh pack-manual

# 校验证书链
docker exec acme-ssl-manager /scripts/cert-manager.sh verify-chains
```

以当前脚本的 `help` 输出为最终命令依据。

## 自动与手动部署

- `deploy_method: auto`：通过 SSH/SCP 推送证书，并执行配置好的 reload 命令。
- `deploy_method: manual`：批量自动部署时跳过，由 CLI 打成 ZIP，供 CDN 或云控制台人工上传。

手动上传后仍应对线上域名执行完整证书链校验。浏览器显示正常，并不保证微信小程序等客户端能接受缺少中间证书的链。

## 定时任务

默认容器包含以下 Cron 任务：

| 时间 | 任务 |
| --- | --- |
| 每日 02:00 | 证书状态监控 |
| 每日 03:00 | 自动续期 |
| 每日 11:00 | 状态报告 |
| 每周日 04:00 | 旧备份清理 |

## 项目结构

```text
CertHub/
├── config/             # YAML 示例；真实配置不入库
├── scripts/            # Community CLI 与证书工作流
│   ├── cert-manager.sh
│   ├── cert-manager-simple.sh
│   ├── lib/
│   └── utils/
├── web/                # 仅 Community /health
├── monitoring/         # 可选 Prometheus 配置
├── tests/              # 冒烟测试
├── Dockerfile
└── docker-compose.yml
```

## 安全边界

- 不要提交 DNS API 密钥、SSH 私钥、证书私钥或真实运行配置。
- 对生产服务器使用最小权限部署账号和专用 SSH 密钥。
- `GET /health` 是公开版唯一 HTTP 接口，不返回证书库存或配置内容。
- Community 不应出现 `/api/certificates`、`/api/config`、`/api/logs` 等管理路由。
- 发现安全问题请参考 [SECURITY.md](SECURITY.md)。

## Community 与 Pro

本仓库只维护 MIT 授权的 Community 能力。CertHub Pro 的 Web 控制台、完整 REST API、商业授权及后续生产级能力在独立私有代码库和交付包中维护。

公开产品介绍可以说明版本差异，但不得把 Pro 源码、授权文件、私有发布包或支付素材提交到本仓库。

## 许可证

Community 版本采用 [MIT License](LICENSE.md)。该许可证只适用于本公开仓库中实际发布的文件，不代表未来独立交付的 CertHub Pro 软件采用相同许可证。

## 致谢

- [acme.sh](https://github.com/acmesh-official/acme.sh)
- [Let's Encrypt](https://letsencrypt.org/)
- [Docker](https://www.docker.com/)
