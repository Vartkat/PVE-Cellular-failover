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
│  [VM/LXC] ──→ [Host PVE] ──→ [Internet Box] ──→ Internet     │
│                     ↓                                        │
│                 [4G Key]  (standby, blocked)                │
└─────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────┐
│                    Internet Box DOWN                        │
│                                                             │
│  [VM/LXC] ──→ [Host PVE] ──→ [4G Key] ──→ Internet           │
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
|---------|-------------|---------|
| `192.168.2.0/24` | Main LAN (box) | 192.168.2.254 |
| `192.168.8.0/24` | 4G modem network | 192.168.8.1 |
| `192.168.12.0/24` | ZeroTier network (VPN) | - |

### Machines

| Machine | Local IP | ZeroTier IP | Role |
|---------|----------|-------------|------|
| **Proxmox Host** | 192.168.2.28 | 192.168.12.28 | Main server, router |
| **NGINX Proxy** | 192.168.2.33 | - | Reverse proxy (port 81) |
| **Home Assistant** | 192.168.2.29 | - | Home automation (port 8123) |
| **PBS** | 192.168.2.25 | - | Backup server |
| **Debian GUI** | 192.168.2.39 | - | Modem management GUI |
| **4G Key** | 192.168.8.100 | - | Failover interface |
| **Remote Client** | - | 192.168.12.50 | Smartphone/PC (ZT test) |

### Full diagram

```
                    ┌──────────────────────────────────┐
                    │      Internet (WAN)              │
                    └────────────┬─────────────────────┘
                                 │
                    ┌────────────┴─────────────┐
                    │                          │
            ┌───────▼────────┐        ┌───────▼────────┐
            │  Internet Box  │        │   4G USB Key   │
            │ 192.168.2.254  │        │  192.168.8.1   │
            └───────┬────────┘        └───────┬────────┘
                    │ vmbr0                   │ enx001e101f0000
                    │                         │
            ┌───────▼─────────────────────────▼───────┐
            │        Proxmox VE Host                      │
            │     192.168.2.28 (local)                    │
            │     192.168.8.100 (4G)                      │
            │     192.168.12.28 (ZeroTier)                │
            │                                             │
            │  [4G-Failover Script]                        │
            │   - Box monitoring                           │
            │   - Routing failover                         │
            │   - NAT / Port forwarding                     │
            └─────────┬───────────────────────────────────┘
                      │
        ┌─────────────┼─────────────┬──────────────┐
        │             │             │              │
    ┌───▼───┐    ┌───▼───┐    ┌───▼───┐     ┌───▼───┐
    │ NGINX │    │ HASS  │    │  PBS  │     │Debian │
    │  .33  │    │  .29  │    │  .25  │     │  .39  │
    └───────┘    └───────┘    └───────┘     └───────┘


    ┌──────────────────────────────────────────────────┐
    │            ZeroTier Network                      │
    │         (Secure remote access)                   │
    │                                                  │
    │  [Client] ──→ 192.168.12.28:8123 ──→ HASS         │
    │  [Client] ──→ 192.168.12.28:81   ──→ NGINX        │
    └──────────────────────────────────────────────────┘
```

---

## 🔧 Requirements

### Hardware

- ✅ Proxmox VE server (tested on PVE 7.x/8.x)  
- ✅ 4G USB modem with modem mode (e.g., Huawei E3372)  
- ✅ SIM card with active data plan  
- ✅ Internet box with Ethernet connection

### Software

Install required packages:

```bash
apt update
apt install -y iptables jq vnstat wget netcat-openbsd curl
```

Install ZeroTier:

```bash
curl -s https://install.zerotier.com | bash
zerotier-cli join <NETWORK_ID>
```

### System configuration

