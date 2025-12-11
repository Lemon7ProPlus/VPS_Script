#!/bin/bash

set -e

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

echo "=== 2. 安装 HubProxy ==="
curl -fsSL https://raw.githubusercontent.com/sky22333/hubproxy/main/install.sh | sudo bash

echo "=== 3. 配置 Caddyfile ==="

CADDYFILE="/etc/caddy/Caddyfile"

# 要追加的配置内容
read -r -d '' ADD_CFG << 'EOF'
$CUSTOM_DOMAIN {
    reverse_proxy 127.0.0.1:5000 {
        header_up X-Forwarded-For {http.request.header.CF-Connecting-IP}
        header_up X-Real-IP {http.request.header.CF-Connecting-IP}
        header_up X-Forwarded-Proto https
        header_up X-Forwarded-Host {host}
    }
}
EOF

# 检查是否已存在，避免重复添加
if grep -q "hp.onemoess.com" "$CADDYFILE"; then
    echo "配置已存在，跳过追加"
else
    echo "$ADD_CFG" >> "$CADDYFILE"
    echo "已追加到 $CADDYFILE"
fi

echo "=== 4. 重新加载 Caddy ==="
systemctl reload caddy || systemctl restart caddy

echo "=== 完成 ==="
echo "Caddy + HubProxy 已全部安装并配置完毕。"
