#!/bin/bash

##############################################
# 4G Failover Script for Proxmox - Simplified Version
# Version 3.0 - October 2024
# 
# CHANGELOG:
# v3.0 - Simplified version: routing only, no NAT/port forward
# v2.3 - Policy routing, curl fallback, ZT port forward
# v2.0 - Complete rewrite with explicit NAT
#
# PREREQUISITES:
# 1. Enable IP forwarding on PVE host:
#    sysctl -w net.ipv4.ip_forward=1
#    echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
#
# 2. Configure Zerotier Central (https://my.zerotier.com):
#    Managed Routes: 192.168.2.0/24 via 192.168.12.28
#
# 3. Install dependencies:
#    apt install -y iptables jq vnstat curl
##############################################

set -uo pipefail

# Export global variables
export LOG_FILE="${LOG_FILE:-/var/log/4g-failover.log}"
export LOCK_FILE="/var/run/4g-failover.lock"
export PID_FILE="/var/run/4g-failover.pid"

# Load configuration
CONFIG_FILE="/etc/4g-failover.conf"

# Default values
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"
CHECK_HOSTS=("8.8.8.8" "1.1.1.1")
CHECK_INTERVAL="${CHECK_INTERVAL:-30}"
PING_COUNT="${PING_COUNT:-2}"
FAIL_COUNT_THRESHOLD="${FAIL_COUNT_THRESHOLD:-3}"
RETRY_4G_INTERVAL="${RETRY_4G_INTERVAL:-60}"
MAX_4G_RETRIES="${MAX_4G_RETRIES:-5}"
FOURG_CHECK_INTERVAL="${FOURG_CHECK_INTERVAL:-1800}"
DATA_CHECK_INTERVAL="${DATA_CHECK_INTERVAL:-3600}"
DATA_ALERT_THRESHOLD_1="${DATA_ALERT_THRESHOLD_1:-500}"
DATA_ALERT_THRESHOLD_2="${DATA_ALERT_THRESHOLD_2:-900}"
DATA_INITIAL_MB="${DATA_INITIAL_MB:-0}"
DATA_RESET_DAY="${DATA_RESET_DAY:-1}"
DATA_ALERT_REPEAT_MAX=3
DATA_ALERT_REPEAT_INTERVAL=3600
DATA_ALERT_COUNT_1=0
DATA_ALERT_COUNT_2=0
LAST_ALERT_TIME_1=0
LAST_ALERT_TIME_2=0

# PBS Configuration
PBS_CTID="${PBS_CTID:-1011}"
LXC_PBS_ENABLED="${LXC_PBS_ENABLED:-false}"

# Network configuration
ZT_HOST_IP="${ZT_HOST_IP:-192.168.12.28}"
ZT_REMOTE_PEER="${ZT_REMOTE_PEER:-192.168.12.50}"
ZT_TEST_ENABLED="${ZT_TEST_ENABLED:-true}"
INTERFACE_4G="${INTERFACE_4G:-enx001e101f0000}"
INTERFACE_MAIN="${INTERFACE_MAIN:-vmbr0}"
GATEWAY_BOX="${GATEWAY_BOX:-192.168.2.254}"
LOCAL_NETWORK="${LOCAL_NETWORK:-192.168.2.0/24}"
IP_4G="${IP_4G:-192.168.8.100}"
GATEWAY_4G="${GATEWAY_4G:-192.168.8.1}"
NETMASK_4G="${NETMASK_4G:-24}"
STATE_FILE="${STATE_FILE:-/var/run/4g-failover.state}"
GATEWAY_STATE_FILE="${GATEWAY_STATE_FILE:-/var/run/4g-gateway.state}"
PBS_STATE_FILE="${PBS_STATE_FILE:-/var/run/4g-failover-pbs.state}"
DEBUG="${DEBUG:-false}"
LOG_MAX_SIZE="${LOG_MAX_SIZE:-10485760}"
PERFORMANCE_METRICS="${PERFORMANCE_METRICS:-false}"

if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
    echo "$(date '+%Y-%m-%d %H:%M:%S') [INIT] ✅ Configuration loaded: $CONFIG_FILE" | tee -a ${LOG_FILE}
else
    echo "$(date '+%Y-%m-%d %H:%M:%S') [INIT] ⚠️ Config file missing, using defaults" | tee -a ${LOG_FILE}
fi