```bash
# 1. Enable IP forwarding
sysctl -w net.ipv4.ip_forward=1
echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf

# 2. Identify 4G interface
ip link show
# Look for an interface name starting with "enx" or "usb"

# 3. Configure ZeroTier Central
# On https://my.zerotier.com:
# - Create a network
# - Add managed route: 192.168.2.0/24 via 192.168.12.28
# - Authorize members (check "Auth")
```

---

## 📥 Installation

### Step 1 — Download the script

```bash
mkdir -p /usr/local/bin
nano /usr/local/bin/4g-failover.sh
# Paste the script content
chmod +x /usr/local/bin/4g-failover.sh
```

### Step 2 — Configuration

Create the configuration file:

```bash
nano /etc/4g-failover.conf
```

Minimal example config:

```bash
#!/bin/bash
# 4G Failover Configuration

# === INTERFACES ===
INTERFACE_MAIN="vmbr0"
INTERFACE_4G="enx001e101f0000"  # Adapt to your modem interface

# === NETWORKS ===
GATEWAY_BOX="192.168.2.254"
IP_4G="192.168.8.100"
GATEWAY_4G="192.168.8.1"
NETMASK_4G="24"

# === ZEROTIER ===
ZT_HOST_IP="192.168.12.28"
ZT_REMOTE_PEER="192.168.12.50"  # Remote peer IP for ZT tests
ZT_TEST_ENABLED="true"

# === AUTHORIZED MACHINES (MASQUERADE) ===
NGINX_IP="192.168.2.33"
HASS_IP="192.168.2.29"
PBS_IP="192.168.2.25"
DEBIAN_GUI_IP="192.168.2.39"

# === PBS ===
PBS_CTID="1011"
LXC_PBS_ENABLED="true"

# === TELEGRAM ===
TELEGRAM_BOT_TOKEN="123456789:ABCdefGHIjklMNOpqrsTUVwxyz"
TELEGRAM_CHAT_ID="987654321"

# === TESTS ===
CHECK_HOSTS=("8.8.8.8" "1.1.1.1")
CHECK_INTERVAL="30"
FAIL_COUNT_THRESHOLD="3"
FOURG_CHECK_INTERVAL="1800"  # 30 minutes

# === DATA ALERTS ===
DATA_ALERT_THRESHOLD_1="500"   # first threshold (MB)
DATA_ALERT_THRESHOLD_2="900"   # second threshold (MB)
DATA_RESET_DAY="1"             # day of month to reset counters

# === DEBUG ===
DEBUG="false"
```

### Step 3 — Systemd service

Create the systemd unit:

```bash
nano /etc/systemd/system/4g-failover.service
```

Paste:

```ini
[Unit]
Description=4G Failover Monitoring for Proxmox
After=network-online.target zerotier-one.service pve-cluster.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/4g-failover.sh
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal
SyslogIdentifier=4g-failover

# Environment
Environment="LOG_FILE=/var/log/4g-failover.log"

[Install]
WantedBy=multi-user.target
```

### Step 4 — Enable and start

```bash
systemctl daemon-reload
systemctl enable 4g-failover
systemctl start 4g-failover
systemctl status 4g-failover
tail -f /var/log/4g-failover.log
```

---

## ⚙️ Configuration

### Main variables

| Variable | Description | Example | Required |
|----------|-------------|---------|----------|
| `INTERFACE_MAIN` | Main network interface | `vmbr0` | ✅ |
| `INTERFACE_4G` | 4G modem interface | `enx001e101f0000` | ✅ |
| `IP_4G` | Static IP for 4G interface | `192.168.8.100` | ✅ |
| `GATEWAY_4G` | 4G gateway | `192.168.8.1` | ✅ |
| `GATEWAY_BOX` | Main box gateway | `192.168.2.254` | ✅ |
| `ZT_HOST_IP` | ZeroTier host IP | `192.168.12.28` | ✅ |
| `ZT_REMOTE_PEER` | ZeroTier remote peer | `192.168.12.50` | ✅ |
| `NGINX_IP` | NGINX Proxy IP | `192.168.2.33` | ✅ |
| `HASS_IP` | Home Assistant IP | `192.168.2.29` | ✅ |
| `PBS_IP` | PBS IP | `192.168.2.25` | ✅ |
| `DEBIAN_GUI_IP` | Debian GUI IP | `192.168.2.39` | ✅ |
| `PBS_CTID` | PBS container ID | `1011` | ✅ |
| `TELEGRAM_BOT_TOKEN` | Telegram bot token | `123:ABC...` | ❌ |
| `CHECK_INTERVAL` | Check interval (s) | `30` | ❌ |
| `FAIL_COUNT_THRESHOLD` | Fail count before failover | `3` | ❌ |
| `DEBUG` | Debug mode | `false` | ❌ |

