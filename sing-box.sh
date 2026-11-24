#!/bin/bash
set -euo pipefail

############################################
# 依赖安装：curl + vim
############################################
install_dependencies() {
    echo "=== 检查并安装依赖 (vim, curl) ==="

    if [[ $EUID -ne 0 ]]; then
        echo "[ERROR] 此脚本需要 root 用户运行"
        return 1
    fi

    local deps=("vim" "curl" "ca-certificates")

    if command -v apt-get >/dev/null 2>&1; then
        apt-get update
        apt-get install -y "${deps[@]}"

    elif command -v apk >/dev/null 2>&1; then
        apk update
        apk add "${deps[@]}"

    else
        echo "[WARNING] 未知系统类型，请手动安装：vim curl ca-certificates"
        return 1
    fi

    echo "=== 依赖安装完毕 ==="
}

############################################
# 用户自定义参数
############################################
VPS_NAME=${VPS_NAME:-"myserver"}

WORK_DIR=${WORK_DIR:-"/home/sing-box"}

STRATEGY=${STRATEGY:-"prefer_ipv4"}
AI_OUT=${AI_OUT:-"direct-out"}
RD_OUT=${RD_OUT:-"direct-out"}

REALITY_PORT=${REALITY_PORT:-443}
REALITY_DOMAIN=${REALITY_DOMAIN:-"addons.mozilla.org"}

HY2_PORT=${HY2_PORT:-8553}
WS_PORT=${WS_PORT:-8443}
SN6_PORT=${SN6_PORT:-9443}

WS_BRUTAL=${WS_BRUTAL:-false}

SN6_MODE=${SN6_MODE:-"default"}

TLS_VPS=${TLS_VPS:-"vps.example.com"}
TLS_EMAIL=${TLS_EMAIL:-"vps@example.com"}
TLS_TOKEN=${TLS_TOKEN:-"your_cf_token"}

DOMAIN_CDN=${DOMAIN_CDN:-"www.visa.com.sg"}

############################################
# 辅助函数
############################################

get_vps_ip() {
    local ip=""

    if command -v curl >/dev/null 2>&1; then
        ip=$(curl -4 -fsS --connect-timeout 5 \
            https://one.one.one.one/cdn-cgi/trace 2>/dev/null |
            awk -F= '$1=="ip" {print $2; exit}')

        if [[ -z "$ip" ]]; then
            ip=$(curl -6 -fsS --connect-timeout 5 \
                https://one.one.one.one/cdn-cgi/trace 2>/dev/null |
                awk -F= '$1=="ip" {print $2; exit}')
        fi
    fi

    if [[ -z "$ip" ]]; then
        ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    fi

    [[ -n "$ip" ]] || {
        echo "❌ 无法获取 VPS IP" >&2
        return 1
    }

    echo "$ip"
}

format_ip_for_url() {
    local ip="$1"

    if [[ "$ip" == *:* ]]; then
        echo "[$ip]"
    else
        echo "$ip"
    fi
}

version_ge() {
    local current="$1"
    local required="$2"

    awk -v current="$current" -v required="$required" '
    BEGIN {
        split(current, a, ".")
        split(required, b, ".")

        for (i = 1; i <= 3; i++) {
            if (a[i] == "") a[i] = 0
            if (b[i] == "") b[i] = 0

            if (a[i] + 0 > b[i] + 0) exit 0
            if (a[i] + 0 < b[i] + 0) exit 1
        }

        exit 0
    }'
}

############################################
# 生成配置值
############################################

