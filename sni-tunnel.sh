cat << 'EOF' > sni-tunnel.sh
#!/usr/bin/env bash
# ==============================================================================
# Project: SNI-Spoof-Tunnel
# Author: Amirwixa
# Description: Automated DPI Bypass Tunnel using TCP Sequence SNI Spoofing
# Target: VPS 1 (Relay Server) -> Cloudflare CDN -> VPS 2 (Hiddify / Xray)
# License: MIT
# ==============================================================================

set -e

APP_DIR="/opt/sni-spoof"
BIN_PATH="$APP_DIR/sni-spoof-rs"
CONFIG_PATH="$APP_DIR/config.json"
SERVICE_PATH="/etc/systemd/system/sni-spoof.service"
SERVICE_NAME="sni-spoof"
CLI_LINK="/usr/local/bin/sni-tunnel"

# Terminal Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}[Error] Please run this script as root (sudo).${NC}"
  exit 1
fi

CF_IP_LIST=(
  "104.16.132.229" "104.16.133.229" "104.17.147.22" "104.18.25.10"
  "104.19.155.100" "172.67.139.236" "172.67.182.201" "162.159.152.4"
  "104.21.45.10"   "104.26.10.15"   "141.101.120.15" "104.16.249.249"
  "104.17.70.206"  "172.67.74.152"  "162.159.138.6"  "104.22.4.15"
  "104.24.10.10"   "104.27.150.12"  "172.64.80.1"    "104.18.32.7"
)

FAKE_SNI_LIST=(
  "telewebion.com"
  "samt.ir"
  "security.vercel.com"
  "speedtest.net"
  "mci.ir"
  "irancell.ir"
  "digikala.com"
  "rubika.ir"
  "shad.ir"
)

install_dependencies() {
  echo -e "${CYAN}[*] Checking and installing dependencies...${NC}" >&2
  apt-get update -y -q >/dev/null 2>&1 || true
  apt-get install -y -q curl wget jq dnsutils iproute2 iptables gawk >/dev/null 2>&1 || true
}

get_public_ip() {
  curl -s4 --connect-timeout 3 https://api.ipify.org 2>/dev/null || \
  curl -s4 --connect-timeout 3 https://icanhazip.com 2>/dev/null || \
  hostname -I | awk '{print $1}'
}

download_binary() {
  if [ -f "$BIN_PATH" ]; then
    return 0
  fi
  mkdir -p "$APP_DIR"
  echo -e "${CYAN}[*] Downloading latest sni-spoof-rs binary...${NC}" >&2
  local url="https://github.com/therealaleph/sni-spoofing-rust/releases/download/v1.0.2/sni-spoof-rs-linux-amd64"
  if ! wget -q "$url" -O "$BIN_PATH"; then
    echo -e "${YELLOW}[!] Fallback to static musl build...${NC}" >&2
    wget -q "https://github.com/therealaleph/sni-spoofing-rust/releases/download/v1.0.2/sni-spoof-rs-linux-amd64-musl" -O "$BIN_PATH"
  fi
  chmod +x "$BIN_PATH"
  echo -e "${GREEN}[+] Binary installed successfully at $BIN_PATH${NC}" >&2
}