# Check dependencies
check_dependencies() {
    local missing_deps=()
    
    for cmd in iptables ping ip pct jq vnstat timeout curl; do
        if ! command -v "$cmd" &> /dev/null; then
            missing_deps+=("$cmd")
        fi
    done
    
    if [ ${#missing_deps[@]} -gt 0 ]; then
        echo "ERROR: Missing dependencies: ${missing_deps[*]}"
        echo "Install with: apt install -y iptables jq vnstat curl"
        exit 1
    fi
}

# Singleton protection
check_singleton() {
    if [ -f "$LOCK_FILE" ]; then
        local pid=$(cat "$LOCK_FILE" 2>/dev/null)
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            echo "❌ Script already running (PID: $pid)"
            exit 1
        else
            rm -f "$LOCK_FILE"
        fi
    fi
    echo $$ > "$LOCK_FILE"
    echo $$ > "$PID_FILE"
}

# Validate configuration
validate_config() {
    local errors=()
    
    [ -z "$INTERFACE_MAIN" ] && errors+=("INTERFACE_MAIN not defined")
    [ -z "$INTERFACE_4G" ] && errors+=("INTERFACE_4G not defined")
    [ -z "$IP_4G" ] && errors+=("IP_4G not defined")
    [ -z "$GATEWAY_4G" ] && errors+=("GATEWAY_4G not defined")
    
    if [ ${#errors[@]} -gt 0 ]; then
        echo "❌ Configuration errors:"
        printf '  - %s\n' "${errors[@]}"
        exit 1
    fi
}

# Validate interfaces
validate_interfaces() {
    for interface in "$INTERFACE_MAIN" "$INTERFACE_4G"; do
        if ! ip link show "$interface" >/dev/null 2>&1; then
            echo "❌ ERROR: Interface $interface not found"
            exit 1
        fi
    done
}

# Timeout wrapper
with_timeout() {
    local timeout_sec="$1"
    shift
    timeout "$timeout_sec" "$@"
}

# Log rotation
setup_log_rotation() {
    if [ -f "$LOG_FILE" ] && [ $(stat -c%s "$LOG_FILE" 2>/dev/null || echo 0) -gt "$LOG_MAX_SIZE" ]; then
        mv "$LOG_FILE" "${LOG_FILE}.old" 2>/dev/null || true
        touch "$LOG_FILE"
        chmod 644 "$LOG_FILE"
    fi
}

# Performance metrics
log_performance_metrics() {
    if [ "$PERFORMANCE_METRICS" = "true" ]; then
        local start_time="$1"
        local operation="$2"
        local duration=$(( $(date +%s) - start_time ))
        debug_log "Performance: $operation took ${duration}s"
    fi
}

# Initialization
fail_count=0
retry_4g_count=0
LAST_4G_CHECK=0
LAST_DATA_CHECK=0
fourg_status="unknown"

if [ -f "${STATE_FILE}" ]; then
    current_state=$(cat ${STATE_FILE})
else
    current_state="box"
    echo "box" > ${STATE_FILE}
fi

# Telegram function
send_telegram() {
    local message="$1"
    [ -z "$TELEGRAM_BOT_TOKEN" ] && { debug_log "Telegram token not defined."; return; }

    # Choose interface based on state
    local curl_interface=""
    if [ "$current_state" == "4g" ]; then
        curl_interface="--interface ${INTERFACE_4G}"
    else
        curl_interface="--interface ${INTERFACE_MAIN}"
    fi
    
    if ! with_timeout 10 curl -s --max-time 10 ${curl_interface} -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        -d chat_id="${TELEGRAM_CHAT_ID}" \
        -d text="🔄 4G Failover: ${message}" \
        -d parse_mode="HTML" > /dev/null 2>&1; then
        log_message "⚠️ Telegram notification failed"
    fi
}

# Log function
log_message() {
    local message="$1"
    local context="${2:-$current_state}"
    local prefix="[${context^^}]"
    echo "$(date '+%Y-%m-%d %H:%M:%S') ${prefix} ${message}" | tee -a ${LOG_FILE}
    setup_log_rotation
}

# Debug log
debug_log() {
    if [ "$DEBUG" = "true" ]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') [DEBUG] $1" | tee -a "${LOG_FILE}"
    fi
}

# Configure 4G static IP
setup_4g_static_ip() {
    log_message "Configuring static IP on ${INTERFACE_4G}..."
    
    if ! ip link show ${INTERFACE_4G} 2>/dev/null | grep -q "state UP"; then
        log_message "⚠️ Interface ${INTERFACE_4G} DOWN, activating..."
        ip link set ${INTERFACE_4G} up
        sleep 2
    fi
    
    if ip addr show ${INTERFACE_4G} | grep -q "${IP_4G}"; then
        debug_log "IP ${IP_4G} already configured"
        return 0
    fi
    
    ip addr flush dev ${INTERFACE_4G} 2>/dev/null || true
    
    if ip addr add ${IP_4G}/${NETMASK_4G} dev ${INTERFACE_4G}; then
        log_message "✅ Static IP configured: ${IP_4G}/${NETMASK_4G}"
    else
        log_message "❌ Static IP configuration error"
        return 1
    fi
    
    debug_log "4G Gateway defined: ${GATEWAY_4G}"

    # ADDED: Policy routing ONLY for 192.168.8.0/24
    # This routes ONLY traffic to modem, not to Internet
    ip route add 192.168.8.0/24 dev ${INTERFACE_4G} src ${IP_4G} table 100 2>/dev/null || true
    ip rule add from ${IP_4G} table 100 2>/dev/null || true
    ip rule add to 192.168.8.0/24 table 100 2>/dev/null || true
    
    debug_log "Policy routing configured for modem network only"
    
    return 0
}

# Check and restore /etc/resolv.conf
check_and_fix_resolv_conf() {
    if systemctl is-active --quiet systemd-resolved; then
        debug_log "systemd-resolved active, skipping /etc/resolv.conf modification"
        return 0
    fi
    
    # Backup file
    local RESOLV_BACKUP="/var/run/4g-failover-resolv.conf.backup"
    
    # Backup original if not already done
    if [ ! -f "$RESOLV_BACKUP" ] && [ -f /etc/resolv.conf ]; then
        cp /etc/resolv.conf "$RESOLV_BACKUP"
        debug_log "Backup /etc/resolv.conf → $RESOLV_BACKUP"
    fi
    
    # Check if corrupted by 4G modem
    if grep -q "^nameserver 192\.168\.8\.1" /etc/resolv.conf 2>/dev/null; then
        log_message "⚠️ /etc/resolv.conf corrupted (DNS 192.168.8.1), restoring..."
        
        if [ -f "$RESOLV_BACKUP" ]; then
            # Restore from backup
            cp "$RESOLV_BACKUP" /etc/resolv.conf
            log_message "✅ /etc/resolv.conf restored from backup"
        else
            # Fallback if no backup
            cat > /etc/resolv.conf << EOF
# DNS restored by 4g-failover
nameserver 8.8.8.8
nameserver 1.1.1.1
EOF
            log_message "✅ /etc/resolv.conf restored (default DNS)"
        fi
    fi
}

# Test box connectivity with PING
check_box_connectivity() {
    local start_time=$(date +%s)
    local success_count=0
    
    debug_log "Testing box connectivity via ${INTERFACE_MAIN} (ping)..."
    
    for host in "${CHECK_HOSTS[@]}"; do
        if with_timeout 10 ping -c ${PING_COUNT} -W 2 -I "${INTERFACE_MAIN}" "$host" >/dev/null 2>&1; then
            ((success_count++))
            debug_log "  ✓ ${host} responds via ${INTERFACE_MAIN} (ping)"
        else
            debug_log "  ✗ ${host} no response via ${INTERFACE_MAIN} (ping)"
        fi
    done
    
    debug_log "Box result: ${success_count}/${#CHECK_HOSTS[@]} hosts OK"
    log_performance_metrics "$start_time" "check_box_connectivity"
    [ "${success_count:-0}" -gt 0 ]
}

# Check iptables NAT rule
iptables_nat_exists() {
    iptables -t nat -C POSTROUTING -s ${LOCAL_NETWORK} -o ${INTERFACE_4G} -j MASQUERADE 2>/dev/null
}

check_4g_connectivity() {
    local start_time=$(date +%s)
    
    debug_log "Testing 4G connectivity via ${INTERFACE_4G} (curl)..."
    
    # Robust interface check (accepts UP and UNKNOWN)
    if ! ip link show ${INTERFACE_4G} >/dev/null 2>&1; then
        log_message "⚠️ ANOMALY: 4G interface does not exist"
        log_performance_metrics "$start_time" "check_4g_connectivity"
        return 1
    fi
    
    # Check link state (UP or UNKNOWN for USB keys)
    local link_state=$(ip link show ${INTERFACE_4G} | grep -o "state [A-Z]*" | awk '{print $2}')
    debug_log "4G interface state: ${link_state}"

    if [ "$link_state" = "DOWN" ]; then
        log_message "⚠️ 4G interface link DOWN, reactivating..."
        ip link set ${INTERFACE_4G} up
        sleep 2
    elif [ "$link_state" = "UNKNOWN" ]; then
        debug_log "4G interface in UNKNOWN (normal for USB keys)"
    elif [ "$link_state" = "UP" ]; then
        debug_log "4G interface UP"
    fi

    if ! ip addr show ${INTERFACE_4G} | grep -q "${IP_4G}"; then
        log_message "⚠️ 4G IP absent, reconfiguring..."
        setup_4g_static_ip || return 1
    fi
    
    local success_count=0
    
    local test_urls=(
        "http://detectportal.firefox.com/success.txt"
        "http://connectivitycheck.gstatic.com/generate_204"
        "http://clients3.google.com/generate_204"
    )
    
    for url in "${test_urls[@]}"; do
        if with_timeout 15 curl --interface ${INTERFACE_4G} \
            --ipv4 \
            --max-time 10 --silent --show-error --fail \
            "$url" >/dev/null 2>&1; then
            ((success_count++))
            debug_log "  ✓ ${url} responds via 4G (curl)"
            break
        else
            debug_log "  ✗ ${url} no response via 4G (curl)"
        fi
    done
    
    debug_log "4G Internet result: ${success_count}/1 test OK"
    
    # ZeroTier test (informative only)
    if [ "$ZT_TEST_ENABLED" = "true" ]; then
        debug_log "Testing ZeroTier connectivity..."
        
        local zt_result
        zt_result=$(with_timeout 10 ping -c 2 -W 3 ${ZT_REMOTE_PEER} 2>&1)
        local zt_exit=$?
        
        if [ $zt_exit -eq 0 ]; then
            debug_log "  ✓ ZeroTier remote peer (${ZT_REMOTE_PEER}) responds"
        else
            debug_log "  ✗ ZeroTier remote peer (${ZT_REMOTE_PEER}) no response (exit: $zt_exit)"
            debug_log "  Ping output: $(echo "$zt_result" | head -3)"
            log_message "⚠️ 4G Internet OK but ZeroTier in transition (normal)"
        fi
    fi
    
    log_performance_metrics "$start_time" "check_4g_connectivity"
    
    # 4G Internet working = sufficient (ZT will reconnect)
    if [ "${success_count:-0}" -gt 0 ]; then
        return 0
    fi
    
    return 1
}

# Block 4G traffic (standby mode)
block_4g_traffic() {
    log_message "Blocking 4G traffic in standby..."
    
    # IPv4 exception: modem web interface
    if ! iptables -C OUTPUT -o ${INTERFACE_4G} -d 192.168.8.1 -j ACCEPT 2>/dev/null; then
        iptables -I OUTPUT -o ${INTERFACE_4G} -d 192.168.8.1 -j ACCEPT
        debug_log "  ACCEPT rule for 192.168.8.1 added"
    fi
    
    # IPv4 block everything else
    if ! iptables -C OUTPUT -o ${INTERFACE_4G} -j DROP 2>/dev/null; then
        iptables -A OUTPUT -o ${INTERFACE_4G} -j DROP
        debug_log "  IPv4 DROP rule added"
    fi
    
    # Complete IPv6 block (to prevent ZeroTier consumption)
    if ! ip6tables -C OUTPUT -o ${INTERFACE_4G} -j DROP 2>/dev/null; then
        ip6tables -A OUTPUT -o ${INTERFACE_4G} -j DROP
        debug_log "  IPv6 DROP rule added"
    fi
    
    if ! ip6tables -C INPUT -i ${INTERFACE_4G} -j DROP 2>/dev/null; then
        ip6tables -A INPUT -i ${INTERFACE_4G} -j DROP
        debug_log "  IPv6 INPUT DROP rule added"
    fi
}

# Temporary unblock for tests
unblock_4g_for_test() {
    debug_log "Temporary 4G unblock for test..."
    
    # Remove IPv4 rules
    iptables -D OUTPUT -o ${INTERFACE_4G} -d 192.168.8.1 -j ACCEPT 2>/dev/null || true
    iptables -D OUTPUT -o ${INTERFACE_4G} -j DROP 2>/dev/null || true
    
    # Remove IPv6 rules
    ip6tables -D OUTPUT -o ${INTERFACE_4G} -j DROP 2>/dev/null || true
    ip6tables -D INPUT -i ${INTERFACE_4G} -j DROP 2>/dev/null || true
    
    # Add temporary default 4G route (low priority)
    ip route add default via ${GATEWAY_4G} dev ${INTERFACE_4G} metric 200 2>/dev/null || true
    debug_log "Temporary 4G route added (metric 200)"
    
    # DEBUG: Check unblock
    debug_log "iptables rules after unblock:"
    iptables -L OUTPUT -n -v | grep ${INTERFACE_4G} | while read line; do
        debug_log "  $line"
    done
    
    # DEBUG: Check route
    debug_log "Current default route:"
    ip route | grep default | while read line; do
        debug_log "  $line"
    done
}

# Reblock after tests
reblock_4g_after_test() {
    debug_log "Reblocking 4G after test..."
    
    # Remove default 4G route
    ip route del default via ${GATEWAY_4G} dev ${INTERFACE_4G} 2>/dev/null || true
    
    # Restore IPv4 rules
    if ! iptables -C OUTPUT -o ${INTERFACE_4G} -d 192.168.8.1 -j ACCEPT 2>/dev/null; then
        iptables -I OUTPUT -o ${INTERFACE_4G} -d 192.168.8.1 -j ACCEPT
    fi
    if ! iptables -C OUTPUT -o ${INTERFACE_4G} -j DROP 2>/dev/null; then
        iptables -A OUTPUT -o ${INTERFACE_4G} -j DROP
    fi
    
    # Restore IPv6 rules
    if ! ip6tables -C OUTPUT -o ${INTERFACE_4G} -j DROP 2>/dev/null; then
        ip6tables -A OUTPUT -o ${INTERFACE_4G} -j DROP
    fi
    if ! ip6tables -C INPUT -i ${INTERFACE_4G} -j DROP 2>/dev/null; then
        ip6tables -A INPUT -i ${INTERFACE_4G} -j DROP
    fi
}

# Complete unblock (failover mode)
unblock_4g_completely() {
    log_message "Complete 4G unblock..."
    
    # Remove IPv4 rules
    iptables -D OUTPUT -o ${INTERFACE_4G} -d 192.168.8.1 -j ACCEPT 2>/dev/null || true
    iptables -D OUTPUT -o ${INTERFACE_4G} -j DROP 2>/dev/null || true
    
    # Remove IPv6 rules
    ip6tables -D OUTPUT -o ${INTERFACE_4G} -j DROP 2>/dev/null || true
    ip6tables -D INPUT -i ${INTERFACE_4G} -j DROP 2>/dev/null || true
}

# Initialize vnstat
init_vnstat_4g() {
    if ! vnstat --dbiflist 2>/dev/null | grep -q "${INTERFACE_4G}"; then
        log_message "Initializing vnstat for ${INTERFACE_4G}..."
        vnstat --add -i ${INTERFACE_4G} 2>/dev/null || true
        sleep 2
    fi
}

# Check 4G data usage
check_4g_data_usage() {
    debug_log "Checking 4G data usage..."
    
    local current_day=$(date +%d)
    local current_month=$(date +%Y-%m)
    local last_reset_month=""
    
    if [ -f /var/run/4g-failover-reset.state ]; then
        last_reset_month=$(cat /var/run/4g-failover-reset.state)
    fi
    
    if [ "$current_day" -ge "$DATA_RESET_DAY" ] && [ "$last_reset_month" != "$current_month" ]; then
        log_message "🗓️ Reset day reached (${DATA_RESET_DAY}), resetting data stats"
        vnstat -i ${INTERFACE_4G} --reset 2>/dev/null || true
        echo "$current_month" > /var/run/4g-failover-reset.state
        DATA_ALERT_COUNT_1=0
        DATA_ALERT_COUNT_2=0
        LAST_ALERT_TIME_1=0
        LAST_ALERT_TIME_2=0
        send_telegram "🗓️ 4G data counter reset (day ${DATA_RESET_DAY} of month)"
        return 0
    fi
    
    local vnstat_data
    vnstat_data=$(vnstat -i ${INTERFACE_4G} --json 2>/dev/null) || return 0
    
    if [ -z "$vnstat_data" ]; then
        debug_log "No vnstat data available"
        return 0
    fi
    
    local rx_bytes
    local tx_bytes
    rx_bytes=$(echo "$vnstat_data" | jq -r '.interfaces[0].traffic.month[0].rx // 0' 2>/dev/null) || rx_bytes=0
    tx_bytes=$(echo "$vnstat_data" | jq -r '.interfaces[0].traffic.month[0].tx // 0' 2>/dev/null) || tx_bytes=0
    
    if [ -z "${rx_bytes:-}" ] || [ "${rx_bytes}" == "null" ] || [ "${rx_bytes}" == "0" ]; then
        debug_log "vnstat data not initialized"
        return 0
    fi
    
    local vnstat_mb=$(( (rx_bytes + tx_bytes) / 1048576 ))
    local total_mib=$((vnstat_mb + DATA_INITIAL_MB))
    
    log_message "📊 4G Usage: ${total_mib} MB / 1024 MB (vnstat: ${vnstat_mb} MB + initial: ${DATA_INITIAL_MB} MB)"
    
    local current_time=$(date +%s)
    
    if [ $total_mib -ge $DATA_ALERT_THRESHOLD_2 ]; then
        if [ $DATA_ALERT_COUNT_2 -lt $DATA_ALERT_REPEAT_MAX ]; then
            if [ $LAST_ALERT_TIME_2 -eq 0 ] || [ $((current_time - LAST_ALERT_TIME_2)) -ge $DATA_ALERT_REPEAT_INTERVAL ]; then
                ((DATA_ALERT_COUNT_2++))
                LAST_ALERT_TIME_2=$current_time
                send_telegram "🚨 4G DATA ALERT [${DATA_ALERT_COUNT_2}/${DATA_ALERT_REPEAT_MAX}]: ${total_mib} MB / 1024 MB (>${DATA_ALERT_THRESHOLD_2} MB)"
                log_message "🚨 THRESHOLD 2 ALERT: ${total_mib} MB (alert ${DATA_ALERT_COUNT_2}/${DATA_ALERT_REPEAT_MAX})"
            fi
        fi
    elif [ $total_mib -ge $DATA_ALERT_THRESHOLD_1 ]; then
        if [ $DATA_ALERT_COUNT_1 -lt $DATA_ALERT_REPEAT_MAX ]; then
            if [ $LAST_ALERT_TIME_1 -eq 0 ] || [ $((current_time - LAST_ALERT_TIME_1)) -ge $DATA_ALERT_REPEAT_INTERVAL ]; then
                ((DATA_ALERT_COUNT_1++))
                LAST_ALERT_TIME_1=$current_time
                send_telegram "⚠️ 4G data alert [${DATA_ALERT_COUNT_1}/${DATA_ALERT_REPEAT_MAX}]: ${total_mib} MB / 1024 MB (>${DATA_ALERT_THRESHOLD_1} MB)"
                log_message "⚠️ THRESHOLD 1 ALERT: ${total_mib} MB (alert ${DATA_ALERT_COUNT_1}/${DATA_ALERT_REPEAT_MAX})"
            fi
        fi
    fi
}

# Stop PBS LXC
disable_pbs_sync() {
    if [ "$LXC_PBS_ENABLED" != "true" ]; then
        debug_log "PBS feature disabled, skip"
        return 0
    fi
    
    if ! pct status ${PBS_CTID} 2>/dev/null | grep -q "running"; then
        debug_log "PBS LXC (${PBS_CTID}) already stopped"
        return 0
    fi
    
    log_message "Stopping PBS LXC (${PBS_CTID}) to save data..."
    
    if pct shutdown ${PBS_CTID} -t 60; then
        log_message "✅ PBS LXC stopped"
        send_telegram "⏸️ PBS stopped (data saving)"
    else
        log_message "⚠️ PBS LXC stop failed"
    fi
}

# Start PBS LXC
enable_pbs_sync() {
    if [ "$LXC_PBS_ENABLED" != "true" ]; then
        debug_log "PBS feature disabled, skip"
        return 0
    fi
    
    if pct status ${PBS_CTID} 2>/dev/null | grep -q "running"; then
        debug_log "PBS LXC (${PBS_CTID}) already started"
        return 0
    fi
    
    log_message "Starting PBS LXC (${PBS_CTID})..."
    
    if pct start ${PBS_CTID}; then
        log_message "✅ PBS LXC restarted"
        send_telegram "▶️ PBS restarted"
    else
        log_message "⚠️ PBS LXC start failed"
    fi
}

# Activate 4G (SIMPLIFIED VERSION - routing only)
activate_4g() {
    local start_time=$(date +%s)
    log_message "Attempting 4G activation (attempt $((retry_4g_count + 1))/${MAX_4G_RETRIES})..." "BOX->4G"
    
    if ! ip addr show ${INTERFACE_4G} | grep -q "${IP_4G}"; then
        log_message "⚠️ 4G IP absent, configuring..." "BOX->4G"
        if ! setup_4g_static_ip; then
            log_message "ERROR - Cannot configure static IP" "BOX->4G"
            ((retry_4g_count++))
            return 1
        fi
    fi
    
    local ip_4g
    ip_4g=$(ip addr show ${INTERFACE_4G} | grep "inet " | awk '{print $2}')
    log_message "4G IP: ${ip_4g}" "BOX->4G"
    log_message "4G Gateway: ${GATEWAY_4G}" "BOX->4G"
    
    log_message "Testing 4G connectivity..." "BOX->4G"
    unblock_4g_completely
    
    # Remove box route
    ip route del default via ${GATEWAY_BOX} dev ${INTERFACE_MAIN} 2>/dev/null || true
    
    # Add 4G route for tests
    ip route add default via ${GATEWAY_4G} dev ${INTERFACE_4G} metric 50 2>/dev/null || true
    debug_log "Temporary 4G route added for tests (metric 50)"
    
    log_message "Waiting for 4G and ZeroTier connection stabilization..." "BOX->4G"
    local wait_time=0
    local max_wait=25
    local fourg_test=0
    
    while [ $wait_time -lt $max_wait ]; do
        sleep 5
        wait_time=$((wait_time + 5))
        
        debug_log "Testing connectivity after ${wait_time}s..."
        if check_4g_connectivity; then
            log_message "✅ 4G connectivity established after ${wait_time}s" "BOX->4G"
            fourg_test=1
            break
        else
            debug_log "Not stable yet, retrying..."
        fi
    done
    
    if [ $fourg_test -eq 0 ]; then
        log_message "⚠️ Final test after ${max_wait}s..." "BOX->4G"
        check_4g_connectivity && fourg_test=1 || fourg_test=0
    fi
    
    if [ $fourg_test -eq 0 ]; then
        log_message "ERROR - 4G without Internet connectivity" "BOX->4G"
        block_4g_traffic
        ((retry_4g_count++))
        
        if [ $retry_4g_count -lt $MAX_4G_RETRIES ]; then
            log_message "Retrying in ${RETRY_4G_INTERVAL}s..." "BOX->4G"
            return 1
        else
            log_message "CRITICAL - No connectivity after ${MAX_4G_RETRIES} attempts" "BOX->4G"
            retry_4g_count=0
            return 2
        fi
    fi
    
    log_message "Switching routing to 4G..." "BOX->4G"
    
    # Check 4G route is active
    if ! ip route show | grep -q "default via ${GATEWAY_4G} dev ${INTERFACE_4G}"; then
        log_message "ERROR - 4G route absent after tests" "BOX->4G"
        ip route add default via ${GATEWAY_BOX} dev ${INTERFACE_MAIN} 2>/dev/null || true
        block_4g_traffic
        ((retry_4g_count++))
        return 1
    fi
    
    log_message "Default route via 4G activated" "BOX->4G"
    
    # Add test routes to box (to detect return)
    log_message "Adding test routes to box..." "4G"
    for host in "${CHECK_HOSTS[@]}"; do
        ip route add ${host}/32 via ${GATEWAY_BOX} dev ${INTERFACE_MAIN} 2>/dev/null || true
        debug_log "  Test route: ${host} via ${GATEWAY_BOX}"
    done
    
    echo "active" > ${STATE_FILE}
    echo "${GATEWAY_4G}" > ${GATEWAY_STATE_FILE}
    current_state="4g"
    retry_4g_count=0
    fourg_status="up"
    
    log_message "✅ 4G activated (Gateway: ${GATEWAY_4G})" "4G"

    send_telegram "✅ 4G activated - Internet OK (ZeroTier reconnecting...)"
    zerotier_reconnect  
    
    log_message "zerotier_reconnect called, checking background process..." "DEBUG"
    sleep 2
    if pgrep -f "ping.*192.168.12.50" > /dev/null; then
        log_message "✓ ZT monitoring process active (PID: $(pgrep -f 'ping.*192.168.12.50'))" "DEBUG"
    else
        log_message "✗ No ZT monitoring process found!" "DEBUG"
    fi

    disable_pbs_sync || true
    
    log_performance_metrics "$start_time" "activate_4g"
    return 0
}

# Deactivate 4G
deactivate_4g() {
    local start_time=$(date +%s)
    log_message "Deactivating 4G, returning to box..." "4G->BOX"
    
    if [ -f ${GATEWAY_STATE_FILE} ]; then
        GATEWAY_4G=$(cat ${GATEWAY_STATE_FILE})
    fi
    
    log_message "Removing test routes..." "4G->BOX"
    for host in "${CHECK_HOSTS[@]}"; do
        ip route del ${host}/32 via ${GATEWAY_BOX} dev ${INTERFACE_MAIN} 2>/dev/null || true
        debug_log "  Test route removed: ${host}"
    done
    
    if [ -n "$GATEWAY_4G" ]; then
        ip route del default via ${GATEWAY_4G} dev ${INTERFACE_4G} 2>/dev/null || true
    fi
    ip route del default dev ${INTERFACE_4G} 2>/dev/null || true
    
    if ! ip route add default via ${GATEWAY_BOX} dev ${INTERFACE_MAIN} 2>/dev/null; then
        log_message "WARNING - Box route already exists" "4G->BOX"
    fi
    
    block_4g_traffic
    
    check_and_fix_resolv_conf
    
    rm -f ${STATE_FILE} ${GATEWAY_STATE_FILE}
    current_state="box"
    retry_4g_count=0
    
    enable_pbs_sync || true
    
    log_message "✅ Box restored (4G blocked but remains UP with IP)" "BOX"
    send_telegram "✅ Box restored - 4G deactivated"
    
    zerotier_reconnect

    log_performance_metrics "$start_time" "deactivate_4g"
}

# Restore state at startup
restore_state() {
    if [ -f ${STATE_FILE} ]; then
        local saved_state=$(cat ${STATE_FILE})
        if [ "$saved_state" == "active" ]; then
            log_message "Active 4G state detected at startup..."
            current_state="4g"
            
            local fourg_test=0
            check_4g_connectivity && fourg_test=1 || fourg_test=0
            
            if [ $fourg_test -eq 1 ]; then
                log_message "4G still functional after restart"
                fourg_status="up"
            else
                log_message "4G inactive, restoring box..."
                deactivate_4g || true
            fi
        fi
    fi
}

zerotier_reconnect() {
    local ZT_NETWORK=$(zerotier-cli listnetworks 2>/dev/null | tail -n +2 | awk '{print $3}' | head -1)
    if [ -n "$ZT_NETWORK" ]; then
        log_message "Forced ZeroTier reconnection (network: ${ZT_NETWORK})"
        zerotier-cli leave $ZT_NETWORK >/dev/null 2>&1
        sleep 5
        zerotier-cli join $ZT_NETWORK >/dev/null 2>&1
        
        # Background monitoring with notification
        log_message "ZT_TEST_ENABLED = '$ZT_TEST_ENABLED'" "DEBUG"
        
        if [ "$ZT_TEST_ENABLED" = "true" ]; then
            log_message "Entering ZT monitoring block" "DEBUG"
            
            local ZT_MONITOR_SCRIPT="/tmp/zt-monitor-$.sh"
            local ZT_MONITOR_LOG="/var/log/zt-monitor-$(date +%Y%m%d-%H%M%S).log"
            
            log_message "Creating monitoring script: $ZT_MONITOR_SCRIPT" "DEBUG"
            log_message "Monitoring log: $ZT_MONITOR_LOG" "DEBUG"
            
            # Simple write test
            log_message "Testing write to /tmp..." "DEBUG"
            if echo "test" > "$ZT_MONITOR_SCRIPT" 2>&1; then
                log_message "✅ /tmp write OK" "DEBUG"
            else
                log_message "❌ /tmp write FAILED: $?" "DEBUG"
                return 1
            fi
            
            log_message "Starting script creation with echo..." "DEBUG"
            
            # Create script line by line (avoids heredoc issues)
            {
                echo '#!/bin/bash'
                echo "TELEGRAM_BOT_TOKEN=\"${TELEGRAM_BOT_TOKEN}\""
                echo "TELEGRAM_CHAT_ID=\"${TELEGRAM_CHAT_ID}\""
                echo "ZT_REMOTE_PEER=\"${ZT_REMOTE_PEER}\""
                echo "INTERFACE_4G=\"${INTERFACE_4G}\""
                echo "INTERFACE_MAIN=\"${INTERFACE_MAIN}\""
                echo "STATE_FILE=\"${STATE_FILE}\""
                echo "LOG_FILE=\"${LOG_FILE}\""
                echo "MONITOR_LOG=\"${ZT_MONITOR_LOG}\""
                echo ''
                echo 'echo "=========================================" >> "${MONITOR_LOG}"'
                echo 'echo "$(date '\''+%Y-%m-%d %H:%M:%S'\'') [ZT-MONITOR] Starting monitoring" >> "${MONITOR_LOG}"'
                echo 'echo "  Peer: ${ZT_REMOTE_PEER}" >> "${MONITOR_LOG}"'
                echo 'echo "  4G Interface: ${INTERFACE_4G}" >> "${MONITOR_LOG}"'
                echo 'echo "  Main Interface: ${INTERFACE_MAIN}" >> "${MONITOR_LOG}"'
                echo 'echo "  Token: ${#TELEGRAM_BOT_TOKEN} chars" >> "${MONITOR_LOG}"'
                echo 'echo "  ChatID: ${TELEGRAM_CHAT_ID}" >> "${MONITOR_LOG}"'
                echo 'echo "=========================================" >> "${MONITOR_LOG}"'
                echo ''
                echo 'for i in {1..60}; do'
                echo '    echo "$(date '\''+%Y-%m-%d %H:%M:%S'\'') [ZT-MONITOR] Test ${i}/60 ($((i*5))s)" >> "${MONITOR_LOG}"'
                echo '    sleep 5'
                echo '    '
                echo '    if ping -c 1 -W 2 ${ZT_REMOTE_PEER} >/dev/null 2>&1; then'
                echo '        echo "$(date '\''+%Y-%m-%d %H:%M:%S'\'') [ZT-MONITOR] ✅ Reconnected in $((i*5))s" >> "${MONITOR_LOG}"'
                echo '        echo "$(date '\''+%Y-%m-%d %H:%M:%S'\'') [ZT-MONITOR] ✅ ZeroTier reconnected after $((i*5))s" >> "${LOG_FILE}"'
                echo '        '
                echo '        # Interface according to state'
                echo '        if [ -f "${STATE_FILE}" ] && [ "$(cat ${STATE_FILE} 2>/dev/null)" == "active" ]; then'
                echo '            curl_if="--interface ${INTERFACE_4G}"'
                echo '            echo "$(date '\''+%Y-%m-%d %H:%M:%S'\'') [ZT-MONITOR] Interface: 4G" >> "${MONITOR_LOG}"'
                echo '        else'
                echo '            curl_if="--interface ${INTERFACE_MAIN}"'
                echo '            echo "$(date '\''+%Y-%m-%d %H:%M:%S'\'') [ZT-MONITOR] Interface: main" >> "${MONITOR_LOG}"'
                echo '        fi'
                echo '        '
                echo '        # Telegram'
                echo '        if [ -n "${TELEGRAM_BOT_TOKEN}" ] && [ -n "${TELEGRAM_CHAT_ID}" ]; then'
                echo '            result=$(timeout 10 curl -s --max-time 10 ${curl_if} -X POST \'
                echo '                "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \'
                echo '                -d chat_id="${TELEGRAM_CHAT_ID}" \'
                echo '                -d text="🔄 4G Failover: ✅ ZeroTier reconnected after $((i*5))s" \'
                echo '                -d parse_mode="HTML" 2>&1)'
                echo '            exit_code=$?'
                echo '            '
                echo '            echo "$(date '\''+%Y-%m-%d %H:%M:%S'\'') [ZT-MONITOR] Curl exit: ${exit_code}" >> "${MONITOR_LOG}"'
                echo '            echo "$(date '\''+%Y-%m-%d %H:%M:%S'\'') [ZT-MONITOR] Curl result: ${result}" >> "${MONITOR_LOG}"'
                echo '            '
                echo '            if [ ${exit_code} -eq 0 ]; then'
                echo '                echo "$(date '\''+%Y-%m-%d %H:%M:%S'\'') [ZT-MONITOR] ✅ Telegram sent" >> "${MONITOR_LOG}"'
                echo '            else'
                echo '                echo "$(date '\''+%Y-%m-%d %H:%M:%S'\'') [ZT-MONITOR] ❌ Telegram failed" >> "${MONITOR_LOG}"'
                echo '            fi'
                echo '        fi'
                echo '        '
                echo '        logger -t 4g-failover "ZeroTier reconnected in $((i*5))s"'
                echo '        echo "=========================================" >> "${MONITOR_LOG}"'
                echo '        rm -f "$0"'
                echo '        exit 0'
                echo '    fi'
                echo 'done'
                echo ''
                echo 'echo "$(date '\''+%Y-%m-%d %H:%M:%S'\'') [ZT-MONITOR] ⚠️ 5min timeout" >> "${MONITOR_LOG}"'
                echo 'echo "=========================================" >> "${MONITOR_LOG}"'
                echo 'rm -f "$0"'
                echo 'exit 1'
            } > "$ZT_MONITOR_SCRIPT" 2>&1
            creation_exit=$?
            
            log_message "Script created with echo method (exit: $creation_exit)" "DEBUG"
            
            if [ $creation_exit -ne 0 ]; then
                log_message "❌ Script creation error!" "DEBUG"
                return 1
            fi
            
            if [ ! -f "$ZT_MONITOR_SCRIPT" ]; then
                log_message "❌ Script not created!" "DEBUG"
                return 1
            fi
            
            chmod +x "$ZT_MONITOR_SCRIPT"
            log_message "✅ Script ready" "DEBUG"
            
            # Detached launch
            nohup "$ZT_MONITOR_SCRIPT" >/dev/null 2>&1 &
            local pid=$!
            
            log_message "✅ Monitoring PID: $pid" "DEBUG"
            log_message "   Logs: $ZT_MONITOR_LOG" "DEBUG"
            
            sleep 0.5
            if ps -p $pid >/dev/null 2>&1; then
                log_message "✅ Process active" "DEBUG"
            else
                log_message "⚠️ Process not found" "DEBUG"
            fi
        fi
    fi
}

