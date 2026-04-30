param ([ValidateSet("Up", "Down")]$Action = "Up")

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(544)) {
    Write-Error "Admin rights required!"; exit
}

$env = @{}
if (Test-Path "$PSScriptRoot/../config/.env") {
    Get-Content "$PSScriptRoot/../config/.env" | Where-Object { $_ -match '=' } | ForEach-Object {
        $k,$v = $_.Split('=', 2); $env[$k.Trim()] = $v.Trim().Trim("'").Trim('"')
    }
}

$targets = ($env.HOST_EXCLUDE_IPS -split ',' | Where-Object { $_ }).Trim()
$wslIp = (wsl hostname -I).Trim().Split(' ')[0]
$wslIdx = (Get-NetIPInterface -InterfaceAlias *WSL* -AddressFamily IPv4 | Select-Object -First 1).InterfaceIndex
$main = Get-NetRoute -DestinationPrefix "0.0.0.0/0" | Sort-Object RouteMetric | Select-Object -First 1
$mainIdx, $mainGw = $main.InterfaceIndex, $main.NextHop

function Set-Routes($gw) {
    if ($Action -eq "Up") {
        Set-NetIPInterface -InterfaceIndex $mainIdx -InterfaceMetric 1000
        Set-NetIPInterface -InterfaceIndex $wslIdx -InterfaceMetric 1
        Get-NetRoute -DestinationPrefix "0.0.0.0/0" -InterfaceIndex $wslIdx -EA 0 | Remove-NetRoute -Confirm:0
        New-NetRoute -DestinationPrefix "0.0.0.0/0" -NextHop $gw -InterfaceIndex $wslIdx -RouteMetric 0 -Confirm:0
    } else {
        Set-NetIPInterface -InterfaceIndex $mainIdx -InterfaceMetric 0
        Set-NetIPInterface -InterfaceIndex $wslIdx -InterfaceMetric 5000
        Get-NetRoute -DestinationPrefix "0.0.0.0/0" -InterfaceIndex $wslIdx -EA 0 | Remove-NetRoute -Confirm:0
    }
}

if ($Action -eq "Up") {
    Write-Host ">>> STARTING TUNNEL <<<" -Fore Cyan
    
    if (-not (wsl docker ps -q -f name=ssh-tunnel)) {
        wsl bash -c "docker compose up -d"
        
        Write-Host "Waiting for tun0..." -NoNewline
        for ($i=0; $i -lt 30; $i++) {
            if (wsl docker exec ssh-tunnel ip link show tun0 2>$null) { 
                Write-Host " Ready!" -Fore Green; break 
            }
            Write-Host "." -NoNewline
            Start-Sleep -Milliseconds 500
        }
    }

    wsl -u root bash -c "
        sysctl -w net.ipv4.ip_forward=1 >/dev/null;
        iptables -C FORWARD -i tun0 -j ACCEPT 2>/dev/null || iptables -I FORWARD -i tun0 -j ACCEPT;
        iptables -C FORWARD -o tun0 -j ACCEPT 2>/dev/null || iptables -I FORWARD -o tun0 -j ACCEPT;
        iptables -t nat -C POSTROUTING -o tun0 -j MASQUERADE 2>/dev/null || \
        iptables -t nat -A POSTROUTING -o tun0 -j MASQUERADE
    "

    foreach ($t in $targets) { route add $t mask 255.255.255.255 $mainGw metric 1 2>$null }
    Set-Routes $wslIp
}
else {
    Write-Host ">>> STOPPING <<<" -Fore Cyan
    wsl -u root bash -c "
        iptables -D FORWARD -i tun0 -j ACCEPT 2>/dev/null;
        iptables -D FORWARD -o tun0 -j ACCEPT 2>/dev/null;
        iptables -t nat -D POSTROUTING -o tun0 -j MASQUERADE 2>/dev/null
    "
    Set-Routes ""
    foreach ($t in $targets) { route delete $t 2>$null }
}

Write-Host "Done. Verifying connection..." -ForegroundColor Gray

$ip = $null
for ($i = 1; $i -le 10; $i++) {
    $ip = curl.exe -s --max-time 2 ifconfig.me 2>$null
    if ($ip) { break }
    Start-Sleep -Milliseconds 500
}

Write-Host "Public IP: " -NoNewline -ForegroundColor Green
if ($ip) { Write-Host $ip -ForegroundColor Green } else { Write-Host "Timeout" -ForegroundColor Red }
Write-Host ""