find_best_cf_ip() {
  local domain="$1"
  local candidates=("${CF_IP_LIST[@]}")

  if [ -n "$domain" ]; then
    echo -e "${CYAN}[*] Resolving Anycast IPs for domain: $domain ...${NC}" >&2
    local domain_ips
    domain_ips=$(dig +short "$domain" A 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' || true)
    if [ -n "$domain_ips" ]; then
      for dip in $domain_ips; do
        candidates=("$dip" "${candidates[@]}")
      done
    fi
  fi

  echo -e "\n${YELLOW}[*] Testing TCP handshakes and measuring latencies to Cloudflare IPs...${NC}" >&2
  local best_ip=""
  local best_time=999999

  for ip in "${candidates[@]}"; do
    local time_sec
    time_sec=$(curl -so /dev/null -w "%{time_connect}" --connect-timeout 2 "https://$ip:443" -k 2>/dev/null || echo "0")
    
    local ms
    ms=$(awk -v t="$time_sec" 'BEGIN {
      gsub(/[^0-9.]/, "", t);
      if (t != "" && (t + 0) > 0.0001) {
        printf "%d", (t + 0) * 1000
      } else {
        print 0
      }
    }')

    if [ "$ms" -gt 0 ]; then
      echo -e "  [${GREEN}REACHABLE${NC}] $ip:443 - Latency: ${GREEN}${ms}ms${NC}" >&2
      if [ "$ms" -lt "$best_time" ]; then
        best_time=$ms
        best_ip=$ip
      fi
    else
      echo -e "  [${RED}BLOCKED / TIMEOUT${NC}] $ip:443" >&2
    fi
  done

  if [ -z "$best_ip" ]; then
    echo -e "${RED}[!] Warning: No open IPs detected. Using safe default.${NC}" >&2
    best_ip="104.16.132.229"
  else
    echo -e "\n${GREEN}[+] Fastest reachable IP: ${BOLD}$best_ip${NC} (${best_time}ms)\n" >&2
  fi

  printf "%s" "$best_ip"
}

find_best_fake_sni() {
  echo -e "${YELLOW}[*] Selecting working Fake SNI candidate...${NC}" >&2
  for sni in "${FAKE_SNI_LIST[@]}"; do
    if curl -s -I --connect-timeout 2 "https://$sni" >/dev/null 2>&1; then
      echo -e "  [${GREEN}VALID${NC}] $sni" >&2
      printf "%s" "$sni"
      return 0
    else
      echo -e "  [${YELLOW}SKIPPED${NC}] $sni" >&2
    fi
  done
  printf "%s" "telewebion.com"
}

write_config() {
  local listen_port="${1:-443}"
  local connect_ip="${2:-104.16.132.229}"
  local fake_sni="${3:-telewebion.com}"

  mkdir -p "$APP_DIR"
  cat <<EOF > "$CONFIG_PATH"
{
  "graceful_shutdown_sec": 0,
  "listeners": [
    {
      "listen": "0.0.0.0:$listen_port",
      "connect": "$connect_ip:443",
      "fake_sni": "$fake_sni",
      "conn_timeout_sec": 6,
      "handshake_timeout_sec": 3,
      "keepalive_time_sec": 11,
      "keepalive_interval_sec": 2
    }
  ]
}
EOF
  echo -e "${GREEN}[+] Configuration written to $CONFIG_PATH${NC}" >&2
}

install_systemd_service() {
  download_binary
  cat <<EOF > "$SERVICE_PATH"
[Unit]
Description=SNI Spoofing Rust DPI Bypass Tunnel
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$APP_DIR
ExecStart=$BIN_PATH $CONFIG_PATH
Restart=always
RestartSec=3
LimitNOFILE=65535
AmbientCapabilities=CAP_NET_RAW CAP_NET_ADMIN

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable "$SERVICE_NAME" >/dev/null 2>&1 || true
  systemctl restart "$SERVICE_NAME"
  echo -e "${GREEN}[+] Systemd service registered and started successfully.${NC}" >&2
}

auto_setup_flow() {
  install_dependencies
  download_binary

  echo -e "\n${BOLD}${BLUE}=== Setup Tunnel Configuration ===${NC}"
  read -rp "Enter listen port on VPS 1 [Default: 443]: " user_port
  user_port=${user_port:-443}

  read -rp "Enter your Hiddify CDN Domain (Optional, press Enter to skip): " user_domain

  if command -v ufw >/dev/null 2>&1; then
    ufw allow "$user_port"/tcp >/dev/null 2>&1 || true
  fi
  iptables -I INPUT -p tcp --dport "$user_port" -j ACCEPT 2>/dev/null || true

  local best_ip
  best_ip=$(find_best_cf_ip "$user_domain")
  
  local best_sni
  best_sni=$(find_best_fake_sni)

  write_config "$user_port" "$best_ip" "$best_sni"
  install_systemd_service

  if [ ! -f "$CLI_LINK" ]; then
    cp "$0" "$CLI_LINK" 2>/dev/null || true
    chmod +x "$CLI_LINK" 2>/dev/null || true
  fi

  local vps_ip
  vps_ip=$(get_public_ip)

  echo -e "\n${BOLD}${GREEN}======================================================${NC}"
  echo -e "${BOLD}${GREEN}        Tunnel Deployed Successfully! 🚀             ${NC}"
  echo -e "${BOLD}${GREEN}======================================================${NC}"
  echo -e " VPS 1 Relay IP:   ${YELLOW}$vps_ip${NC}"
  echo -e " Listen Port:      ${YELLOW}$user_port${NC}"
  echo -e " Upstream Target:  ${YELLOW}$best_ip:443${NC}"
  echo -e " Injected Fake SNI:${YELLOW}$best_sni${NC}"
  echo -e "------------------------------------------------------"
  echo -e "${CYAN}How to update client VLESS configs:${NC}"
  echo -e " In your client app (v2rayNG / Hiddify / Sing-box / FoXray):"
  echo -e "  1. Change ${BOLD}Server Address / IP${NC} to: ${YELLOW}$vps_ip${NC}"
  echo -e "  2. Change ${BOLD}Server Port${NC} to:         ${YELLOW}$user_port${NC}"
  echo -e "  3. Leave ${BOLD}SNI and Host Header${NC} as:   ${RED}your original CDN domain${NC}"
  echo -e "------------------------------------------------------\n"
}

action_scan_update_ip() {
  install_dependencies
  download_binary

  echo -e "${CYAN}[*] Starting Cloudflare Anycast IP scanner...${NC}"
  read -rp "Scan a specific domain? (Press Enter to scan default ranges): " user_domain
  
  local best_ip
  best_ip=$(find_best_cf_ip "$user_domain")

  local current_port="443"
  local current_sni="telewebion.com"

  if [ -f "$CONFIG_PATH" ]; then
    current_port=$(jq -r '.listeners[0].listen' "$CONFIG_PATH" 2>/dev/null | cut -d':' -f2 || echo "443")
    current_sni=$(jq -r '.listeners[0].fake_sni' "$CONFIG_PATH" 2>/dev/null || echo "telewebion.com")
  fi
  current_port=${current_port:-443}
  current_sni=${current_sni:-telewebion.com}

  write_config "$current_port" "$best_ip" "$current_sni"
  install_systemd_service
  echo -e "\n${GREEN}[+] Switched to new clean IP: $best_ip${NC}"
}

action_change_sni() {
  if [ ! -f "$CONFIG_PATH" ]; then
    echo -e "${RED}[Error] Config not found. Run option 1 first.${NC}"
    return
  fi

  echo -e "\n${CYAN}Select a Fake SNI candidate:${NC}"
  local i=1
  for s in "${FAKE_SNI_LIST[@]}"; do
    echo "  $i) $s"
    ((i++))
  done
  echo "  0) Enter custom domain"
  read -rp "Select option [1-${#FAKE_SNI_LIST[@]}]: " choice

  local selected_sni="telewebion.com"
  if [ "$choice" -ge 1 ] && [ "$choice" -le "${#FAKE_SNI_LIST[@]}" ]; then
    selected_sni="${FAKE_SNI_LIST[$((choice-1))]}"
  elif [ "$choice" == "0" ]; then
    read -rp "Enter custom Fake SNI: " selected_sni
  fi

  local current_port current_ip
  current_port=$(jq -r '.listeners[0].listen' "$CONFIG_PATH" | cut -d':' -f2)
  current_ip=$(jq -r '.listeners[0].connect' "$CONFIG_PATH" | cut -d':' -f1)

  write_config "$current_port" "$current_ip" "$selected_sni"
  install_systemd_service
  echo -e "\n${GREEN}[+] Fake SNI updated to $selected_sni${NC}"
}

action_live_debug() {
  echo -e "${YELLOW}[*] Pausing background service for live interactive debugging...${NC}"
  systemctl stop "$SERVICE_NAME" 2>/dev/null || true

  echo -e "${CYAN}======================================================${NC}"
  echo -e "${CYAN}  Live packet injection viewer active (DEBUG mode).   ${NC}"
  echo -e "${CYAN}  Connect with your client now to observe traffic.    ${NC}"
  echo -e "${CYAN}  Press [Ctrl + C] to exit and resume the service.     ${NC}"
  echo -e "${CYAN}======================================================${NC}\n"

  RUST_LOG=debug "$BIN_PATH" "$CONFIG_PATH" || true

  echo -e "\n${YELLOW}[*] Resuming background systemd service...${NC}"
  systemctl start "$SERVICE_NAME"
  echo -e "${GREEN}[+] Background service resumed.${NC}"
}

action_convert_vless() {
  local vps_ip
  vps_ip=$(get_public_ip)
  local current_port="443"
  if [ -f "$CONFIG_PATH" ]; then
    current_port=$(jq -r '.listeners[0].listen' "$CONFIG_PATH" 2>/dev/null | cut -d':' -f2 || echo "443")
  fi

  echo -e "\n${CYAN}Paste your original CDN VLESS link from Hiddify:${NC}"
  read -rp "Original Link: " orig_link

  if [[ "$orig_link" =~ ^vless://([^@]+)@([^:]+):([0-9]+)(\?.*)$ ]]; then
    local uuid="${BASH_REMATCH[1]}"
    local rest="${BASH_REMATCH[4]}"
    local new_link="vless://${uuid}@${vps_ip}:${current_port}${rest}"

    echo -e "\n${GREEN}Converted Client Link (Points to VPS 1 Relay):${NC}"
    echo -e "${YELLOW}$new_link${NC}\n"
  else
    echo -e "${RED}[Error] Invalid VLESS URI format!${NC}"
  fi
}

action_uninstall() {
  echo -e "${RED}Are you sure you want to completely remove SNI-Spoof-Tunnel? [y/N]: ${NC}"
  read -rp "" confirm
  if [[ "$confirm" =~ ^[Yy]$ ]]; then
    systemctl stop "$SERVICE_NAME" 2>/dev/null || true
    systemctl disable "$SERVICE_NAME" 2>/dev/null || true
    rm -f "$SERVICE_PATH"
    systemctl daemon-reload
    rm -rf "$APP_DIR"
    rm -f "$CLI_LINK"
    echo -e "${GREEN}[+] All files and services uninstalled successfully.${NC}"
    exit 0
  fi
}

menu() {
  while true; do
    clear
    echo -e "${BOLD}${CYAN}======================================================${NC}"
    echo -e "${BOLD}${CYAN}       🚀 SNI-Spoof-Tunnel CLI Manager (VPS 1)        ${NC}"
    echo -e "${BOLD}${CYAN}======================================================${NC}"
    
    if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
      echo -e " Service Status: ${GREEN}● Active & Running${NC}"
    else
      echo -e " Service Status: ${RED}○ Inactive / Not Installed${NC}"
    fi

    echo -e "------------------------------------------------------"
    echo -e " ${BOLD}1)${NC} ${GREEN}Auto Install & Setup (One-Click Deployment)${NC}"
    echo -e " ${BOLD}2)${NC} Scan & Switch to Fastest Cloudflare Clean IP"
    echo -e " ${BOLD}3)${NC} Change Fake SNI Candidate"
    echo -e " ${BOLD}4)${NC} ${YELLOW}Live Packet Debug Mode (Inspect Handshakes)${NC}"
    echo -e " ${BOLD}5)${NC} View Live Service Logs"
    echo -e " ${BOLD}6)${NC} View Status & Configuration"
    echo -e " ${BOLD}7)${NC} Restart Service"
    echo -e " ${BOLD}8)${NC} Convert Hiddify VLESS Link"
    echo -e " ${BOLD}9)${NC} ${RED}Uninstall Everything${NC}"
    echo -e " ${BOLD}0)${NC} Exit"
    echo -e "------------------------------------------------------"
    read -rp "Please enter an option [0-9]: " opt

    case "$opt" in
      1) auto_setup_flow; read -rp "Press Enter to return to menu...";;
      2) action_scan_update_ip; read -rp "Press Enter...";;
      3) action_change_sni; read -rp "Press Enter...";;
      4) action_live_debug; read -rp "Press Enter...";;
      5) journalctl -u "$SERVICE_NAME" -f -n 30;;
      6) systemctl status "$SERVICE_NAME" --no-pager || true; [ -f "$CONFIG_PATH" ] && cat "$CONFIG_PATH"; read -rp "Press Enter...";;
      7) systemctl restart "$SERVICE_NAME" && echo -e "${GREEN}Service restarted.${NC}"; sleep 1;;
      8) action_convert_vless; read -rp "Press Enter...";;
      9) action_uninstall;;
      0) exit 0;;
      *) echo -e "${RED}Invalid option!${NC}"; sleep 1;;
    esac
  done
}

case "$1" in
  install) auto_setup_flow;;
  scan)    action_scan_update_ip;;
  debug)   action_live_debug;;
  status)  systemctl status "$SERVICE_NAME" --no-pager;;
  restart) systemctl restart "$SERVICE_NAME";;
  logs)    journalctl -u "$SERVICE_NAME" -f -n 30;;
  *)       menu;;
esac
EOF