# Complete cleanup on stop
cleanup() {
    log_message "Stop signal received, complete cleanup..."
    
    if [ "$current_state" == "4g" ]; then
        deactivate_4g || true
    fi
    
    # CRITICAL: Restart PBS if stopped
    if [ "$LXC_PBS_ENABLED" = "true" ]; then
        enable_pbs_sync || true
    fi
       
    log_message "Cleaning iptables rules..."
    
    # IPv4
    iptables -D OUTPUT -o ${INTERFACE_4G} -d 192.168.8.1 -j ACCEPT 2>/dev/null || true
    iptables -D OUTPUT -o ${INTERFACE_4G} -j DROP 2>/dev/null || true
    
    # IPv6 - CRITICAL to avoid consumption after stop
    ip6tables -A OUTPUT -o ${INTERFACE_4G} -j DROP 2>/dev/null || true
    ip6tables -A INPUT -i ${INTERFACE_4G} -j DROP 2>/dev/null || true
    
    # Remove resolv.conf backup
    rm -f /var/run/4g-failover-resolv.conf.backup
    
    rm -f "$LOCK_FILE" "$PID_FILE"
    
    log_message "Clean service stop"
    exit 0
}

# === STARTUP ===
check_dependencies
check_singleton
validate_config
validate_interfaces

