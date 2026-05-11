#!/bin/bash
set -euo pipefail

############################################
# 依赖安装：curl + vim（根据系统类型自动安装）
############################################
install_dependencies() {
    echo "=== 检查并安装依赖 (vim, curl) ==="

    if [[ $EUID -ne 0 ]]; then
        echo "[ERROR] 此脚本需要 root 权限运行"
        exit 1
    fi

    local deps=("vim" "curl")

    if command -v apt >/dev/null 2>&1; then
        apt update -y
        apt install -y "${deps[@]}"

    elif command -v apk >/dev/null 2>&1; then
        apk update
        apk add "${deps[@]}"

    else
        echo "[WARNING] 未知系统类型，请手动安装：vim curl"
    fi

    echo "=== 依赖安装完毕 ==="
}

# ---------- 用户自定义参数 ----------
VPS_NAME=${VPS_NAME:-"myserver"}

WORK_DIR=${WORK_DIR:-"/root/sing-box"}

STRATEGY=${STRATEGY:-"prefer_ipv4"}
AI_OUT=${AI_OUT:-"direct-out"}

REALITY_PORT=${REALITY_PORT:-443}
REALITY_DOMAIN=${REALITY_DOMAIN:-"addons.mozilla.org"}

HY2_PORT=${HY2_PORT:-8443}
WS_PORT=${WS_PORT:-8663}

WS_BRUTAL=${WS_BRUTAL:-false}

TLS_VPS=${TLS_VPS:-"vps.example.com"}
TLS_EMAIL=${TLS_EMAIL:-"vps@example.com"}
TLS_TOKEN=${TLS_TOKEN:-"your_cf_token"}

DOMAIN_CDN=${DOMAIN_CDN:-"cf.090227.xyz"}