### Port Forwarding (ZeroTier)

Defined in the script (example around line ~74):

```bash
declare -A PORT_FORWARDS=(
    ["8123"]="192.168.2.29:8123"  # Home Assistant
    ["81"]="192.168.2.33:81"      # NGINX
    ["8007"]="192.168.2.25:8007"  # PBS (optional)
)
```

### Telegram bot

1. Create a bot with @BotFather → get TOKEN  
2. Get your CHAT_ID with @userinfobot → note the ID  
3. Configure `TELEGRAM_BOT_TOKEN` and `TELEGRAM_CHAT_ID` in `/etc/4g-failover.conf`

---

## 🔄 Detailed Operation

### Lifecycle

```
┌──────────────────────────────────────────────────────────┐
│                   STARTUP                                 │
│ 1. Check dependencies                                     │
│ 2. Configure 4G interface (UP + static IP)               │
│ 3. Block 4G traffic (except modem IP)                    │
│ 4. Restore state if restarting while in 4G mode          │
└──────────────────┬───────────────────────────────────────┘
                   │
                   ▼
┌──────────────────────────────────────────────────────────┐
│              MAIN LOOP (every CHECK_INTERVAL seconds)    │
│                                                          │
│  ┌────────────────────────────────────────────┐         │
│  │ Test box connectivity (ping hosts)         │         │
│  └────────────┬───────────────────────────────┘         │
│               │                                          │
│       ┌───────┴──────┐                                   │
│       │ BOX OK ?     │                                   │
│       └───┬──────┬───┘                                   │
│           │      │                                       │
│          YES    NO                                      │
│           │      │                                       │
│           │      ▼                                       │
│           │   fail_count++                               │
│           │      │                                       │
│           │   ┌──┴──────────────────┐                   │
│           │   │ fail_count >= N ?   │                   │
│           │   └──┬──────────────┬───┘                   │
│           │      │              │                        │
│           │     YES            NO                       │
│           │      │              │                        │
│           │      ▼              └──→ Continue           │
│           │   ACTIVATE 4G                               │
│           │   - Unblock 4G in iptables                  │
│           │   - Set default route via 4G                │
│           │   - Add MASQUERADE for selected hosts       │
│           │   - Setup ZeroTier port forwards           │
│           │   - Disable PBS backups                    │
│           │   - Send Telegram notification             │
│           │                                              │
│           ▼                                              │
│   ┌─────────────────┐                                    │
│   │ Is current state 4G? │                                │
│   └─────┬───────────┘                                    │
│         │                                                │
│        YES                                               │
│         │                                                │
│         ▼                                                │
│   DEACTIVATE 4G                                        │
│   - Remove test routes                                │
│   - Restore default route via box                     │
│   - Remove NAT / port forwards                        │
│   - Re-block 4G in iptables                           │
│   - Re-enable PBS                                     │
│   - Send Telegram notification                        │
│                                                          │
└──────────────────────────────────────────────────────────┘

Periodic tasks:
- Every FOURG_CHECK_INTERVAL: test 4G connectivity even in standby  
- Every hour: read vnstat, alert if thresholds exceeded, reset monthly on DATA_RESET_DAY
```

### Possible states

