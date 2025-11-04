# PVE-Cellular-failover
A bash script to get access to PVE via Zerotier in case main connection fails

#############################

# 📡 4G Failover Script for Proxmox VE

**Version**: 2.0  
**Date**: December 2024  
**Author**: Automatic 4G failover script for Internet outages  
**Environment**: Proxmox VE with 4G USB modem and ZeroTier

---

## 📖 Table of Contents

1. [General Principle](#-general-principle)  
2. [Network Architecture](#-network-architecture)  
3. [Requirements](#-requirements)  
4. [Installation](#-installation)  
5. [Configuration](#-configuration)  
6. [Detailed Operation](#-detailed-operation)  
7. [Technical Documentation](#-technical-documentation)  
8. [Port Forwarding vs MASQUERADE](#-port-forwarding-vs-masquerade)  
9. [Maintenance](#-maintenance)  
10. [Troubleshooting](#-troubleshooting)  
11. [Future Notes](#-future-notes)

---

## 🎯 General Principle

This script ensures **high availability** of a Proxmox VE server by automatically switching to a 4G connection if the main Internet router becomes unreachable.

### How It Works

```
┌─────────────────────────────────────────────────────────────┐
│                    Normal Conditions                        │
│                                                             │
│  [VM/LXC] ──→ [Host PVE] ──→ [Internet Box] ──→ Internet  │
│                     ↓                                        │
│                 [4G Key]  (standby, blocked)                │
└─────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────┐
│                    Internet Box DOWN                        │
│                                                             │
│  [VM/LXC] ──→ [Host PVE] ──→ [4G Key] ──→ Internet        │
│                     ↑                                        │
│                 Automatic failover                          │
│                 + Telegram notification                     │
│                 + PBS backups disabled                      │
└─────────────────────────────────────────────────────────────┘
```

### Key Features

- ✅ **Automatic failover** — Detects loss of main Internet and switches to 4G  
- ✅ **Automatic recovery** — Reverts to the main box when back online  
- ✅ **Data saving** — Keeps 4G blocked in standby, disables PBS backups  
- ✅ **Monitoring** — Periodic 4G test even when idle, data usage alerts  
- ✅ **Remote access** — Services available via ZeroTier when on 4G  
- ✅ **Notifications** — Telegram alerts for all events  
- ✅ **Security** — Only critical machines are allowed to use 4G

---

## 🏗️ Network Architecture

### Networks

| Network | Description | Gateway |
|----------|-------------|----------|
| `192.168.2.0/24` | Main LAN (box) | 192.168.2.254 |
| `192.168.8.0/24` | 4G modem network | 192.168.8.1 |
| `192.168.12.0/24` | ZeroTier (VPN) | - |

### Machines

| Machine | Local IP | ZeroTier IP | Role |
|----------|-----------|--------------|------|
| **Proxmox Host** | 192.168.2.28 | 192.168.12.28 | Main server, router |
| **NGINX Proxy** | 192.168.2.33 | - | Reverse proxy (port 81) |
| **Home Assistant** | 192.168.2.29 | - | Home automation (port 8123) |
| **PBS** | 192.168.2.25 | - | Backup server |
| **Debian GUI** | 192.168.2.39 | - | Modem management GUI |
| **4G Key** | 192.168.8.100 | - | Failover interface |
| **Remote Client** | - | 192.168.12.50 | Smartphone/PC (ZT test) |

---

## 🔧 Requirements

### Hardware

- ✅ Proxmox VE server (tested on PVE 7.x / 8.x)  
- ✅ 4G USB modem (e.g., Huawei E3372)  
- ✅ SIM card with active data plan  
- ✅ Internet box with Ethernet connection

### Software

```bash
# Required packages
apt install -y iptables jq vnstat wget netcat-openbsd curl

# ZeroTier (for remote access)
curl -s https://install.zerotier.com | bash
zerotier-cli join <NETWORK_ID>
```

### System Configuration

```bash
# 1. Enable IP forwarding
sysctl -w net.ipv4.ip_forward=1
echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf

# 2. Identify 4G interface
ip link show
# Look for an interface starting with "enx" or "usb"

# 3. Configure ZeroTier Central
# https://my.zerotier.com
# - Create a network
# - Add managed route: 192.168.2.0/24 via 192.168.12.28
# - Authorize members (check “Auth”)
```

---

## 📥 Installation

### Step 1: Download the script

```bash
mkdir -p /usr/local/bin
nano /usr/local/bin/4g-failover.sh
# Paste script content
chmod +x /usr/local/bin/4g-failover.sh
```

### Step 2: Configuration

```bash
nano /etc/4g-failover.conf
```

(Minimal example config shown above...)

