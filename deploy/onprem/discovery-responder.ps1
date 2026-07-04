<#
  Host-side LAN discovery responder for Dockerized Pointy backends (Windows).

  POS clients find their backend by broadcasting POINTY_DISCOVERY_V1 on UDP
  port 47777. UDP broadcasts never reach a container through Docker's published
  ports (Docker Desktop adds a VM boundary on top), so this responder runs on
  the HOST — registered as the 'PointyDiscoveryResponder' scheduled task by
  register-autostart.ps1. The reply only points the client at the API base URL;
  the client then fetches the full payload from GET /api/discovery/service/.

  Configuration (environment, all optional):
    POINTY_DISCOVERY_UDP_PORT      listen port           (default 47777)
    POINTY_DISCOVERY_API_PORT      advertised API port   (default 8000)
    POINTY_DISCOVERY_API_BASE_URL  full URL override, e.g. behind a proxy
#>
$ErrorActionPreference = "Continue"

$probe = "POINTY_DISCOVERY_V1"
$udpPort = if ($env:POINTY_DISCOVERY_UDP_PORT) { [int]$env:POINTY_DISCOVERY_UDP_PORT } else { 47777 }
$apiPort = if ($env:POINTY_DISCOVERY_API_PORT) { [int]$env:POINTY_DISCOVERY_API_PORT } else { 8000 }

function Write-Log($message) {
    Write-Host "[pointy-discovery] $message"
}

function Test-PrivateAddress([System.Net.IPAddress]$address) {
    if ($address.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) { return $false }
    $bytes = $address.GetAddressBytes()
    if ($bytes[0] -eq 10) { return $true }                                    # 10.0.0.0/8
    if ($bytes[0] -eq 172 -and $bytes[1] -ge 16 -and $bytes[1] -le 31) { return $true }  # 172.16/12
    if ($bytes[0] -eq 192 -and $bytes[1] -eq 168) { return $true }            # 192.168/16
    if ($bytes[0] -eq 169 -and $bytes[1] -eq 254) { return $true }            # link-local
    if ($bytes[0] -eq 127) { return $true }                                   # loopback
    return $false
}

function Get-LocalHostForPeer([string]$peer) {
    # The IP of the host interface that faces this peer (multi-NIC safe).
    try {
        $probeSocket = New-Object System.Net.Sockets.UdpClient
        try {
            $probeSocket.Connect($peer, 9)
            return $probeSocket.Client.LocalEndPoint.Address.ToString()
        } finally {
            $probeSocket.Close()
        }
    } catch {
        return "127.0.0.1"
    }
}

function Get-PayloadForPeer([string]$peer) {
    $override = "$env:POINTY_DISCOVERY_API_BASE_URL".Trim()
    if ($override) {
        $backendUrl = $override.TrimEnd('/')
        if ($backendUrl.EndsWith('/api')) { $backendUrl = $backendUrl.Substring(0, $backendUrl.Length - 4).TrimEnd('/') }
    } else {
        $backendUrl = "http://$(Get-LocalHostForPeer $peer):$apiPort"
    }
    # Minimal shape of the backend's own discovery payload: the client only
    # reads service + api_base_url from UDP, then fetches the full payload
    # from the backend over HTTP.
    $payload = [ordered]@{
        service                 = "pointy-backend"
        version                 = 1
        shop_name               = ""
        backend_url             = $backendUrl
        api_base_url            = "$backendUrl/api"
        api_path                = "/api"
        pairing_path            = "/api/relay/pairing/"
        installation_id         = ""
        remote_access_supported = $false
        relay_public_api_url    = ""
        connector_last_seen_at  = $null
    }
    return [System.Text.Encoding]::UTF8.GetBytes(($payload | ConvertTo-Json -Compress))
}

while ($true) {
    $server = $null
    try {
        $server = New-Object System.Net.Sockets.UdpClient
        $server.Client.SetSocketOption(
            [System.Net.Sockets.SocketOptionLevel]::Socket,
            [System.Net.Sockets.SocketOptionName]::ReuseAddress, $true)
        $server.Client.Bind([System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any, $udpPort))
        Write-Log "listening on udp/$udpPort"
        $remote = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)
        while ($true) {
            $data = $server.Receive([ref]$remote)
            $text = [System.Text.Encoding]::UTF8.GetString($data).Trim()
            if ($text -ne $probe) { continue }
            if (-not (Test-PrivateAddress $remote.Address)) { continue }
            try {
                $reply = Get-PayloadForPeer $remote.Address.ToString()
                [void]$server.Send($reply, $reply.Length, $remote)
            } catch {
                Write-Log "reply to $($remote.Address) failed: $($_.Exception.Message)"
            }
        }
    } catch {
        # Port busy or interface flap: keep trying — this process is run-forever.
        Write-Log "socket error: $($_.Exception.Message); retrying in 10s"
        Start-Sleep -Seconds 10
    } finally {
        if ($server) { $server.Close() }
    }
}
