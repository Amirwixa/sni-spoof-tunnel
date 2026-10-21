# 🚀 SNI-Spoof-Tunnel

[![Ubuntu](https://img.shields.io/badge/Ubuntu-20.04%20%7C%2022.04%20%7C%2024.04-orange?logo=ubuntu)](https://ubuntu.com)
[![Platform](https://img.shields.io/badge/Platform-Linux%20x86__64-blue)]()
[![DPI-Bypass](https://img.shields.io/badge/DPI%20Bypass-TCP%20Seq%20Spoofing-brightgreen)]()
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

An automated relay tunnel designed to bypass Deep Packet Inspection (DPI) and severe internet filtering by injecting out-of-window fake TLS ClientHello packets with spoofed SNIs.

Ideal for tunneling traffic from a local/bridge server (**VPS 1**) to an unrestricted foreign endpoint (**VPS 2**) fronted by Cloudflare CDN (Hiddify / Xray / Sing-box).

---

## ⚡ Quick One-Line Installation

Run the following command on **VPS 1** (as `root`):

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Amirwixa/sni-spoof-tunnel/main/sni-tunnel.sh)