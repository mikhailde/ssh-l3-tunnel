#!/bin/sh

# --- Config ---
D_NAME=${TUN_DEV:-tun0}
D_NUM=$(echo "$D_NAME" | tr -dc '0-9')
P=${SSH_PORT:-22}; U=${SSH_USER:-root}
L=${TUN_LOCAL_IP:-10.0.0.1}; R=${TUN_REMOTE_IP:-10.0.0.2}
MTU=${TUN_MTU:-1404}
K="/tmp/id_rsa"; MK="/root/.ssh/id_rsa"
MSS_RULE="-p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu"

# Detect gateway
GW_LINE=$(ip route show default | head -n1)
DEV=$(echo "$GW_LINE" | awk '{print $5}')
VIA=$(echo "$GW_LINE" | grep -o "via [^ ]*")

cleanup() {
    echo ">>> Restoration..."
    ip route del default 2>/dev/null
    ip route add default $VIA dev $DEV 2>/dev/null
    iptables -t mangle -D FORWARD $MSS_RULE 2>/dev/null
    iptables -t mangle -D OUTPUT $MSS_RULE 2>/dev/null
    [ -n "$SSH_PID" ] && kill "$SSH_PID"
    exit
}
trap cleanup SIGINT SIGTERM

# Preparation
[ ! -f "$MK" ] && echo "Key missing" && exit 1
cp "$MK" "$K" && chmod 600 "$K"

# 1. Exclusions
echo ">>> Setting container exclusions..."
for target in $(echo "$EXCLUDE_CONTAINER" | tr ',' ' '); do
    ip route replace "$target" $VIA dev $DEV 2>/dev/null
done

# 2. Remote Cleanup
echo ">>> Preparing remote server..."
ssh -i "$K" -p "$P" -o StrictHostKeyChecking=no "$U@$SSH_HOST" "ip link delete $D_NAME 2>/dev/null" -v

# 3. Establish Tunnel
echo ">>> Connecting to $SSH_HOST ($D_NAME)..."
ssh -i "$K" -p "$P" -o StrictHostKeyChecking=no -o ExitOnForwardFailure=yes \
    -o ServerAliveInterval=15 -o ServerAliveCountMax=3 -N -w "$D_NUM:$D_NUM" "$U@$SSH_HOST" &
SSH_PID=$!

until [ -d "/sys/class/net/$D_NAME" ]; do
    kill -0 "$SSH_PID" 2>/dev/null || { echo "SSH failed"; exit 1; }
    sleep 1
done

# 4. Final Network Setup
echo ">>> Configuring network (MTU $MTU)..."
ip addr add "$L" peer "$R" dev "$D_NAME"
ip link set dev "$D_NAME" mtu "$MTU" up
iptables -t mangle -A FORWARD $MSS_RULE
iptables -t mangle -A OUTPUT $MSS_RULE

ssh -i "$K" -p "$P" -o StrictHostKeyChecking=no "$U@$SSH_HOST" \
    "ip addr add $R peer $L dev $D_NAME 2>/dev/null; ip link set $D_NAME mtu $MTU up" || cleanup

echo ">>> Verifying data path..."
until ping -c 1 -W 1 "$R" >/dev/null; do
    kill -0 "$SSH_PID" 2>/dev/null || cleanup
    sleep 1
done

ip route replace default via "$R" dev "$D_NAME"

echo ">>> TUNNEL IS UP"
wait "$SSH_PID"
cleanup