| State | Description | Routes | 4G iptables | NAT | Port Forward |
|-------|-------------|--------|-------------|-----|--------------|
| **box** | Normal | Default via box | Blocked | ❌ | ❌ |
| **4g** | Failover | Default via 4G | Unblocked | ✅ x4 | ✅ |
| **transition** | Switching | Tests in progress | Temporary | ⏳ | ⏳ |

---

## 📚 Technical Documentation

### System files

| File | Type | Description |
|------|------|-------------|
| `/usr/local/bin/4g-failover.sh` | Script | Main program |
| `/etc/4g-failover.conf` | Config | User configuration |
| `/etc/systemd/system/4g-failover.service` | Service | systemd unit |
| `/var/log/4g-failover.log` | Log | Event log |
| `/var/run/4g-failover.state` | State | Current state (box/4g) |
| `/var/run/4g-failover.pid` | PID | Process id |
| `/var/run/4g-failover.lock` | Lock | Singleton protection |
| `/var/run/4g-gateway.state` | State | Saved 4G gateway |
| `/var/run/4g-failover-pbs.state` | State | PBS jobs disabled |
| `/var/run/4g-failover-reset.state` | State | Date of last data reset |

### Script architecture

```
4g-failover.sh
├── CONFIG (lines 1-100)
│   ├── Global variables
│   ├── Load /etc/4g-failover.conf
│   └── Port forwarding configuration
│
├── UTILS (lines 100-250)
│   ├── check_dependencies()
│   ├── check_singleton()
│   ├── validate_config()
│   ├── validate_interfaces()
│   ├── with_timeout()
│   ├── setup_log_rotation()
│   ├── log_message()
│   ├── debug_log()
│   └── send_telegram()
│
├── NETWORK (lines 250-450)
│   ├── setup_4g_static_ip()
│   ├── check_and_fix_resolv_conf()
│   ├── check_box_connectivity()
│   ├── check_4g_connectivity()
│   ├── test_port_connectivity()
│   └── test_forwarded_services()
│
├── IPTABLES (lines 450-550)
│   ├── iptables_rule_exists()
│   ├── iptables_block_exists()
│   ├── port_forward_exists()
│   ├── forward_rule_exists()
│   ├── block_4g_traffic()
│   ├── unblock_4g_for_test()
│   ├── unblock_4g_completely()
│   ├── setup_port_forwarding()
│   └── remove_port_forwarding()
│
├── PBS (lines 550-650)
│   ├── disable_pbs_sync()
│   └── enable_pbs_sync()
│
├── MONITORING (lines 650-700)
│   ├── init_vnstat_4g()
│   └── check_4g_data_usage()
│
├── FAILOVER (lines 700-800)
│   ├── activate_4g()
│   ├── deactivate_4g()
│   ├── restore_state()
│   └── cleanup()
│
└── MAIN LOOP (lines 800-900)
    ├── Initialization
    ├── Periodic box tests
    ├── 4G failover when needed
    ├── Periodic 4G tests
    └── Data usage check
```

### Main functions (summarized)

#### `check_dependencies()`
Checks for required packages (`iptables`, `ping`, `wget`, `ip`, `pct`, `jq`, `vnstat`, `timeout`, `nc`) and exits with error if missing.

#### `check_singleton()`
Ensures only one instance runs using `/var/run/4g-failover.lock`.

#### `setup_4g_static_ip()`
Configures the static IP on the 4G interface, flushes existing addresses, and sets `IP_4G/NETMASK_4G`.

#### `check_box_connectivity()`
Pings `CHECK_HOSTS` via `INTERFACE_MAIN` to verify main Internet reachability.

#### `check_4g_connectivity()`
Tests 4G connectivity using `wget` (in case ICMP is blocked by carrier) and ZeroTier peer reachability.

#### `block_4g_traffic()`
Blocks all 4G traffic except the modem management IP with iptables rules:

