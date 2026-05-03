#!/bin/sh

# --- Config ---
D_NAME=${TUN_DEV:-tun0}
D_NUM=$(echo "$D_NAME" | tr -dc '0-9')
P=${SSH_PORT:-22}; U=${SSH_USER:-root}
L=${TUN_LOCAL_IP:-10.0.0.1}; R=${TUN_REMOTE_IP:-10.0.0.2}
MTU=${TUN_MTU:-1400}
K="/tmp/id_rsa"; MK="/root/.ssh/id_rsa"
MSS_RULE="-p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu"
SSH_OPT="-i $K -p $P -o StrictHostKeyChecking=no -o ConnectTimeout=5 -o ServerAliveInterval=25 -o ServerAliveCountMax=2"

# Verbosity Level (0=none, 1=-v, 2=-vv, 3=-vvv)
DEBUG_LVL=${SSH_DEBUG:-0}
V_FLAG=""
[ "$DEBUG_LVL" -eq 1 ] && V_FLAG="-v"
[ "$DEBUG_LVL" -eq 2 ] && V_FLAG="-vv"
[ "$DEBUG_LVL" -ge 3 ] && V_FLAG="-vvv"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [$1] $2"
}

cleanup() {
    log "INFO" "Restoration started..."
    ip route del default 2>/dev/null
    ip route add default $VIA dev $DEV 2>/dev/null
    iptables -t mangle -D FORWARD $MSS_RULE 2>/dev/null
    iptables -t mangle -D OUTPUT $MSS_RULE 2>/dev/null
    [ -n "$SSH_PID" ] && kill "$SSH_PID" 2>/dev/null
    log "INFO" "Tunnel stopped."
    exit
}
trap cleanup SIGINT SIGTERM

# Detect gateway
GW_LINE=$(ip route show default | head -n1)
DEV=$(echo "$GW_LINE" | awk '{print $5}')
VIA=$(echo "$GW_LINE" | grep -o "via [^ ]*")

log "INFO" "Starting SSH L3 Tunnel Engine"

# Preparation
[ ! -f "$MK" ] && { log "ERROR" "Private key missing at $MK"; exit 1; }
cp "$MK" "$K" && chmod 600 "$K"

# 1. Routing Exclusions
log "INFO" "Setting container exclusions: ${EXCLUDE_CONTAINER:-none}"
for target in $(echo "$EXCLUDE_CONTAINER" | tr ',' ' '); do
    ip route replace "$target" $VIA dev $DEV 2>/dev/null
done

# 2. Remote Cleanup
log "INFO" "Cleaning up remote interface $D_NAME..."
ssh $SSH_OPT "$U@$SSH_HOST" "ip link delete $D_NAME 2>/dev/null || true" || { log "ERROR" "Initial SSH connection failed"; cleanup; }

# 3. Establish Tunnel
log "INFO" "Connecting to $SSH_HOST ($D_NAME)..."
# Redirect stderr to stdout to pipe everything through the log function
ssh $SSH_OPT $V_FLAG -o ExitOnForwardFailure=yes -N -w "$D_NUM:$D_NUM" "$U@$SSH_HOST" 2>&1 | while read -r line; do
    [ -n "$line" ] && log "SSH" "$line"
done &
SSH_PID=$!

# Wait for tun device to appear
T=0
until [ -d "/sys/class/net/$D_NAME" ]; do
    T=$((T+1))
    [ "$T" -gt 5 ] && { log "ERROR" "tun0 interface failed to appear (timeout)"; cleanup; }
    kill -0 "$SSH_PID" 2>/dev/null || { log "ERROR" "SSH process died during tunnel creation"; cleanup; }
    sleep 1
done

# 4. Local Network Setup
log "INFO" "Configuring network (MTU $MTU)..."
ip addr add "$L" peer "$R" dev "$D_NAME"
ip link set dev "$D_NAME" mtu "$MTU" up
iptables -t mangle -A FORWARD $MSS_RULE
iptables -t mangle -A OUTPUT $MSS_RULE

# 5. Remote Network Setup
ssh $SSH_OPT "$U@$SSH_HOST" \
    "ip addr add $R peer $L dev $D_NAME 2>/dev/null; ip link set $D_NAME mtu $MTU up" || { log "ERROR" "Failed to configure remote interface"; cleanup; }

# 6. Verify Data Path
log "INFO" "Verifying data path (ping $R)..."
T=0
until ping -c 1 -W 1 "$R" >/dev/null; do
    T=$((T+1))
    [ "$T" -gt 5 ] && { log "ERROR" "Data path verification failed (ping timeout)"; cleanup; }
    kill -0 "$SSH_PID" 2>/dev/null || cleanup
    sleep 1
done

ip route replace default via "$R" dev "$D_NAME"
log "SUCCESS" "TUNNEL IS UP AND ROUTING TRAFFIC"

wait "$SSH_PID"
cleanup
