#!/bin/bash
# gen_config.sh - 生成 config.json 配置文件并输出分享链接
set -euo pipefail

CONFIG_FILE="config.json"

############################################
# 依赖安装：openssl + vim（根据系统类型自动安装）
############################################
install_dependencies() {
    echo "=== 检查并安装依赖 (vim, openssl) ==="

    if [[ $EUID -ne 0 ]]; then
        echo "[ERROR] 此脚本需要 root 权限运行"
        exit 1
    fi

    local deps=("vim" "openssl")

    if command -v apt >/dev/null 2>&1; then
        apt update -y
        apt install -y "${deps[@]}"

    elif command -v apk >/dev/null 2>&1; then
        apk update
        apk add "${deps[@]}"

    else
        echo "[WARNING] 未知系统类型，请手动安装：vim openssl"
    fi

    echo "=== 依赖安装完毕 ==="
}

# ---------- 用户自定义参数 ----------
VPS_NAME=${VPS_NAME:-"myserver"}
PORT_REAL=${PORT_REAL:-443}
PORT_WS=${PORT_WS:-443}
PORT_HY2=${PORT_HY2:-443}
DOMAIN_REAL=${DOMAIN_REAL:-"addons.mozilla.org"}
DOMAIN_VPS=${DOMAIN_VPS:-"vps.example.com"}
TOKEN_CF=${TOKEN_CF:-"your_cf_token"}
DOMAIN_CDN=${DOMAIN_CDN:-"cf.090227.xyz"}

# ---------- 辅助函数 ----------
urlencode() {
    local raw="$1"
    local length="${#raw}"
    local i c enc=""
    for ((i=0; i<length; i++)); do
        c="${raw:i:1}"
        case "$c" in
            [a-zA-Z0-9.~_-]) enc+="$c" ;;
            *) printf -v hex '%%%02X' "'$c"; enc+="$hex" ;;
        esac
    done
    echo "$enc"
}

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
    echo "生成 Reality X25519 密钥对..."
    TMP_KEY=$(mktemp)
    TMP_PRIV=$(mktemp)
    TMP_PUB=$(mktemp)
    openssl genpkey -algorithm X25519 -out "$TMP_KEY" >/dev/null 2>&1
    openssl pkey -in "$TMP_KEY" -pubout -outform DER 2>/dev/null | tail -c 32 > "$TMP_PUB"
    openssl pkey -in "$TMP_KEY" -outform DER 2>/dev/null | tail -c 32 > "$TMP_PRIV"
    PRIVATE_KEY_REAL=$(base64 < "$TMP_PRIV" | tr '+/' '-_' | tr -d '=')
    PUBLIC_KEY_REAL=$(base64 < "$TMP_PUB" | tr '+/' '-_' | tr -d '=')
    rm -f "$TMP_KEY" "$TMP_PRIV" "$TMP_PUB"

    echo "生成 UUID..."
    if [ -f /proc/sys/kernel/random/uuid ]; then
        UUID_REAL=$(cat /proc/sys/kernel/random/uuid)
        UUID_WS=$(cat /proc/sys/kernel/random/uuid)
    elif command -v uuidgen &>/dev/null; then
        UUID_REAL=$(uuidgen)
        UUID_WS=$(uuidgen)
    else
        UUID_REAL=$(openssl rand -hex 16 | sed 's/\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)/\1\2\3\4-\5\6-\7\8/')
        UUID_WS=$(openssl rand -hex 16 | sed 's/\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)/\1\2\3\4-\5\6-\7\8/')
    fi

    PATH_WS="/${UUID_WS##*-}"

    echo "生成 Hy2 密码..."
    PASSWORD_HY2=$(head -c 16 /dev/urandom | base64)
    PASSWORD_HY2_ENC=$(urlencode "$PASSWORD_HY2")

    echo "获取 VPS IP..."
    VPS_IP=$(get_vps_ip || echo "")
    VPS_IP_FORMATTED=$(format_ip_for_url "$VPS_IP")
    echo
}