generate_config_values() {
    echo "=== 生成配置参数 ==="

    REALITY_UUID=$(sing-box generate uuid)
    WS_UUID=$(sing-box generate uuid)

    WS_PATH="/${WS_UUID##*-}"

    echo "生成 Reality X25519 密钥对..."

    local keypair
    keypair=$(sing-box generate reality-keypair)

    REALITY_PRIVATE_KEY=$(echo "$keypair" |
        awk '/PrivateKey/ {print $2}')

    REALITY_PUBLIC_KEY=$(echo "$keypair" |
        awk '/PublicKey/ {print $2}')

    [[ -n "$REALITY_PRIVATE_KEY" && -n "$REALITY_PUBLIC_KEY" ]] || {
        echo "❌ Reality 密钥生成失败"
        return 1
    }

    echo "生成 Hy2 密码..."
    HY2_UUID=$(sing-box generate rand 16 --base64)

    echo "生成 Snell PSK..."
    SN6_UUID=$(sing-box generate rand 32 --hex)

    echo "获取 VPS IP..."
    VPS_IP=$(get_vps_ip) || return 1

    # 原始 IP：用于 JSON / YAML
    VPS_IP_RAW="$VPS_IP"

    # URL 格式：IPv6 自动加方括号
    VPS_IP_URL=$(format_ip_for_url "$VPS_IP")

    # Mihomo YAML 格式：IPv6 使用引号，不加方括号
    MIHOMO_SERVER="$VPS_IP_RAW"

    if [[ "$VPS_IP_RAW" == *:* ]]; then
        MIHOMO_SERVER="\"${VPS_IP_RAW}\""
    fi

    # 参数校验
    if [[ "$WS_BRUTAL" != "true" && "$WS_BRUTAL" != "false" ]]; then
        echo "❌ WS_BRUTAL 只能设置为 true 或 false"
        return 1
    fi

    case "$SN6_MODE" in
        default|unshaped|unsafe-raw)
            ;;
        *)
            echo "❌ SN6_MODE 不合法"
            return 1
            ;;
    esac

    echo "VPS IP: $VPS_IP_RAW"
}

############################################
# 生成配置文件
############################################

