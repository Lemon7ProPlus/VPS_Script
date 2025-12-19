#!/bin/bash
set -euo pipefail

# -------- 用户参数（可修改） --------
DOMAIN=${DOMAIN:-"ssh.example.com"}
INSTALL_DIR="/root/ssh"
SERVICE_FILE="/etc/systemd/system/sshwifty.service"
GH_ARCH=$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')
PASSWORD=${PASSWORD:-$(openssl rand -hex 8)}
SSH_PORT=8182  # sshwifty 本地监听端口

# -------- 检查依赖 --------
install_dependencies() {
    echo "=== 1. 安装 Caddy ==="
    apt update
    apt install -y debian-keyring debian-archive-keyring apt-transport-https curl

    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
      | sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg

    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
      | sudo tee /etc/apt/sources.list.d/caddy-stable.list

    chmod o+r /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    chmod o+r /etc/apt/sources.list.d/caddy-stable.list

    apt update
    apt install -y caddy
}

# -------- 下载最新 release --------
install_sshwifty() {
    mkdir -p "$INSTALL_DIR"
    cd "$INSTALL_DIR"

    TMP_DIR=$(mktemp -d)
    echo "创建临时目录: $TMP_DIR"
    cd "$TMP_DIR"

    echo "获取 sshwifty 最新版本..."
    LATEST_URL=$(curl -L -H "Accept: application/vnd.github+json" \
                 https://api.github.com/repos/niruix/sshwifty/releases/latest \
                 | grep browser_download_url \
                 | grep "$GH_ARCH" \
                 | grep linux \
                 | cut -d '"' -f 4)

    if [ -z "$LATEST_URL" ]; then
        echo "无法获取匹配架构的 sshwifty 版本（架构：$GH_ARCH）"
        rm -rf "$TMP_DIR"
        exit 1
    fi

    FILE_NAME=$(basename "$LATEST_URL")
    echo "下载: $FILE_NAME"
    wget -q -O "$FILE_NAME" "$LATEST_URL"
    tar -xzf "$FILE_NAME"

    BIN_NAME=$(find "$TMP_DIR" -maxdepth 1 -type f -name "sshwifty*" ! -name "*.tar.gz" | head -n 1)
    if [ -z "$BIN_NAME" ]; then
        echo "错误：未找到 sshwifty 可执行文件"
        rm -rf "$TMP_DIR"
        exit 1
    fi

    mv -f "$BIN_NAME" "$INSTALL_DIR/sshwifty"
    chmod +x "$INSTALL_DIR/sshwifty"
    echo "sshwifty 安装完成，位置：$INSTALL_DIR/sshwifty"

    rm -rf "$TMP_DIR"
}

# -------- 生成 sshwifty 配置文件 --------
generate_config() {
    mkdir -p "$INSTALL_DIR"

    cat > "$INSTALL_DIR/sshwifty.conf.json" <<EOF
{
  "HostName": "",
  "SharedKey": "$PASSWORD",
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
      "ListenPort": $SSH_PORT,
      "InitialTimeout": 3,
      "ReadTimeout": 60,
      "WriteTimeout": 60,
      "HeartbeatTimeout": 20,
      "ReadDelay": 10,
      "WriteDelay": 10,
      "ServerMessage":  "SSHwifty"
    }
  ],
  "Presets": [],
  "OnlyAllowPresetRemotes": false
}
EOF

    echo "已生成 sshwifty 配置: $INSTALL_DIR/sshwifty.conf.json"
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

# -------- 配置 Caddy 反代 --------
setup_caddy() {
    CADDYFILE="/etc/caddy/Caddyfile"
    ADD_CFG=$(cat <<EOF
$DOMAIN {
    reverse_proxy 127.0.0.1:$SSH_PORT
}
EOF
)

    if grep -q "$DOMAIN" "$CADDYFILE"; then
        echo "Caddy 配置已存在，跳过追加"
    else
        echo "$ADD_CFG" >> "$CADDYFILE"
        echo "已追加 Caddy 配置: $DOMAIN -> sshwifty:$SSH_PORT"
    fi

    systemctl reload caddy || systemctl restart caddy
}

# -------- 启动 sshwifty 服务 --------
start_service() {
    systemctl restart sshwifty
    systemctl status sshwifty --no-pager
}

# -------- 主流程 --------
main() {
    install_dependencies
    install_sshwifty
    sleep 3s
    generate_config
    create_service
    start_service
    setup_caddy

    echo "=========== sshwifty 安装完成 ==========="
    echo "访问地址：https://$DOMAIN"
    echo "访问密码：$PASSWORD"
    echo "配置文件：$INSTALL_DIR/sshwifty.conf.json"
    echo "可执行文件：$INSTALL_DIR/sshwifty"
    echo "systemd 服务：systemctl restart sshwifty"
}

main
