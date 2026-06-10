# VPS_Script

## Sing-box
```bash
curl -fsSL https://raw.githubusercontent.com/Lemon7ProPlus/VPS_Script/main/sing-box.sh | \
VPS_NAME="myserver" \
STRATEGY="prefer_ipv4" \
AI_OUT="direct-out" \
REALITY_PORT=REALITY_Port \
REALITY_DOMAIN="Reality_Domain" \
HY2_PORT=Hysteria2_Port \
WS_PORT=Websock_Port \
WS_BRUTAL="false" \
TLS_VPS="VPS_Domain" \
TLS_EMAIL="vps@example.com" \
TLS_TOKEN="CF_Token" \
bash
```
## SSHwifty
```bash
curl -fsSL https://raw.githubusercontent.com/Lemon7ProPlus/VPS_Script/main/sshwifty.sh | \
DOMAIN=YOUR_SERVER_DOMAIN \
PASSWORD=YOUR_PASSWORD \
bash
```
## Hubproxy
```bash
curl -fsSL https://raw.githubusercontent.com/Lemon7ProPlus/VPS_Script/main/hubproxy.sh | \
CUSTOM_DOMAIN=your.domain.com \
bash
```