generate_config_json() {
    echo "=== 生成 sing-box 配置 ==="

    mkdir -p /etc/sing-box
    mkdir -p "${WORK_DIR}"

    chown -R root:root /etc/sing-box "${WORK_DIR}"
    chmod 750 /etc/sing-box "${WORK_DIR}"

    umask 077

    ########################################
    # 00_log
    ########################################

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

    ########################################
    # 01_outbounds
    ########################################

    cat > /etc/sing-box/01_outbounds.json << EOF
{
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct-out",
      "domain_resolver": {
        "server": "local-dns",
        "rewrite_ttl": 60,
        "client_subnet": "8.8.8.8"
      }
    }
  ]
}
EOF

    ########################################
    # 02_endpoints
    ########################################

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

    ########################################
    # 03_http_clients
    ########################################

    cat > /etc/sing-box/03_http-clients.json << EOF
{
  "http_clients": [
    {
      "tag": "rule-set-http",
      "detour": "direct-out"
    }
  ]
}
EOF

    ########################################
    # 04_route
    ########################################

    cat > /etc/sing-box/04_route.json << EOF
{
  "route": {
    "default_domain_resolver": {
      "server": "local-dns",
      "rewrite_ttl": 60,
      "client_subnet": "8.8.8.8"
    },
    "rule_set": [
      {
        "tag": "geosite-gemini",
        "type": "remote",
        "format": "binary",
        "url": "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-google-gemini.srs",
        "http_client": "rule-set-http"
      },
      {
        "tag": "geosite-reddit",
        "type": "remote",
        "format": "binary",
        "url": "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-reddit.srs",
        "http_client": "rule-set-http"
      }
    ],
    "rules": [
      {
        "action": "sniff"
      },
      {
        "action": "route",
        "rule_set": [
          "geosite-gemini"
        ],
        "outbound": "${AI_OUT}"
      },
      {
        "action": "route",
        "rule_set": [
          "geosite-reddit"
        ],
        "outbound": "${RD_OUT}"
      }
    ],
    "final": "direct-out"
  }
}
EOF

    ########################################
    # 05_experimental
    ########################################

    cat > /etc/sing-box/05_experimental.json << EOF
{
  "experimental": {
    "cache_file": {
      "enabled": true,
      "path": "${WORK_DIR}/cache.db"
    }
  }
}
EOF

    ########################################
    # 06_dns
    ########################################

    cat > /etc/sing-box/06_dns.json << EOF
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

    ########################################
    # 07_ntp
    ########################################

    cat > /etc/sing-box/07_ntp.json << EOF
{
  "ntp": {
    "enabled": true,
    "server": "time.apple.com",
    "server_port": 123,
    "interval": "60m"
  }
}
EOF

    ########################################
    # 08_certificate_providers
    ########################################

    cat > /etc/sing-box/08_certificate_providers.json << EOF
{
  "certificate_providers": [
    {
      "type": "acme",
      "tag": "acme-provider",
      "domain": [
        "${TLS_VPS}"
      ],
      "data_directory": "${WORK_DIR}/acme",
      "email": "${TLS_EMAIL}",
      "dns01_challenge": {
        "provider": "cloudflare",
        "api_token": "${TLS_TOKEN}"
      },
      "http_client": "rule-set-http"
    }
  ]
}
EOF

    ########################################
    # 11_vless_reality
    ########################################

    cat > /etc/sing-box/11_vless-reality_inbounds.json << EOF
{
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-reality",
      "listen": "::",
      "listen_port": ${REALITY_PORT},
      "users": [
        {
          "uuid": "${REALITY_UUID}",
          "flow": "xtls-rprx-vision"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "${REALITY_DOMAIN}",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "${REALITY_DOMAIN}",
            "server_port": 443
          },
          "private_key": "${REALITY_PRIVATE_KEY}",
          "short_id": [
            ""
          ]
        }
      },
      "multiplex": {
        "enabled": false,
        "padding": false,
        "brutal": {
          "enabled": false,
          "up_mbps": 1000,
          "down_mbps": 1000
        }
      }
    }
  ]
}
EOF

    ########################################
    # 12_hysteria2
    ########################################

    cat > /etc/sing-box/12_hysteria2_inbounds.json << EOF
{
  "inbounds": [
    {
      "type": "hysteria2",
      "tag": "hy2",
      "listen": "::",
      "listen_port": ${HY2_PORT},
      "users": [
        {
          "password": "${HY2_UUID}"
        }
      ],
      "ignore_client_bandwidth": false,
      "tls": {
        "enabled": true,
        "server_name": "${TLS_VPS}",
        "alpn": [
          "h3"
        ],
        "min_version": "1.3",
        "max_version": "1.3",
        "certificate_provider": "acme-provider"
      }
    }
  ]
}
EOF

    ########################################
    # 13_vless_ws_tls
    ########################################

    cat > /etc/sing-box/13_vless-ws-tls_inbounds.json << EOF
{
  "inbounds": [
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
        "certificate_provider": "acme-provider"
      },
      "multiplex": {
        "enabled": true,
        "padding": false,
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

    ########################################
    # 14_snell_v6
    ########################################

    cat > /etc/sing-box/14_snell_v6_inbounds.json << EOF
{
  "inbounds": [
    {
      "type": "snell",
      "tag": "snell-in",
      "listen": "::",
      "listen_port": ${SN6_PORT},
      "version": 6,
      "psk": "${SN6_UUID}",
      "mode": "${SN6_MODE}"
    }
  ]
}
EOF

    ########################################
    # 配置文件权限
    ########################################

    chown root:root /etc/sing-box/*.json
    chmod 600 /etc/sing-box/*.json

    echo "=== 配置文件生成完成 ==="
}

############################################
# 安装 sing-box
############################################

install_sing_box() {
    echo "=== 配置并安装 sing-box ==="

    [[ $EUID -eq 0 ]] || {
        echo "[ERROR] 此脚本需要 root 用户运行"
        return 1
    }

    [[ -f /etc/os-release ]] || {
        echo "[ERROR] 无法识别系统类型"
        return 1
    }

    . /etc/os-release
    local OS_ID="${ID,,}"

    case "$OS_ID" in
        debian|ubuntu)
            echo "=== 配置 sing-box 官方 APT 仓库 ==="

            mkdir -p /etc/apt/keyrings

            curl -fsSL https://sing-box.app/gpg.key \
                -o /etc/apt/keyrings/sagernet.asc || {
                echo "[ERROR] 下载 GPG 密钥失败"
                return 1
            }

            chmod 0644 /etc/apt/keyrings/sagernet.asc

            cat > /etc/apt/sources.list.d/sagernet.sources <<'EOF'
Types: deb
URIs: https://deb.sagernet.org/
Suites: *
Components: *
Enabled: yes
Signed-By: /etc/apt/keyrings/sagernet.asc
EOF

            apt-get update
            apt-get install -y sing-box
            ;;

        alpine)
            echo "=== 配置 Alpine APK 仓库 ==="

            local REPO="https://dl-cdn.alpinelinux.org/alpine/edge/community"

            grep -Fqx "$REPO" /etc/apk/repositories ||
                echo "$REPO" >> /etc/apk/repositories

            apk update
            apk add --upgrade sing-box sing-box-openrc
            ;;

        *)
            echo "[ERROR] 不支持的系统类型：$OS_ID"
            return 1
            ;;
    esac

    command -v sing-box >/dev/null 2>&1 || {
        echo "[ERROR] sing-box 安装失败"
        return 1
    }

    local VERSION
    VERSION=$(sing-box version 2>/dev/null |
        awk '{for (i=1;i<=NF;i++) if ($i ~ /^[0-9]+\.[0-9]+\.[0-9]+/) {print $i; exit}}' |
        sed 's/[^0-9.].*$//')

    [[ -n "$VERSION" ]] || {
        echo "[ERROR] 无法识别 sing-box 版本"
        return 1
    }

    echo "当前 sing-box 版本：${VERSION}"

    if ! version_ge "$VERSION" "1.14.0"; then
        echo ""
        echo "[ERROR] 当前版本低于 1.14.0"
        echo "本脚本使用的 Snell v6 和 certificate_providers 要求 sing-box >= 1.14.0"
        echo "请升级 sing-box 后再运行初始化脚本。"
        return 1
    fi

    echo "=== sing-box 安装完成 ==="
    sing-box version
}

############################################
# 启动 sing-box
############################################

start_sing_box() {
    echo "=== 检查 sing-box 配置 ==="

    sing-box check -C /etc/sing-box || {
        echo "❌ 配置检查失败，取消启动"
        return 1
    }

    . /etc/os-release
    local OS_ID="${ID,,}"

    case "$OS_ID" in
        debian|ubuntu)
            echo "=== 启动 systemd 服务 ==="

            systemctl daemon-reload
            systemctl enable sing-box
            systemctl restart sing-box

            systemctl status sing-box --no-pager
            ;;

        alpine)
            echo "=== 配置 OpenRC 服务 ==="

            # 明确指定配置目录，确保加载所有 JSON 片段
            cat > /etc/init.d/sing-box <<'EOF'
#!/sbin/openrc-run

description="sing-box service"

command="/usr/bin/sing-box"
command_args="run -C /etc/sing-box"

command_background=true
pidfile="/run/sing-box.pid"

depend() {
    need net
    after firewall
}
EOF

            chmod 755 /etc/init.d/sing-box

            rc-update add sing-box default

            rc-service sing-box restart ||
                rc-service sing-box start

            rc-service sing-box status
            ;;

        *)
            echo "未知系统类型，无法自动启动服务"
            return 1
            ;;
    esac

    echo "=== sing-box 服务启动完成 ==="
}

############################################
# 生成分享链接
############################################

generate_share_links() {
    echo "=== 生成客户端配置 ==="

    mkdir -p "${WORK_DIR}/list"

    # Hy2 密码 URL 编码
    HY2_UUID_ENC=$(printf '%s' "$HY2_UUID" |
        sed 's/%/%25/g; s/\//%2F/g; s/+/%2B/g; s/=/%3D/g')

    ########################################
    # V2Ray / 通用 URI
    ########################################

    cat > "${WORK_DIR}/list/v2ray" <<EOF
vless://${REALITY_UUID}@${VPS_IP_URL}:${REALITY_PORT}?security=reality&sni=${REALITY_DOMAIN}&fp=firefox&pbk=${REALITY_PUBLIC_KEY}&type=tcp&flow=xtls-rprx-vision&packetEncoding=xudp&encryption=none#${VPS_NAME}-reality
hy2://${HY2_UUID_ENC}@${VPS_IP_URL}:${HY2_PORT}?sni=${TLS_VPS}&alpn=h3#${VPS_NAME}-hy2
snell://${SN6_UUID}@${VPS_IP_RAW}:${SN6_PORT}?version=6&mode=${SN6_MODE}#${VPS_NAME}-snell6
vless://${WS_UUID}@${DOMAIN_CDN}:${WS_PORT}?security=tls&sni=${TLS_VPS}&fp=firefox&type=ws&path=${WS_PATH}&host=${TLS_VPS}&encryption=none#${VPS_NAME}-ws
EOF

    echo "========== Generated Share Links (v2ray) =========="
    cat "${WORK_DIR}/list/v2ray"
    echo "==================================================="

    ########################################
    # sing-box 客户端配置
    ########################################

    cat > "${WORK_DIR}/list/singbox" <<EOF
{ "tag":"${VPS_NAME}-reality","type":"vless","server":"${VPS_IP_RAW}","server_port":${REALITY_PORT},"uuid":"${REALITY_UUID}","flow":"xtls-rprx-vision","tls":{"enabled":true,"server_name":"${REALITY_DOMAIN}","insecure":false,"reality":{"enabled":true,"public_key":"${REALITY_PUBLIC_KEY}"},"utls":{"enabled":true,"fingerprint":"firefox"}}}, 
{ "tag":"${VPS_NAME}-snell6","type":"snell","server":"${VPS_IP_RAW}","server_port":${SN6_PORT},"version":6,"psk":"${SN6_UUID}","mode":"${SN6_MODE}"}, 
{ "tag":"${VPS_NAME}-hy2","type":"hysteria2","server":"${VPS_IP_RAW}","server_port":${HY2_PORT},"password":"${HY2_UUID}","tls":{"enabled":true,"server_name":"${TLS_VPS}","alpn":["h3"],"insecure":false}}, 
{ "tag":"${VPS_NAME}-ws","type":"vless","server":"${DOMAIN_CDN}","server_port":${WS_PORT},"uuid":"${WS_UUID}","tls":{"enabled":true,"server_name":"${TLS_VPS}","insecure":false,"utls":{"enabled":true,"fingerprint":"firefox"}}, 
EOF

    echo "========== Generated sing-box Config =========="
    cat "${WORK_DIR}/list/singbox"
    echo "================================================"

    ########################################
    # Mihomo 配置
    ########################################

    cat > "${WORK_DIR}/list/mihomo" <<EOF
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

  - type: snell
    name: ${VPS_NAME}-snell6
    server: ${MIHOMO_SERVER}
    port: ${SN6_PORT}
    psk: ${SN6_UUID}
    version: 6
    mode: ${SN6_MODE}
    udp: true

  - type: hysteria2
    name: ${VPS_NAME}-hy2
    server: ${MIHOMO_SERVER}
    port: ${HY2_PORT}
    password: ${HY2_UUID}
    sni: ${TLS_VPS}
    alpn:
      - h3

  - type: vless
    name: ${VPS_NAME}-ws
    server: ${DOMAIN_CDN}
    port: ${WS_PORT}
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

    echo "========== Generated Mihomo Config =========="
    cat "${WORK_DIR}/list/mihomo"
    echo "============================================="

    chmod 600 "${WORK_DIR}/list/"*

    echo "=== 客户端配置生成完成 ==="
}

############################################
# 主程序
############################################

main() {
    # 1. 安装依赖
    install_dependencies

    # 2. 安装 sing-box
    install_sing_box

    # 3. 检查必要参数
    if [[ "$TLS_TOKEN" == "your_cf_token" ||
          "$TLS_VPS" == "vps.example.com" ||
          "$TLS_EMAIL" == "vps@example.com" ]]; then
        echo "❌ 请先设置 TLS_VPS、TLS_EMAIL 和 TLS_TOKEN"
        return 1
    fi

    # 4. 生成 UUID、密钥和路径
    generate_config_values

    # 5. 生成配置文件
    generate_config_json

    # 6. 检查并启动服务
    start_sing_box

    # 7. 生成客户端配置
    generate_share_links

    echo ""
    echo "============================================"
    echo " sing-box 初始化完成"
    echo "============================================"
    echo "配置目录：/etc/sing-box"
    echo "工作目录：${WORK_DIR}"
    echo "客户端配置：${WORK_DIR}/list"
    echo ""
    echo "Reality: ${REALITY_PORT}/TCP"
    echo "Hy2:     ${HY2_PORT}/UDP"
    echo "WS:      ${WS_PORT}/TCP"
    echo "Snell6:  ${SN6_PORT}/TCP"
    echo "============================================"
}

main "$@"