trap cleanup SIGTERM SIGINT SIGQUIT

log_message "========================================="
log_message "Starting 4G failover monitoring v3.0 (simplified)"
log_message "Configuration:"
log_message "  - Main interface: ${INTERFACE_MAIN}"
log_message "  - 4G interface: ${INTERFACE_4G}"
log_message "  - 4G static IP: ${IP_4G}/${NETMASK_4G}"
log_message "  - 4G gateway: ${GATEWAY_4G}"
log_message "  - NAT local network: ${LOCAL_NETWORK}"
log_message "  - ZeroTier Host: ${ZT_HOST_IP}"
log_message "  - ZeroTier Remote Peer: ${ZT_REMOTE_PEER}"
log_message "  - ZeroTier test: ${ZT_TEST_ENABLED}"
log_message "  - PBS Container: ${PBS_CTID} (enabled: ${LXC_PBS_ENABLED})"
log_message "  - Box Gateway: ${GATEWAY_BOX}"
log_message "  - Check hosts: ${CHECK_HOSTS[*]}"
log_message "  - Check interval: ${CHECK_INTERVAL}s"
log_message "  - Ping count: ${PING_COUNT}"
log_message "  - Fail threshold: ${FAIL_COUNT_THRESHOLD}"
log_message "  - 4G check interval: ${FOURG_CHECK_INTERVAL}s ($((FOURG_CHECK_INTERVAL / 60))min)"
log_message "  - Debug mode: ${DEBUG}"
log_message "  - MODE: Routing + NAT MASQUERADE (/24)"
log_message "========================================="