# ---------- 生成 config.json ----------
generate_config_json() {
    echo "生成 config.json..."
    cat > "$CONFIG_FILE" << EOF
{
    "log": {
        "disabled": false,
        "level": "info",
        "timestamp": true
    },
    "dns": {
        "rules": [],
        "servers": [
            {
                "type": "local",
                "tag": "local-dns"
            }
        ],
        "strategy": "prefer_ipv4"
    },
    "inbounds": [
        {
            "type": "vless",
            "tag": "vless-reality",
            "listen": "::",
            "listen_port": ${PORT_REAL},
            "tcp_fast_open": true,
            "users": [
                {
                    "uuid": "${UUID_REAL}",
                    "flow": "xtls-rprx-vision"
                }
            ],
            "tls": {
                "enabled": true,
                "server_name": "${DOMAIN_REAL}",
                "reality": {
                    "enabled": true,
                    "handshake": {
                        "server": "${DOMAIN_REAL}",
                        "server_port": 443
                    },
                    "private_key": "${PRIVATE_KEY_REAL}",
                    "short_id": [""]
                }
            }
        },
        {
            "type": "vless",
            "tag": "vless-ws",
            "listen": "::",
            "listen_port": ${PORT_WS},
            "tcp_fast_open": true,
            "users": [
                {
                    "uuid": "${UUID_WS}",
                    "flow": ""
                }
            ],
            "tls": {
                "enabled": true,
                "server_name": "${DOMAIN_VPS}",
                "acme": {
                    "domain": "${DOMAIN_VPS}",
                    "email": "onemoss@outlook.jp",
                    "dns01_challenge": {
                        "provider": "cloudflare",
                        "api_token": "${TOKEN_CF}"
                    }
                }
            },
            "transport": {
                "type": "ws",
                "path": "${PATH_WS}",
                "max_early_data": 2048,
                "early_data_header_name": "Sec-WebSocket-Protocol"
            }
        },
        {
            "type": "hysteria2",
            "tag": "hy2",
            "listen": "::",
            "listen_port": ${PORT_HY2},
            "tcp_fast_open": true,
            "users": [
                {
                    "name": "moss",
                    "password": "${PASSWORD_HY2}"
                }
            ],
            "tls": {
                "enabled": true,
                "server_name": "${DOMAIN_VPS}",
                "acme": {
                    "domain": "${DOMAIN_VPS}",
                    "email": "onemoss@outlook.jp",
                    "dns01_challenge": {
                        "provider": "cloudflare",
                        "api_token": "${TOKEN_CF}"
                    }
                }
            }
        }
    ],
    "outbounds": [
        {
            "type": "direct",
            "tag": "direct-out"
        }
    ],
    "route": {
        "rules": [
            {
                "inbound": [
                    "vless-reality",
                    "hy2",
                    "vless-ws"
                ],
                "outbound": "direct-out"
            }
        ]
    }
}
EOF

    echo "✅ config.json生成完成: $CONFIG_FILE"
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
    [ ! -f /etc/sing-box/config.json ] && { echo "未找到配置文件"; exit 1; }
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
            echo "未知系统类型，请手动运行：sing-box run -c /etc/sing-box/config.json" ;;
    esac
}

# ---------- 分享链接 ----------
generate_share_links() {
    mkdir -p /root/list

    PASSWORD_HY2_ENC=$(printf '%s' "$PASSWORD_HY2" | sed -e 's/\//%2F/g')

    # 统一使用 /root/list（你原脚本路径有误）
    cat >/root/list/singbox <<EOF
vless://${UUID_REAL}@${VPS_IP_FORMATTED}:${PORT_REAL}?security=reality&sni=${DOMAIN_REAL}&fp=firefox&pbk=${PUBLIC_KEY_REAL}&type=tcp&flow=xtls-rprx-vision&packetEncoding=xudp&encryption=none#${VPS_NAME}-reality
hy2://${PASSWORD_HY2_ENC}@${VPS_IP_FORMATTED}:${PORT_HY2}?sni=${DOMAIN_VPS}#${VPS_NAME}-hy2
vless://${UUID_WS}@${DOMAIN_CDN}:8443?security=tls&sni=${DOMAIN_VPS}&fp=firefox&type=ws&path=${PATH_WS}&host=${DOMAIN_VPS}&mux=false&packetEncoding=xudp&encryption=none#${VPS_NAME}-wsa
vless://${UUID_WS}@${DOMAIN_CDN}:8443?security=tls&sni=${DOMAIN_VPS}&fp=firefox&type=ws&path=${PATH_WS}&host=${DOMAIN_VPS}&mux=false&packetEncoding=xudp&encryption=none#${VPS_NAME}-wss
EOF

    echo "========== Generated Share Links (singbox) =========="
    cat /root/list/singbox
    echo "====================================================="

    cat >/root/list/mihomo <<EOF
proxies:
  - type: vless
    name: ${VPS_NAME}-reality
    server: ${VPS_IP_FORMATTED}
    port: ${PORT_REAL}
    uuid: ${UUID_REAL}
    network: tcp
    servername: ${DOMAIN_REAL}
    tls: true
    encryption: none
    reality-opts:
      public-key: ${PUBLIC_KEY_REAL}
    client-fingerprint: firefox
    flow: xtls-rprx-vision

  - type: hysteria2
    name: ${VPS_NAME}-hy2
    server: ${VPS_IP_FORMATTED}
    port: ${PORT_HY2}
    password: ${PASSWORD_HY2}
    sni: ${DOMAIN_VPS}
  
  - type: vless
    name: ${VPS_NAME}-wsa
    server: ${DOMAIN_CDN}
    port: 8443
    uuid: ${UUID_WS}
    network: ws
    servername: ${DOMAIN_VPS}
    tls: true
    encryption: none
    ws-opts:
      path: ${PATH_WS}
      headers:
        Host: ${DOMAIN_VPS}
    client-fingerprint: firefox
  
  - type: vless
    name: ${VPS_NAME}-wss
    server: ${DOMAIN_CDN}
    port: 8443
    uuid: ${UUID_WS}
    network: ws
    servername: ${DOMAIN_VPS}
    tls: true
    encryption: none
    ws-opts:
      path: ${PATH_WS}
      headers:
        Host: ${DOMAIN_VPS}
    client-fingerprint: firefox
EOF

    echo "========== Generated Clash/Mihomo File (mihomo) =========="
    cat /root/list/mihomo
    echo "=========================================================="
}

############################################
# 主程序
############################################
main() {
    install_dependencies
    generate_config_values
    generate_config_json
    
    install_sing_box
    
    echo "=== 安装配置文件到 /etc/sing-box/ ==="
    mkdir -p /etc/sing-box
    install -m 600 "$CONFIG_FILE" /etc/sing-box/config.json
    echo "✅ 已移动到 /etc/sing-box/config.json"
    
    start_sing_box
    generate_share_links
}

main
