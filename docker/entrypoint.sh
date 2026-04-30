#!/bin/sh

# --- Config ---
P=${REMOTE_PORT:-22}; U=${REMOTE_USER:-root}
L=${LOCAL_TUN_IP:-10.0.0.1}; R=${REMOTE_TUN_IP:-10.0.0.2}
K="/tmp/id_rsa"; MK="/root/.ssh/id_rsa"

# Detect gateway
GW_LINE=$(ip route show default | head -n1)
DEV=$(echo "$GW_LINE" | awk '{print $5}')
VIA=$(echo "$GW_LINE" | grep -o "via [^ ]*")

cleanup() {
    echo ">>> Restoration..."
    ip route del default 2>/dev/null
    ip route add default $VIA dev $DEV 2>/dev/null
    [ -n "$SSH_PID" ] && kill "$SSH_PID"
    exit
}
trap cleanup SIGINT SIGTERM

# Preparation
[ ! -f "$MK" ] && echo "Key missing" && exit 1
cp "$MK" "$K" && chmod 600 "$K"

# 1. Exclusions
echo ">>> Setting container exclusions..."
for target in $(echo "$CONTAINER_EXCLUDE_IPS" | tr ',' ' '); do
    ip route replace "$target" $VIA dev $DEV 2>/dev/null
done

# 2. Remote Cleanup
echo ">>> Preparing remote server..."
ssh -i "$K" -p "$P" -o StrictHostKeyChecking=no "$U@$REMOTE_HOST" "ip link delete tun0 2>/dev/null"

# 3. Establish Tunnel
echo ">>> Connecting to $REMOTE_HOST..."
ssh -i "$K" -p "$P" -o StrictHostKeyChecking=no -o ExitOnForwardFailure=yes \
    -o ServerAliveInterval=15 -o ServerAliveCountMax=3 -N -w 0:0 "$U@$REMOTE_HOST" &
SSH_PID=$!

# Wait for tun0
until [ -d /sys/class/net/tun0 ]; do
    kill -0 "$SSH_PID" 2>/dev/null || { echo "SSH failed"; exit 1; }
    sleep 1
done

# 4. Final Network Setup
ip addr add "$L" peer "$R" dev tun0 && ip link set tun0 up
ssh -i "$K" -p "$P" -o StrictHostKeyChecking=no "$U@$REMOTE_HOST" \
    "ip addr add $R peer $L dev tun0 2>/dev/null; ip link set tun0 up" || cleanup

ping -c 1 -W 5 "$R" >/dev/null || cleanup

ip route replace default via "$R" dev tun0

echo ">>> TUNNEL IS UP"
wait "$SSH_PID"
cleanup
