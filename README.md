# VPS_Script
##
Based on Sing-box with Vless-reality, Vless-websockt, Hysteria2 configuration.
## Usage
```bash
curl -fsSL https://raw.githubusercontent.com/Lemon7ProPlus/VPS_Script/main/sb.sh | \
VPS_NAME="myserver" \
PORT_REAL=REALITY_Port \
PORT_WS=Websock_Port \
PORT_HY2=Hysteria2_Port \
DOMAIN_REAL="Reality_Domain" \
DOMAIN_VPS="VPS_Domain" \
TOKEN_CF="CF_Token" \
bash
```

```bash
curl -fsSL https://raw.githubusercontent.com/Lemon7ProPlus/VPS_Script/main/sshwifty.sh | \
DOMAIN=YOUR_SERVER_DOMAIN \
bash
```

```bash
curl -fsSL https://raw.githubusercontent.com/Lemon7ProPlus/VPS_Script/main/hubproxy.sh | \
CUSTOM_DOMAIN=your.domain.com \
bash
```
