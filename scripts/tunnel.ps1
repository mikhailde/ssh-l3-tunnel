param ([ValidateSet("Up", "Down")]$Action = "Up")

# Check for Admin rights
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(544)) {
    Write-Error "Admin rights required!"; exit
}

# Logger function
function Write-Log([string]$Msg, [string]$Level = "INFO") {
    $Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $Color = switch ($Level) {
        "SUCCESS" { "Green" }
        "ERROR"   { "Red" }
        "WARN"    { "Yellow" }
        "SSH"     { "Cyan" }
        default   { "Gray" }
    }
    Write-Host "$Timestamp [$Level] $Msg" -ForegroundColor $Color
}

# Parse .env file
$env = @{}
if (Test-Path "$PSScriptRoot/../config/.env") {
    Get-Content "$PSScriptRoot/../config/.env" | Where-Object { $_ -match '=' } | ForEach-Object {
        $k,$v = $_.Split('=', 2); $env[$k.Trim()] = $v.Trim().Trim("'").Trim('"')
    }
}

$tunDev = if ($env.TUN_DEV) { $env.TUN_DEV } else { "tun0" }
$targets = ($env.EXCLUDE_HOST -split ',' | Where-Object { $_ }).Trim()
$wslIp = (wsl hostname -I).Trim().Split(' ')[0]
$wslIdx = (Get-NetIPInterface -InterfaceAlias *WSL* -AddressFamily IPv4 | Select-Object -First 1).InterfaceIndex
$main = Get-NetRoute -DestinationPrefix "0.0.0.0/0" | Where-Object { $_.InterfaceIndex -ne $wslIdx } | Sort-Object RouteMetric | Select-Object -First 1
$mainIdx, $mainGw = $main.InterfaceIndex, $main.NextHop

# Route and Interface Metric management
function Set-Routes($gw, $routeAction) {
    if ($routeAction -eq "Up") {
        Set-NetIPInterface -InterfaceIndex $mainIdx -InterfaceMetric 1000 -AutomaticMetric Disabled | Out-Null
        Set-NetIPInterface -InterfaceIndex $wslIdx -InterfaceMetric 1 -AutomaticMetric Disabled | Out-Null
        Get-NetRoute -DestinationPrefix "0.0.0.0/0" -InterfaceIndex $wslIdx -EA 0 | Remove-NetRoute -Confirm:0 | Out-Null
        New-NetRoute -DestinationPrefix "0.0.0.0/0" -NextHop $gw -InterfaceIndex $wslIdx -RouteMetric 0 -Confirm:0 | Out-Null
    } else {
        Set-NetIPInterface -InterfaceIndex $mainIdx -AutomaticMetric Enabled | Out-Null
        Set-NetIPInterface -InterfaceIndex $wslIdx -AutomaticMetric Enabled | Out-Null
        Get-NetRoute -DestinationPrefix "0.0.0.0/0" -InterfaceIndex $wslIdx -EA 0 | Remove-NetRoute -Confirm:0 | Out-Null
    }
}

# Public IP verification helper
function Verify-IP {
    Write-Log "Verifying public IP..." "INFO"
    $ip = $null
    for ($i = 1; $i -le 6; $i++) {
        $ip = curl.exe -s --max-time 2 ifconfig.me 2>$null
        if ($ip) { break }
        Start-Sleep -Milliseconds 500
    }

    if ($ip) { Write-Log "External IP: $ip" "SUCCESS" }
    else { Write-Log "Could not verify External IP" "ERROR" }
}

# Centralized cleanup logic
function Stop-Tunnel {
    Write-Log "Stopping tunnel and restoring network..." "WARN"
    wsl -u root bash -c "
        iptables -D FORWARD -i $tunDev -j ACCEPT 2>/dev/null;
        iptables -D FORWARD -o $tunDev -j ACCEPT 2>/dev/null;
        iptables -t nat -D POSTROUTING -o $tunDev -j MASQUERADE 2>/dev/null
    " | Out-Null
    Set-Routes "" "Down"
    foreach ($t in $targets) { $null = route delete $t 2>$null }
    wsl bash -c "docker compose down" | Out-Null
    Write-Log "Cleanup complete." "SUCCESS"
    Verify-IP
}

# Main routing setup/teardown
if ($Action -eq "Up") {
    Write-Log "Starting Tunnel Process..." "INFO"
    
    # Start the Docker container
    $null = wsl bash -c "docker compose up -d 2>&1"

    Write-Log "Waiting for engine initialization..." "INFO"
    $ready = $false
    $timeout = 10
    $start = Get-Date
    $lastSeenLine = 0

    # Real-time log streaming from Docker to PowerShell
    while (((Get-Date) - $start).TotalSeconds -lt $timeout) {
        $allLogs = wsl docker logs ssh-tunnel 2>$null
        $lines = $allLogs -split "`n"
        if ($lines.Count -gt $lastSeenLine) {
            for ($i = $lastSeenLine; $i -lt $lines.Count; $i++) {
                $line = $lines[$i].Trim()
                if ($line -match "\[INFO\]|\[SSH\]|\[ERROR\]|\[SUCCESS\]") {
                    if ($line -match "\[SSH\]") { Write-Log ($line -replace ".*\[SSH\]", "Container:") "SSH" }
                    elseif ($line -match "\[ERROR\]") { Write-Log ($line -replace ".*\[ERROR\]", "Container:") "ERROR" }
                    elseif ($line -match "\[SUCCESS\]") { Write-Log "Engine reported: READY" "SUCCESS"; $ready = $true }
                    else { Write-Log ($line -replace ".*\[INFO\]", "Container:") "INFO" }
                }
            }
            $lastSeenLine = $lines.Count
        }
        if ($ready) { break }
        Start-Sleep -Milliseconds 500
    }

    if (-not $ready) {
        Write-Log "Tunnel engine failed to start or timeout reached." "ERROR"
        exit
    }

    Write-Log "Applying WSL2 NAT rules..." "INFO"
    wsl -u root bash -c "
        sysctl -w net.ipv4.ip_forward=1 >/dev/null;
        iptables -C FORWARD -i $tunDev -j ACCEPT 2>/dev/null || iptables -I FORWARD -i $tunDev -j ACCEPT;
        iptables -C FORWARD -o $tunDev -j ACCEPT 2>/dev/null || iptables -I FORWARD -o $tunDev -j ACCEPT;
        iptables -t nat -C POSTROUTING -o $tunDev -j MASQUERADE 2>/dev/null || \
        iptables -t nat -A POSTROUTING -o $tunDev -j MASQUERADE
    " | Out-Null

    # Configure Host Exclusions
    $hostExcl = if ($env.EXCLUDE_HOST) { $env.EXCLUDE_HOST } else { "none" }
    Write-Log "Configuring Windows Host routes (Exclusions: $hostExcl)..." "INFO"
    foreach ($t in $targets) { $null = route add $t mask 255.255.255.255 $mainGw metric 1 2>$null }
    Set-Routes $wslIp "Up"

    # Verify tunnel IP before starting loop
    Verify-IP

    # Sleep loop
    try {
        Write-Log "Tunnel is UP and running. Press Ctrl+C to stop tunnel and restore network." "SUCCESS"
        while ($true) {
            Start-Sleep -Seconds 1
        }
    }
    finally {
        # Executes when Ctrl+C is pressed
        Write-Log "Script stopped." "INFO"
        Stop-Tunnel
    }
}
else {
    Stop-Tunnel
}
