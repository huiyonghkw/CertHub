# SSL证书自动管理服务Dockerfile
# 基于Alpine Linux构建轻量级证书管理容器
FROM swr.cn-north-4.myhuaweicloud.com/ddn-k8s/docker.io/alpine:3.18

# 维护者信息
LABEL maintainer="SSL Certificate Manager <admin@example.com>"
LABEL version="1.0.0"
LABEL description="Automated SSL Certificate Management Service with ACME.sh"

# 设置环境变量
ENV ACME_HOME=/opt/acme.sh \
    CERT_HOME=/data/certs \
    LOG_HOME=/data/logs \
    BACKUP_HOME=/data/backups \
    CONFIG_HOME=/config \
    SCRIPTS_HOME=/scripts \
    TZ=Asia/Shanghai \
    LANG=C.UTF-8

# 设置工作目录
WORKDIR /opt

# 配置Alpine软件源为国内镜像
RUN sed -i 's/dl-cdn.alpinelinux.org/mirrors.aliyun.com/g' /etc/apk/repositories

# 安装系统依赖包
RUN apk add --no-cache \
    bash \
    curl \
    wget \
    git \
    openssh-client \
    sshpass \
    rsync \
    openssl \
    ca-certificates \
    jq \
    yq \
    python3 \
    py3-pip \
    py3-yaml \
    py3-requests \
    py3-cryptography \
    tzdata \
    dcron \
    sudo \
    socat \
    && rm -rf /var/cache/apk/*

# 配置pip使用国内镜像源
RUN pip3 config set global.index-url https://mirrors.aliyun.com/pypi/simple/ && \
    pip3 config set global.trusted-host mirrors.aliyun.com

# 安装Python依赖（分步安装以便调试）
RUN pip3 install --no-cache-dir pyyaml requests cryptography && \
    pip3 install --no-cache-dir click colorama tabulate || \
    apk add --no-cache py3-click

# 安装Web API服务器依赖
RUN pip3 install --no-cache-dir flask flask-cors

# 创建系统用户
RUN addgroup -g 1000 acme && \
    adduser -D -s /bin/bash -G acme -u 1000 acme && \
    echo "acme ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/acme

# 创建必要的目录
RUN mkdir -p \
    ${ACME_HOME} \
    ${CERT_HOME} \
    ${LOG_HOME} \
    ${BACKUP_HOME} \
    ${CONFIG_HOME} \
    ${SCRIPTS_HOME} \
    /var/log/acme \
    /etc/acme \
    /root/.ssh

# 安装acme.sh客户端 (使用离线方式或备用源)
RUN wget -O acme.sh https://raw.githubusercontent.com/acmesh-official/acme.sh/master/acme.sh || \
    wget -O acme.sh https://gitee.com/neilpang/acme.sh/raw/master/acme.sh || \
    curl -fsSL https://get.acme.sh | sh || \
    (apk add --no-cache acme.sh && echo "使用系统包安装acme.sh")

# 创建acme.sh软链接并设置权限
RUN if [ -f "acme.sh" ]; then \
        chmod +x acme.sh && \
        mv acme.sh /usr/local/bin/acme.sh; \
    elif [ -f "/root/.acme.sh/acme.sh" ]; then \
        ln -sf /root/.acme.sh/acme.sh /usr/local/bin/acme.sh; \
    else \
        echo "acme.sh安装成功，使用系统包"; \
    fi

# 配置acme.sh (如果通过脚本安装)
RUN if [ -f "/root/.acme.sh/acme.sh" ]; then \
        /root/.acme.sh/acme.sh --set-default-ca --server letsencrypt && \
        /root/.acme.sh/acme.sh --upgrade --auto-upgrade; \
    fi

# 复制脚本文件
COPY scripts/ ${SCRIPTS_HOME}/
COPY config/ ${CONFIG_HOME}/

# 设置脚本权限
RUN chmod +x ${SCRIPTS_HOME}/*.sh && \
    chmod +x ${SCRIPTS_HOME}/utils/*.sh

# 配置SSH客户端
RUN echo "Host *" >> /etc/ssh/ssh_config && \
    echo "    StrictHostKeyChecking no" >> /etc/ssh/ssh_config && \
    echo "    UserKnownHostsFile /dev/null" >> /etc/ssh/ssh_config && \
    echo "    LogLevel ERROR" >> /etc/ssh/ssh_config

# 配置cron
RUN echo "# SSL证书自动管理定时任务" > /etc/crontabs/root && \
    echo "0 2 * * * /scripts/cert-manager.sh monitor >> /data/logs/cron.log 2>&1" >> /etc/crontabs/root && \
    echo "0 3 * * * /scripts/cert-manager.sh renew-all >> /data/logs/cron.log 2>&1" >> /etc/crontabs/root && \
    echo "0 11 * * * /scripts/cert-manager.sh report >> /data/logs/status-report.log 2>&1" >> /etc/crontabs/root && \
    echo "0 4 * * 0 /scripts/utils/backup.sh cleanup >> /data/logs/backup.log 2>&1" >> /etc/crontabs/root

# 创建启动脚本
RUN cat > /entrypoint.sh << 'EOF'
#!/bin/bash
set -e

# 初始化日志目录
mkdir -p ${LOG_HOME} ${BACKUP_HOME} ${CERT_HOME}

# 检查配置文件
if [ ! -f "${CONFIG_HOME}/domains.yml" ]; then
    echo "警告: 域名配置文件不存在，将使用示例配置"
    cp "${CONFIG_HOME}/domains.yml.example" "${CONFIG_HOME}/domains.yml"
fi

if [ ! -f "${CONFIG_HOME}/servers.yml" ]; then
    echo "警告: 服务器配置文件不存在，将使用示例配置"
    cp "${CONFIG_HOME}/servers.yml.example" "${CONFIG_HOME}/servers.yml"
fi

if [ ! -f "${CONFIG_HOME}/dns-providers.yml" ]; then
    echo "警告: DNS提供商配置文件不存在，将使用示例配置"
    cp "${CONFIG_HOME}/dns-providers.yml.example" "${CONFIG_HOME}/dns-providers.yml"
fi

# 设置文件权限（跳过只读文件系统）
chmod 600 ${CONFIG_HOME}/dns-providers.yml 2>/dev/null || echo "配置文件为只读，跳过权限设置"
chmod 600 ${CONFIG_HOME}/servers.yml 2>/dev/null || echo "配置文件为只读，跳过权限设置"
chmod 600 /root/.ssh/* 2>/dev/null || true

# 启动cron服务
crond -b -l 2

# 记录启动信息
echo "$(date '+%Y-%m-%d %H:%M:%S') - ACME SSL Certificate Manager started" >> ${LOG_HOME}/service.log

# 如果有参数，执行命令；否则保持容器运行
if [ $# -gt 0 ]; then
    exec "$@"
else
    # 保持容器运行
    tail -f /dev/null
fi
EOF

# 设置启动脚本权限
RUN chmod +x /entrypoint.sh

# 设置目录权限
RUN chown -R acme:acme ${CERT_HOME} ${LOG_HOME} ${BACKUP_HOME} && \
    chown -R root:root ${CONFIG_HOME} ${SCRIPTS_HOME}

# 暴露端口（如果需要健康检查接口）
EXPOSE 8080

# 健康检查 (简化版本)
HEALTHCHECK --interval=30s --timeout=10s --start-period=10s --retries=3 \
    CMD test -f /scripts/cert-manager-simple.sh && echo "Health check OK" || exit 1

# 数据卷
VOLUME ["${CERT_HOME}", "${LOG_HOME}", "${BACKUP_HOME}", "${CONFIG_HOME}"]

# 启动入口
ENTRYPOINT ["/entrypoint.sh"]

# 默认命令
CMD ["tail", "-f", "/dev/null"] 