# ---------- 辅助函数 ----------
get_vps_ip() {
    local ip=""
    if command -v curl &>/dev/null; then
        ip=$(curl -s --connect-timeout 3 https://one.one.one.one/cdn-cgi/trace | grep '^ip=' | cut -d= -f2)
    fi
    [ -z "$ip" ] && ip=$(hostname -I | awk '{print $1}')
    [ -z "$ip" ] && { echo "❌ 无法获取 VPS IP" >&2; return 1; }
    echo "$ip"
}

format_ip_for_url() {
    local ip="$1"
    [[ "$ip" == *:* ]] && echo "[$ip]" || echo "$ip"
}

# ---------- 生成配置值 ----------
generate_config_values() {
    echo "生成 UUID..."
    REALITY_UUID=$(sing-box generate uuid)
    WS_UUID=$(sing-box generate uuid)
    
    WS_PATH="/${WS_UUID##*-}"
    
    echo "生成 Reality X25519 密钥对..."
    keypair=$(sing-box generate reality-keypair)
    REALITY_PRIVATE_KEY=$(echo "$keypair" | awk '/PrivateKey/ {print $2}')
    REALITY_PUBLIC_KEY=$(echo "$keypair" | awk '/PublicKey/ {print $2}')

    echo "生成 Hy2 密码..."
    HY2_UUID=$(sing-box generate rand 16 --base64)

    echo "获取 VPS IP..."
    VPS_IP=$(get_vps_ip || echo "")
    VPS_IP_FORMATTED=$(format_ip_for_url "$VPS_IP")
}

# ---------- 生成 config.json ----------
generate_config_json() {
    mkdir -p ${WORK_DIR}
    
    echo "生成 config.json..."
    
    # 生成 log 配置
    cat > /etc/sing-box/00_log.json << EOF
{
  "log": {
    "disabled": false, 
    "level": "error",
    "output": "${WORK_DIR}/box.log", 
    "timestamp": true
  }
}
EOF

    # 生成 outbound 配置
    cat > /etc/sing-box/01_outbounds.json << EOF
{
  "outbounds": [
    {
      "type": "direct", 
      "tag": "direct-out"
    }
  ]
}
EOF

    # 生成 endpoint 配置
    cat > /etc/sing-box/02_endpoints.json << EOF
{
  "endpoints": [
    {
      "type": "wireguard", 
      "tag": "warp-ep", 
      "mtu": 1280, 
      "address": [
        "172.16.0.2/32",
        "2606:4700:110:8a36:df92:102a:9602:fa18/128"
      ],
      "private_key": "YFYOAdbw1bKTHlNNi+aEjBM3BO7unuFC5rOkMRAz9XY=",
      "peers": [
        {
          "address": "engage.cloudflareclient.com",
          "port": 2408,
          "public_key": "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=",
          "allowed_ips": [
            "0.0.0.0/0",
            "::/0"
          ], 
          "reserved": [
            78, 
            135, 
            76
          ]
        }
      ]
    }
  ]
}
EOF

    # 生成 route 配置
    cat > /etc/sing-box/03_route.json << EOF
{
  "route":{
    "rule_set": [
      {
        "tag": "geosite-ai", 
        "type": "remote", 
        "format": "binary", 
        "url":"https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-category-ai-!cn.srs"
      }
    ], 
    "rules":[
      {
        "action": "sniff"
      }, 
      {
        "action": "route", 
        "rule_set": [
          "geosite-ai"
        ], 
        "outbound": "${AI_OUT}"
      }
    ], 
    "final": "direct-out"
  }
}
EOF

    # 生成 experimental 配置
    cat > /etc/sing-box/04_experimental.json << EOF
{
  "experimental": {
    "cache_file": true, 
    "path": "${WORK_DIR}/cache.db"
  }
}
EOF

    # 生成 dns 配置
    cat > /etc/sing-box/05_dns.json << EOF
{
  "dns": {
    "servers": [
      {
        "type": "local", 
        "tag": "local-dns"
      }
    ], 
    "strategy": "${STRATEGY}"
  }
}
EOF

    # 生成 ntp 配置
    cat > /etc/sing-box/06_ntp.json << EOF
{
  "ntp": {
    "enabled": true, 
    "server": "time.apple.com", 
    "server_port": 123, 
    "interval": "60m"
  }
}
EOF

    # 生成 vless-reality 配置
    cat > /etc/sing-box/11_vless-reality_inbounds.json << EOF
{
    "inbounds":[
        {
            "type": "vless",
            "tag": "vless-reality",
            "listen": "::",
            "listen_port": ${REALITY_PORT},
            "users":[
                {
                    "uuid":"${REALITY_UUID}",
                    "flow":"xtls-rprx-vision"
                }
            ],
            "tls":{
                "enabled":true,
                "server_name":"${REALITY_DOMAIN}",
                "reality":{
                    "enabled":true,
                    "handshake":{
                        "server":"${REALITY_DOMAIN}",
                        "server_port":443
                    },
                    "private_key":"${REALITY_PRIVATE_KEY}",
                    "short_id":[
                        ""
                    ]
                }
            },
            "multiplex":{
                "enabled":false,
                "padding":false,
                "brutal":{
                    "enabled":false,
                    "up_mbps":1000,
                    "down_mbps":1000
                }
            }
        }
    ]
}
EOF

    # 生成 hysteria2 配置
    cat > /etc/sing-box/12_hysteria2_inbounds.json << EOF
{
    "inbounds": [
        {
            "type": "hysteria2", 
            "tag": "hy2", 
            "listen": "::", 
            "listen_port": ${HY2_PORT}, 
            "users":[
                {
                    "password": "${HY2_UUID}"
                }
            ], 
            "ignore_client_bandwidth": false, 
            "tls": {
                "enabled": true, 
                "server_name": "${TLS_VPS}",
                "alpn": "h3", 
                "min_version": "1.3", 
                "max_version": "1.3", 
                "acme": {
                    "domain": "${TLS_VPS}", 
                    "email": "${TLS_EMAIL}", 
                    "dns01_challenge": {
                        "provider": "cloudflare", 
                        "api_token": "${TLS_TOKEN}"
                    }
                }
            }
        }
    ]
}
EOF

    # 生成 vless-ws-tls 配置
    cat > /etc/sing-box/13_vless-ws-tls_inbounds.json << EOF
{
    "inbounds":[
        {
            "type": "vless", 
            "tag": "vless-ws", 
            "listen": "::", 
            "listen_port": ${WS_PORT}, 
            "tcp_fast_open": false, 
            "proxy_protocol": false, 
            "users": [
                {
                    "name": "sing-box", 
                    "uuid": "${WS_UUID}"
                }
            ],
            "transport": {
                "type": "ws", 
                "path": "${WS_PATH}", 
                "max_early_data": 2560, 
                "early_data_header_name": "Sec-WebSocket-Protocol"
            },
            "tls": {
                "enabled": true, 
                "server_name": "${TLS_VPS}", 
                "min_version": "1.3", 
                "max_version": "1.3", 
                "acme": {
                    "domain": "${TLS_VPS}", 
                    "email": "${TLS_EMAIL}", 
                    "dns01_challenge": {
                        "provider": "cloudflare", 
                        "api_token": "${TLS_TOKEN}"
                    }
                }
            },
            "multiplex": {
                "enabled": true, 
                "padding": true, 
                "brutal": {
                    "enabled": ${WS_BRUTAL}, 
                    "up_mbps": 1000, 
                    "down_mbps": 1000
                }
            }
        }
    ]
}
EOF

    chmod 600 /etc/sing-box/*.json 2>/dev/null || true
}

# ---------- 安装 sing-box ----------
install_sing_box() {
    echo "=== 检测系统类型并安装 sing-box ==="
    [ "$(id -u)" -ne 0 ] && { echo "请使用 root 用户运行此脚本。"; return 1; }

    . /etc/os-release
    OS_ID=$(echo "$ID" | tr '[:upper:]' '[:lower:]')

    if command -v sing-box >/dev/null 2>&1; then
        echo "✅ 已安装 sing-box：$(sing-box version 2>/dev/null | head -n 1)"
        return 0
    fi

    case "$OS_ID" in
        debian|ubuntu)
            curl -fsSL https://sing-box.app/install.sh | sh ;;
        alpine)
            echo "http://dl-cdn.alpinelinux.org/alpine/edge/main" >> /etc/apk/repositories
            echo "http://dl-cdn.alpinelinux.org/alpine/edge/community" >> /etc/apk/repositories
            apk update && apk add sing-box ;;
        *)
            echo "不支持的系统类型：$OS_ID"; return 1 ;;
    esac

    command -v sing-box >/dev/null 2>&1 && echo "✅ 安装成功" || { echo "❌ 安装失败"; return 1; }
}

# ---------- 启动 sing-box ----------
start_sing_box() {
    echo "=== 启动 sing-box 服务 ==="
    if [ ! -d /etc/sing-box ] || [ -z "$(find /etc/sing-box -maxdepth 1 -name '*.json' -print -quit)" ]; then
        echo "❌ 未找到配置文件片段 (/etc/sing-box/*.json)"
        exit 1
    fi
    . /etc/os-release
    OS_ID=$(echo "$ID" | tr '[:upper:]' '[:lower:]')
    case "$OS_ID" in
        debian|ubuntu)
            systemctl daemon-reload
            systemctl enable sing-box --now
            systemctl restart sing-box
            systemctl status sing-box --no-pager ;;
        alpine)
            rc-update add sing-box default
            rc-service sing-box restart
            rc-service sing-box status ;;
        *)
            echo "未知系统类型，请手动运行：sing-box run" ;;
    esac
}

# ---------- 分享链接 ----------
generate_share_links() {
    mkdir -p ${WORK_DIR}/list

    # 自动为 IPv6 添加双引号，不修改已有的中括号格式
    if [[ "$VPS_IP_FORMATTED" == *:* && "$VPS_IP_FORMATTED" != *.* ]]; then
        MIHOMO_SERVER="\"${VPS_IP_FORMATTED}\""
    else
        MIHOMO_SERVER="$VPS_IP_FORMATTED"
    fi

    HY2_UUID_ENC=$(printf '%s' "$HY2_UUID" | sed 's/\//%2F/g; s/+/%2B/g; s/=/%3D/g')

    # 统一使用 /root/list
    cat > ${WORK_DIR}/list/singbox <<EOF
vless://${REALITY_UUID}@${VPS_IP_FORMATTED}:${REALITY_PORT}?security=reality&sni=${REALITY_DOMAIN}&fp=firefox&pbk=${REALITY_PUBLIC_KEY}&type=tcp&flow=xtls-rprx-vision&packetEncoding=xudp&encryption=none#${VPS_NAME}-reality
hy2://${HY2_UUID_ENC}@${VPS_IP_FORMATTED}:${HY2_PORT}?sni=${TLS_VPS}#${VPS_NAME}-hy2
vless://${WS_UUID}@${DOMAIN_CDN}:8443?security=tls&sni=${TLS_VPS}&fp=firefox&type=ws&path=${WS_PATH}&host=${TLS_VPS}&mux=false&packetEncoding=xudp&encryption=none#${VPS_NAME}-wsa
vless://${WS_UUID}@${DOMAIN_CDN}:8443?security=tls&sni=${TLS_VPS}&fp=firefox&type=ws&path=${WS_PATH}&host=${TLS_VPS}&mux=false&packetEncoding=xudp&encryption=none#${VPS_NAME}-wss
EOF

    echo "========== Generated Share Links (singbox) =========="
    cat ${WORK_DIR}/list/singbox
    echo "====================================================="

    cat > ${WORK_DIR}/list/mihomo <<EOF
proxies:
  - type: vless
    name: ${VPS_NAME}-reality
    server: ${MIHOMO_SERVER}
    port: ${REALITY_PORT}
    uuid: ${REALITY_UUID}
    network: tcp
    servername: ${REALITY_DOMAIN}
    tls: true
    encryption: none
    reality-opts:
      public-key: ${REALITY_PUBLIC_KEY}
    client-fingerprint: firefox
    flow: xtls-rprx-vision

  - type: hysteria2
    name: ${VPS_NAME}-hy2
    server: ${MIHOMO_SERVER}
    port: ${HY2_PORT}
    password: ${HY2_UUID}
    sni: ${TLS_VPS}
  
  - type: vless
    name: ${VPS_NAME}-wsa
    server: ${DOMAIN_CDN}
    port: 8443
    uuid: ${WS_UUID}
    network: ws
    servername: ${TLS_VPS}
    tls: true
    encryption: none
    ws-opts:
      path: ${WS_PATH}
      headers:
        Host: ${TLS_VPS}
    client-fingerprint: firefox
  
  - type: vless
    name: ${VPS_NAME}-wss
    server: ${DOMAIN_CDN}
    port: 8443
    uuid: ${WS_UUID}
    network: ws
    servername: ${TLS_VPS}
    tls: true
    encryption: none
    ws-opts:
      path: ${WS_PATH}
      headers:
        Host: ${TLS_VPS}
    client-fingerprint: firefox
EOF

    echo "========== Generated Clash/Mihomo File (mihomo) =========="
    cat ${WORK_DIR}/list/mihomo
    echo "=========================================================="
}

############################################
# 主程序
############################################
main() {
    # 1. 安装依赖和 sing-box
    install_dependencies
    install_sing_box
    
    # 2. 生成所有配置值（UUID, 密钥, 路径等）
    generate_config_values
    
    # 3. 确保配置目录存在
    mkdir -p /etc/sing-box
    
    # 4. 生成拆分后的配置文件片段（直接写入 /etc/sing-box/）
    generate_config_json
    
    # 5. 启动 sing-box 服务（OpenRC 会自动使用 -C /etc/sing-box）
    start_sing_box
    
    # 6. 生成分享链接（mihomo / sing-box）
    generate_share_links
}

main