log_message "Initializing 4G interface..."

ip link set ${INTERFACE_4G} up 2>/dev/null || {
    log_message "❌ ERROR: Cannot activate ${INTERFACE_4G}"
    exit 1
}
sleep 2

if setup_4g_static_ip; then
    IP_4G_INIT=$(ip addr show ${INTERFACE_4G} | grep "inet " | awk '{print $2}')
    log_message "✅ 4G IP configured: ${IP_4G_INIT}"
else
    log_message "⚠️ Static IP configuration failed (will retry)"
fi

check_and_fix_resolv_conf
block_4g_traffic
log_message "4G interface initialized (UP, static IP, BLOCKED)"

init_vnstat_4g

restore_state

send_telegram "🚀 Failover monitoring started v3.0 (state: ${current_state})"

LAST_4G_CHECK=$(date +%s)
LAST_DATA_CHECK=$(date +%s)

# Main loop
while true; do
    box_status=0
    check_box_connectivity && box_status=1 || box_status=0
    
    if [ $box_status -eq 1 ]; then
        if [ $fail_count -gt 0 ]; then
            log_message "Box recovered (after ${fail_count} failures)"
        fi
        fail_count=0
        
        if [ "$current_state" == "4g" ]; then
            log_message "Box back, switching..."
            deactivate_4g || true
        fi
        
    else
        ((fail_count++))
        log_message "Box connectivity failure ($fail_count/${FAIL_COUNT_THRESHOLD})"
        
        if [ $fail_count -ge $FAIL_COUNT_THRESHOLD ]; then
            if [ "$current_state" == "box" ]; then
                log_message "Failure threshold reached, activating 4G..."
                activate_4g || true
                activation_result=$?
                
                if [ $activation_result -eq 1 ]; then
                    log_message "Waiting before retry..."
                    sleep ${RETRY_4G_INTERVAL}
                    continue
                elif [ $activation_result -eq 2 ]; then
                    log_message "Extended wait..."
                    sleep $((CHECK_INTERVAL * 5))
                fi
            else
                fourg_status_check=0
                check_4g_connectivity && fourg_status_check=1 || fourg_status_check=0
                
                if [ $fourg_status_check -eq 0 ]; then
                    log_message "⚠️ 4G lost, reactivating..."
                    deactivate_4g || true
                    sleep 5
                    activate_4g || true
                fi
            fi
        fi
    fi
    
    # Periodic 4G test in standby
    if [ "$current_state" == "box" ]; then
        current_time=$(date +%s)
        if [ $((current_time - LAST_4G_CHECK)) -ge $FOURG_CHECK_INTERVAL ]; then
            LAST_4G_CHECK=$current_time
            debug_log "Periodic 4G test (every $((FOURG_CHECK_INTERVAL / 60))min)..."
            
            unblock_4g_for_test
            
            fourg_check_result=0
            check_4g_connectivity && fourg_check_result=1 || fourg_check_result=0
            
            if [ $fourg_check_result -eq 1 ]; then
                if [ "$fourg_status" == "down" ]; then
                    send_telegram "✅ 4G restored (standby)"
                    log_message "✅ 4G restored"
                elif [ "$fourg_status" == "unknown" ]; then
                    log_message "✅ 4G functional (first test)"
                fi
                fourg_status="up"
            else
                if [ "$fourg_status" != "down" ]; then
                    send_telegram "⚠️ 4G unreachable (standby)"
                    log_message "⚠️ 4G unreachable"
                fi
                fourg_status="down"
            fi
            
            reblock_4g_after_test
        fi
    fi
    
    # Periodic data usage check
    current_time=$(date +%s)
    if [ $((current_time - LAST_DATA_CHECK)) -ge $DATA_CHECK_INTERVAL ]; then
        LAST_DATA_CHECK=$current_time
        check_4g_data_usage
    fi
    
    sleep ${CHECK_INTERVAL}
done
