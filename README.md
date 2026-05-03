# ssh-l3-tunnel

A high-performance, VPN-like Layer 3 tunnel over SSH, fully dockerized. This project allows you to route all system traffic (TCP, UDP, ICMP) through a remote server. It is specifically optimized for **Linux** and **Windows (via WSL2)**.

## Features

- **True L3 Tunneling**: Unlike standard SSH proxies (SOCKS), this creates a virtual `tun` device, allowing ICMP (ping), UDP, and all TCP traffic to pass through.
- **Dockerized Engine**: The entire SSH logic is isolated in a lightweight Alpine container.
- **Real-time Log Streaming**: Engine logs (including SSH debug output) are streamed directly to the host console with color-coded status levels for easier monitoring.
- **Windows Integration**: Includes an optimized PowerShell script to bridge Windows host traffic into the WSL2 tunnel with automatic priority management.
- **Smart Routing**: Separate exclusion lists for the container/WSL side and the Windows host.
- **Zero Static Waits**: Scripts use retry loops to verify connectivity as fast as possible.

---

## Prerequisites

### 1. Remote Server (Linux)

#### SSH Configuration
The SSH server must allow tunneling. Edit `/etc/ssh/sshd_config`:
```bash
PermitTunnel yes
AllowTcpForwarding yes
# Restart SSH after changes: systemctl restart ssh
```

#### IP Forwarding & NAT (Masquerade)
The server must be configured to forward traffic from the tunnel to the internet.

1. **Enable IP Forwarding:**
   ```bash
   sysctl -w net.ipv4.ip_forward=1
   # To make it permanent, add "net.ipv4.ip_forward=1" to /etc/sysctl.conf
   ```

2. **Enable NAT (Masquerade):**
   Assuming your server's public interface is `eth0` (check with `ip route`), run:
   ```bash
   iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
   ```
   *Note: If you use `nftables` or `ufw`, ensure that traffic from the tunnel subnet (e.g., `10.0.0.0/24`) is allowed to be forwarded and masqueraded.*

### 2. Local Machine
- **Linux**: Docker and Docker Compose.
- **Windows**: Docker Desktop (or Docker inside WSL2) and WSL2 installed.

---

## Installation

1. **Clone the repository:**
   ```bash
   git clone https://github.com/mikhailde/ssh-l3-tunnel.git
   cd ssh-l3-tunnel
   ```

2. **Prepare configuration:**
   ```bash
   mkdir config
   cp .env.example config/.env
   ```

3. **Setup SSH Key:**
   Place your private key in `config/id_rsa`.
   ```bash
   # For Linux/macOS
   chmod 600 config/id_rsa
   ```

---

## Configuration (`config/.env`)

| Variable | Default | Description |
| :--- | :--- | :--- |
| `SSH_HOST` | - | IP or Domain of your SSH server. |
| `SSH_PORT` | `22` | SSH port. |
| `SSH_USER` | `root` | SSH user (must have root privileges). |
| `SSH_DEBUG` | `0` | SSH Debug level: `0` (off), `1` (-v), `2` (-vv), `3` (-vvv). |
| `TUN_DEV` | `tun0` | Name of the tunnel device (e.g., `tun5`). |
| `TUN_MTU` | `1400` | MTU size. Lowering this helps if some websites fail to load. |
| `TUN_LOCAL_IP` | `10.0.0.1` | Internal IP for the local end of the tunnel. |
| `TUN_REMOTE_IP` | `10.0.0.2` | Internal IP for the remote end of the tunnel. |
| `EXCLUDE_CONTAINER` | - | IPs excluded inside WSL/Container (Include `SSH_HOST` here). |
| `EXCLUDE_HOST` | - | IPs excluded on Windows Host (Local networks, Server IP, etc). |

---

## Usage

### Windows (WSL2)
1. Open PowerShell as **Administrator**.
2. **Start Tunnel:**
   ```powershell
   .\scripts\tunnel.ps1 -Action Up
   ```
3. **Stop Tunnel:**
   ```powershell
   .\scripts\tunnel.ps1 -Action Down
   ```

### Linux
1. **Start Engine:**
   ```bash
   docker-compose up -d
   ```

---

## Logging Levels
The system uses a unified logging format for both the Docker engine and the host script:
- **[INFO]**: Standard initialization steps.
- **[SSH]**: Verbose output from the SSH client (visible if `SSH_DEBUG > 0`).
- **[SUCCESS]**: Confirmed connectivity or verified public IP.
- **[ERROR]**: Critical failures with automatic cleanup.

---

## How it Works
1. **Docker** establishes an SSH connection with a `-w 0:0` flag, creating a `tun0` interface on both local and remote sides.
2. **Entrypoint script** configures point-to-point IP addresses and sets the default route inside the container/WSL2.
3. **PowerShell script** (for Windows) lowers the priority of the physical network adapter and sets the WSL2 virtual interface as the primary gateway.
4. **NAT (IP Masquerading)** is applied inside WSL2 to forward Windows host traffic through the `tun0` interface.

---

## Troubleshooting

- **Detailed SSH Debugging**: If the connection fails, set `SSH_DEBUG=1` in your `.env`. This will pipe the full SSH handshake and authentication logs directly into your console.
- **Connection Timeout**: Ensure `SSH_HOST` is in both exclusion lists. If not, the SSH client will try to connect through itself, creating a loop.
- **MTU issues**: If websites hang or you see `channel 0: rcvd too much data` in logs, lower `TUN_MTU` (e.g., to `1300`) in `.env`.
- **WSL2 Not Found**: Ensure WSL2 is running by typing `wsl -l -v` in PowerShell.

---

## License
This project is open-source and available under the [MIT License](LICENSE).