```
ACCEPT  -o <4g_if> -d 192.168.8.1
DROP    -o <4g_if>
```

#### `setup_port_forwarding()`
Adds DNAT PREROUTING rules to map ZeroTier incoming ports to internal services and adds POSTROUTING MASQUERADE for outgoing traffic via 4G for allowed hosts.

#### `activate_4g(mode)`
Performs failover sequence: unblocks 4G, sets default route, optionally adds NAT and port forwards, disables PBS, then notifies Telegram.

#### `deactivate_4g()`
Restores default routing via box, removes NAT and port forwards, reblocks 4G, re-enables PBS, and notifies Telegram.

#### `disable_pbs_sync()` / `enable_pbs_sync()`
Manages Proxmox Backup Server scheduled jobs: saves current schedules, deletes them during 4G, and restores them once back on box.

#### `check_4g_data_usage()`
Reads vnstat totals for the 4G interface, adds any carried-over initial value, alerts via Telegram if thresholds are exceeded, and resets monthly on `DATA_RESET_DAY`.

---

## 🧾 iptables tables used (examples)

### NAT table

| Chain | Rule example | Purpose |
|-------|--------------|---------|
| PREROUTING | `DNAT -i zt+ --dport 8123 -> 192.168.2.29:8123` | Forward ZT -> HASS |
| PREROUTING | `DNAT -i zt+ --dport 81 -> 192.168.2.33:81` | Forward ZT -> NGINX |
| POSTROUTING | `MASQUERADE -s 192.168.2.33/32 -o <4g_if>` | NGINX outbound via 4G |
| POSTROUTING | `MASQUERADE -s 192.168.2.29/32 -o <4g_if>` | HASS outbound via 4G |
| OUTPUT | `ACCEPT -o <4g_if> -d 192.168.8.1` | Allow host to reach modem |
| OUTPUT | `DROP -o <4g_if>` | Block all other host traffic via 4G |

### FILTER table

| Chain | Rule example | Purpose |
|-------|--------------|---------|
| FORWARD | `ACCEPT -d 192.168.2.29 -p tcp --dport 8123` | Allow forwarded traffic to HASS |
| FORWARD | `ACCEPT -d 192.168.2.33 -p tcp --dport 81` | Allow forwarded traffic to NGINX |

---

## 🔀 Port Forwarding vs MASQUERADE

### Understand the difference

These mechanisms are **complementary**.

#### Port Forwarding (DNAT)
- **Direction**: Incoming connections (initiated from outside ZeroTier)  
- **Table**: `nat PREROUTING`  
- **Action**: Redirects an exposed port on the host to an internal host:port

Example flow:

```
CLIENT (ZeroTier) 192.168.12.50
    │
    │ connects to 192.168.12.28:8123 (host)
    ▼
Host PVE DNAT → 192.168.2.29:8123 (Home Assistant)
```

#### MASQUERADE (SNAT)
- **Direction**: Outgoing connections from LAN via 4G  
- **Table**: `nat POSTROUTING`  
- **Action**: Rewrites source IP to host's 4G IP so return traffic is routed back via 4G

They are used together: DNAT to allow inbound access from ZeroTier, MASQUERADE so internal services can reach the Internet via 4G.

---

## 🛠️ Maintenance

- Logs: `/var/log/4g-failover.log`  
- State files: `/var/run/4g-failover.*`  
- Restart after config change:
```bash
systemctl restart 4g-failover
```

---

## 🆘 Troubleshooting

- Check interfaces: `ip a`  
- Check routes: `ip route`  
- Check iptables NAT rules: `iptables -t nat -L -n -v`  
- Enable debug: set `DEBUG="true"` in `/etc/4g-failover.conf`  
- View logs: `journalctl -u 4g-failover -f` or `tail -f /var/log/4g-failover.log`

---

## 🧭 Future Notes

- Add IPv6 support  
- Add support for multiple 4G modems  
- Add WireGuard integration

---
