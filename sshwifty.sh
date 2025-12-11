#!/bin/bash
set -euo pipefail

# -------- 用户参数（可修改） --------
DOMAIN=${DOMAIN:-"ssh.example.com"}
INSTALL_DIR="/root/ssh"
SERVICE_FILE="/etc/systemd/system/sshwifty.service"
GH_ARCH=$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')
SHARED_KEY=$(openssl rand -hex 8)

# -------- 检查依赖 --------
install_dependencies() {
    . /etc/os-release
    OS="$ID"

    case "$OS" in
        debian|ubuntu)
            apt update
            apt install -y curl wget unzip socat cron ;;
        alpine)
            apk update
            apk add curl wget unzip socat bash ;;
        *)
            echo "不支持系统：$OS"
            exit 1 ;;
    esac
}

# -------- 下载最新 release --------
install_sshwifty() {
    mkdir -p "$INSTALL_DIR"
    cd "$INSTALL_DIR"
    
    # 创建临时目录
    TMP_DIR=$(mktemp -d)
    echo "创建临时目录: $TMP_DIR"
    cd "$TMP_DIR"
    
    echo "获取 sshwifty 最新版本..."
    LATEST_URL=$(curl -L -H "Accept: application/vnd.github+json" \
                 https://api.github.com/repos/niruix/sshwifty/releases/latest \
                | grep browser_download_url \
                | grep amd64 \
                | grep linux \
                | cut -d '"' -f 4)

    if [ -z "$LATEST_URL" ]; then
        echo "无法从 GitHub 获取匹配架构的 sshwifty 版本（架构：$GH_ARCH）"
        rm -rf "$TMP_DIR"
        exit 1
    fi

    FILE_NAME=$(basename "$LATEST_URL")

    echo "下载: $FILE_NAME"
    wget -q -O "$FILE_NAME" "$LATEST_URL"

    echo "解压文件..."
    tar -xzf "$FILE_NAME"

    # 找出解压后的二进制文件名
    BIN_NAME=$(find "$TMP_DIR" -maxdepth 1 -type f -name "sshwifty*" ! -name "*.tar.gz" | head -n 1)

    if [ -z "$BIN_NAME" ]; then
        echo "错误：未找到 sshwifty 可执行文件"
        rm -rf "$TMP_DIR"
        exit 1
    fi

    echo "发现二进制文件: $(basename "$BIN_NAME")"

    mv -f "$BIN_NAME" "$INSTALL_DIR/sshwifty"
    chmod +x "$INSTALL_DIR/sshwifty"

    echo "sshwifty 安装完成，位置：$INSTALL_DIR/sshwifty"
    
    # 清理临时文件夹
    rm -rf "$TMP_DIR"
    echo "临时目录已清理"
}

# -------- 安装 acme.sh 并申请证书（Cloudflare DNS-01）--------
issue_certificate() {
    curl https://get.acme.sh | sh

    ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt

    # 检查是否有公网 IPv6
    echo "检测 IPv6 公网地址..."
    if ip -6 addr show scope global | grep -q "inet6"; then
        echo "检测到 IPv6 公网地址，将使用 --listen-v6 模式申请证书"
        LISTEN_MODE="--standalone --listen-v6"
    else
        echo "未检测到 IPv6 公网地址，使用 IPv4 standalone 模式"
        LISTEN_MODE="--standalone"
    fi

    # 申请证书
    ~/.acme.sh/acme.sh --issue \
        -d "$DOMAIN" \
        $LISTEN_MODE

    if [ ! -d "$INSTALL_DIR/cert" ]; then
        mkdir -p "$INSTALL_DIR/cert"
    fi

    # 安装证书
    ~/.acme.sh/acme.sh --install-cert \
        -d "$DOMAIN" \
        --key-file "$INSTALL_DIR/cert/key.pem" \
        --fullchain-file "$INSTALL_DIR/cert/fullchain.pem"
        
    echo "证书申请成功，已安装到 $INSTALL_DIR/cert/"
}

# -------- 生成配置文件 --------
generate_config() {
    mkdir -p "$INSTALL_DIR"

    cat > "$INSTALL_DIR/sshwifty.conf.json" <<EOF
{
  "HostName": "",
  "SharedKey": "$SHARED_KEY",
  "DialTimeout": 5,
  "Socks5": "",
  "Socks5User": "",
  "Socks5Password": "",
  "Hooks": {
    "before_connecting": []
  },
  "HookTimeout": 30,
  "Servers": [
    {
      "ListenInterface": "0.0.0.0",
      "ListenPort": 8182,
      "InitialTimeout": 3,
      "ReadTimeout": 60,
      "WriteTimeout": 60,
      "HeartbeatTimeout": 20,
      "ReadDelay": 10,
      "WriteDelay": 10,
      "TLSCertificateFile": "$INSTALL_DIR/cert/fullchain.pem",
      "TLSCertificateKeyFile": "$INSTALL_DIR/cert/key.pem",
      "ServerMessage":  "SSHwifty"
    }
  ],
  "Presets": [],
    "OnlyAllowPresetRemotes": false
}
EOF

    echo "已生成配置: $INSTALL_DIR/sshwifty.conf.json"
}

# -------- 创建 systemd 服务 --------
create_service() {
    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Sshwifty Web SSH Gateway
After=network.target

[Service]
ExecStart=$INSTALL_DIR/sshwifty --config $INSTALL_DIR/sshwifty.conf.json
WorkingDirectory=$INSTALL_DIR
Restart=on-failure
RestartSec=5s
User=root

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable sshwifty
}

# -------- 启动服务 --------
start_service() {
    
    if [ ! -s "$INSTALL_DIR/cert/fullchain.pem" ] || [ ! -s "$INSTALL_DIR/cert/key.pem" ]; then
        echo "证书不存在或无效，停止"
        exit 1
    fi
    
    systemctl restart sshwifty
    systemctl status sshwifty --no-pager
}

# -------- 主流程 --------
main() {
    install_dependencies
    install_sshwifty
    sleep 5s
    issue_certificate
    generate_config
    create_service
    start_service
    
    echo "=========== sshwifty 安装完成 ==========="
    echo "访问地址：https://$DOMAIN"
    echo "访问密码：$SHARED_KEY"
    echo "配置文件：$INSTALL_DIR/sshwifty.conf.json"
    echo "可执行文件：$INSTALL_DIR/sshwifty"
    echo "systemd 服务：systemctl restart sshwifty"
}

main
