<#
.SYNOPSIS
    Identify a DVR/NVR on the shop LAN and report what Pointy can do with it.

.DESCRIPTION
    A standalone copy of `manage.py probe_recorder`, for the case that command
    cannot cover: standing in a shop with a USB stick and no Pointy installed.
    Windows PowerShell 5.1 is on every Windows machine since 7, so this needs
    nothing installed, nothing downloaded, and no admin rights.

    It answers the two questions that decide everything, and that a photo of
    the recorder's web page cannot:

      1. What is this box really? "XVR 5.0" on a login screen is not a brand —
         it is Dahua's hybrid product line AND the web UI title on a good share
         of Xiongmai/Hisilicon OEM boxes. They need different drivers.
      2. What will Pointy be able to do with it? Live video is nearly always
         possible; recording search — which is what invoice-linked footage and
         playback rest on — is not, and it is the one worth knowing before
         promising anything.

    Read-only. It opens sockets, asks each dialect who it is, and prints the
    answer. It never writes to the recorder and never changes a setting.

    IDENTIFICATION NEEDS NO PASSWORD. Each brand guards one path the others
    404, and answers it with an authentication challenge — so *which* path
    challenges is the fingerprint, whether or not the password is right. Give
    credentials and it goes further: model, firmware, and the channel list.

.PARAMETER RecorderHost
    The recorder's address, e.g. 192.168.1.108.

.PARAMETER Scan
    No address known? Sweep the local /24 for recorders and list candidates.

.PARAMETER Username
    Defaults to admin, which is what these boxes ship with.

.PARAMETER Password
    Optional. Without it you still get the brand; with it you get the details.

.PARAMETER Json
    Emit JSON instead of a report, for pasting back into an issue or a chat.

.EXAMPLE
    .\Probe-Recorder.ps1 -Scan

.EXAMPLE
    .\Probe-Recorder.ps1 -RecorderHost 192.168.1.108 -Password 'secret'

.NOTES
    If Windows refuses to run it ("running scripts is disabled"), this does not
    need an execution-policy change and does not need admin:

        powershell -ExecutionPolicy Bypass -File .\Probe-Recorder.ps1 -Scan
#>

[CmdletBinding(DefaultParameterSetName = 'Probe')]
param(
    [Parameter(ParameterSetName = 'Probe', Position = 0, Mandatory = $true)]
    [Alias('Host', 'Address', 'IP')]
    [string] $RecorderHost,

    [Parameter(ParameterSetName = 'Scan', Mandatory = $true)]
    [switch] $Scan,

    [string] $Username = 'admin',
    [string] $Password = '',
    [int]    $Port = 80,
    [int]    $RtspPort = 554,
    [int]    $TimeoutMs = 4000,
    [switch] $Json
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

# DVRs ship self-signed certificates and speak old TLS. Refusing them here
# would mean refusing the device we came to identify.
try {
    [System.Net.ServicePointManager]::SecurityProtocol =
        [System.Net.SecurityProtocolType]::Tls12 -bor
        [System.Net.SecurityProtocolType]::Tls11 -bor
        [System.Net.SecurityProtocolType]::Tls
} catch { }
[System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }

#: Ports worth knowing about. 34567 is the one that matters most: it is
#: unassigned, Xiongmai's own, and open on almost nothing else — so it is a
#: fingerprint on its own, where 80 tells you nothing.
$script:PortsOfInterest = @(
    @{ Port = 80;    What = 'HTTP (Hikvision ISAPI / Dahua CGI)' }
    @{ Port = 8000;  What = 'HTTP alternate' }
    @{ Port = 8080;  What = 'HTTP alternate / ONVIF' }
    @{ Port = 8899;  What = 'ONVIF on several OEM firmwares' }
    @{ Port = 554;   What = 'RTSP (the video itself)' }
    @{ Port = 34567; What = 'Xiongmai DVRIP — its own protocol' }
)

#: What each Pointy driver can do, mirroring drivers/*.py. Keep in step with
#: `supports_search` / `supports_playback` / `supports_snapshot` there.
$script:Capabilities = @{
    'hikvision'    = @{ Live = $true; Snapshot = $true;  Search = $true;  Playback = $true }
    'dahua'        = @{ Live = $true; Snapshot = $true;  Search = $true;  Playback = $true }
    'xiongmai'     = @{ Live = $true; Snapshot = $false; Search = $true;  Playback = $true }
    'onvif'        = @{ Live = $true; Snapshot = $true;  Search = $null;  Playback = $null }
    'generic_rtsp' = @{ Live = $true; Snapshot = $false; Search = $false; Playback = $false }
}

# ---------------------------------------------------------------------------
# Plumbing
# ---------------------------------------------------------------------------

function Test-TcpPort {
    param([string] $Address, [int] $TcpPort, [int] $Milliseconds = 700)
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $async = $client.BeginConnect($Address, $TcpPort, $null, $null)
        if (-not $async.AsyncWaitHandle.WaitOne($Milliseconds, $false)) { return $false }
        $client.EndConnect($async)
        return $true
    } catch {
        return $false
    } finally {
        $client.Close()
    }
}

function Invoke-DeviceRequest {
    <#
      One HTTP request to the device, returning status, body and the
      authentication challenge. A 401 is NOT an error here — it is the most
      useful answer a device can give without a password, because only the
      brand that owns a path will challenge on it.
    #>
    param(
        [string] $Url,
        [string] $Method = 'GET',
        [string] $Body = $null,
        [string] $ContentType = $null,
        [switch] $Authenticate
    )
    $result = [ordered]@{
        Ok = $false; Status = 0; Body = ''; Challenge = ''; Error = ''
    }
    try {
        $request = [System.Net.HttpWebRequest]::Create($Url)
        $request.Method = $Method
        $request.Timeout = $TimeoutMs
        $request.ReadWriteTimeout = $TimeoutMs
        $request.AllowAutoRedirect = $false
        $request.UserAgent = 'Pointy-Probe/1.0'
        if ($Authenticate) {
            $uri = New-Object System.Uri($Url)
            $credential = New-Object System.Net.NetworkCredential($Username, $Password)
            $cache = New-Object System.Net.CredentialCache
            # Digest is what these boxes ship with; a few accept Basic. Offering
            # both costs nothing, because .NET only uses the one the device asks
            # for in its challenge.
            $cache.Add($uri, 'Digest', $credential)
            $cache.Add($uri, 'Basic', $credential)
            $request.Credentials = $cache
        }
        if ($Body) {
            $request.ContentType = $ContentType
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($Body)
            $request.ContentLength = $bytes.Length
            $stream = $request.GetRequestStream()
            $stream.Write($bytes, 0, $bytes.Length)
            $stream.Close()
        }
        $response = $request.GetResponse()
        $reader = New-Object System.IO.StreamReader($response.GetResponseStream())
        $result.Body = $reader.ReadToEnd()
        $reader.Close()
        $result.Status = [int] $response.StatusCode
        $result.Ok = $true
        $response.Close()
    } catch [System.Net.WebException] {
        $webError = $_.Exception
        if ($webError.Response) {
            $result.Status = [int] $webError.Response.StatusCode
            $result.Challenge = [string] $webError.Response.Headers['WWW-Authenticate']
            try {
                $reader = New-Object System.IO.StreamReader($webError.Response.GetResponseStream())
                $result.Body = $reader.ReadToEnd()
                $reader.Close()
            } catch { }
        }
        $result.Error = $webError.Message
    } catch {
        $result.Error = $_.Exception.Message
    }
    return $result
}

function Test-BodyIsFromDevice {
    <#
      A 200 is only believed if the body looks like the endpoint's own answer.
      Routers, and DVRs behind a captive login, answer *every* path with their
      login page — so status alone identifies nothing, and trusting it is how
      every address on the subnet becomes "a Dahua".
    #>
    param([string] $Body, [string[]] $Markers)
    if (-not $Body) { return $false }
    foreach ($marker in $Markers) {
        if ($Body.IndexOf($marker, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
            return $true
        }
    }
    return $false
}

function Get-SofiaHash {
    <#
      Xiongmai's own password digest: eight characters folded out of an MD5.
      Not a standard construction and not a strong one, but it is what the
      firmware compares against. Mirrors `sofia_hash` in drivers/xiongmai.py.
      The plaintext password never goes on the wire.
    #>
    param([string] $Secret)
    $md5 = [System.Security.Cryptography.MD5]::Create()
    try {
        $digest = $md5.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Secret))
    } finally {
        $md5.Dispose()
    }
    $alphabet = '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz'
    $out = New-Object System.Text.StringBuilder
    for ($i = 0; $i -lt 8; $i++) {
        $sum = [int] $digest[2 * $i] + [int] $digest[2 * $i + 1]
        [void] $out.Append($alphabet[$sum % 62])
    }
    return $out.ToString()
}

# ---------------------------------------------------------------------------
# The four dialects
# ---------------------------------------------------------------------------

function Test-Hikvision {
    param([string] $Address, [int] $HttpPort)
    $url = "http://${Address}:${HttpPort}/ISAPI/System/deviceInfo"
    $answer = Invoke-DeviceRequest -Url $url -Authenticate
    $found = [ordered]@{ Brand = ''; Model = ''; Firmware = ''; Serial = ''
                         Channels = 0; Detail = ''; Challenged = $false }
    if ($answer.Status -eq 401) {
        $found.Challenged = $true
        $found.Brand = 'hikvision'
        $found.Detail = 'ISAPI challenged for a password, which only a Hikvision-dialect box does.'
        return $found
    }
    if (-not (Test-BodyIsFromDevice $answer.Body @('<DeviceInfo', '<ResponseStatus'))) {
        return $null
    }
    $found.Brand = 'hikvision'
    try {
        $xml = [xml] $answer.Body
        $info = $xml.DocumentElement
        $found.Model    = [string] $info.model
        $found.Firmware = [string] $info.firmwareVersion
        $found.Serial   = [string] $info.serialNumber
        foreach ($tag in @('videoInputPortNums', 'channelNums', 'analogChannelNums')) {
            $raw = [string] $info.$tag
            if ($raw -match '^\d+$' -and [int] $raw -gt $found.Channels) {
                $found.Channels = [int] $raw
            }
        }
    } catch {
        $found.Detail = 'Answered ISAPI but the XML could not be read.'
    }
    return $found
}

function Test-Dahua {
    param([string] $Address, [int] $HttpPort)
    $url = "http://${Address}:${HttpPort}/cgi-bin/magicBox.cgi?action=getSystemInfo"
    $answer = Invoke-DeviceRequest -Url $url -Authenticate
    $found = [ordered]@{ Brand = ''; Model = ''; Firmware = ''; Serial = ''
                         Channels = 0; Detail = ''; Challenged = $false }
    if ($answer.Status -eq 401) {
        $found.Challenged = $true
        $found.Brand = 'dahua'
        $found.Detail = 'The Dahua CGI challenged for a password, which only a Dahua-dialect box does.'
        return $found
    }
    if (-not (Test-BodyIsFromDevice $answer.Body @('deviceType=', 'serialNumber=', 'processor='))) {
        return $null
    }
    $found.Brand = 'dahua'
    $pairs = @{}
    foreach ($line in ($answer.Body -split "`r?`n")) {
        if ($line -match '^\s*([^=]+)=(.*)$') { $pairs[$matches[1].Trim()] = $matches[2].Trim() }
    }
    if ($pairs.ContainsKey('deviceType')) { $found.Model = $pairs['deviceType'] }
    elseif ($pairs.ContainsKey('processor')) { $found.Model = $pairs['processor'] }
    if ($pairs.ContainsKey('serialNumber')) { $found.Serial = $pairs['serialNumber'] }

    $version = Invoke-DeviceRequest -Authenticate `
        -Url "http://${Address}:${HttpPort}/cgi-bin/magicBox.cgi?action=getSoftwareVersion"
    if ($version.Ok -and $version.Body -match 'version=([^\r\n,]+)') {
        $found.Firmware = $matches[1].Trim()
    }
    return $found
}

function Test-Xiongmai {
    <#
      Spoken natively on TCP 34567 — the port the XMEye phone app uses. A
      20-byte binary header frames a JSON body; the password is a sofia_hash.
      Mirrors the handshake in drivers/xiongmai.py.
    #>
    param([string] $Address)
    if (-not (Test-TcpPort -Address $Address -TcpPort 34567 -Milliseconds $TimeoutMs)) {
        return $null
    }
    $found = [ordered]@{ Brand = 'xiongmai'; Model = ''; Firmware = ''; Serial = ''
                         Channels = 0; Detail = ''; Challenged = $false }
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $async = $client.BeginConnect($Address, 34567, $null, $null)
        if (-not $async.AsyncWaitHandle.WaitOne($TimeoutMs, $false)) { return $found }
        $client.EndConnect($async)
        $client.ReceiveTimeout = $TimeoutMs
        $client.SendTimeout = $TimeoutMs
        $stream = $client.GetStream()

        function Send-Dvrip {
            param($NetStream, [int] $SessionId, [int] $Sequence, [int] $MessageId, [string] $JsonBody)
            $payload = [System.Text.Encoding]::UTF8.GetBytes($JsonBody) + @(0x0A, 0x00)
            $header = New-Object byte[] 20
            $header[0] = 0xFF
            [Array]::Copy([BitConverter]::GetBytes([uint32] $SessionId), 0, $header, 4, 4)
            [Array]::Copy([BitConverter]::GetBytes([uint32] $Sequence),  0, $header, 8, 4)
            [Array]::Copy([BitConverter]::GetBytes([uint16] $MessageId), 0, $header, 14, 2)
            [Array]::Copy([BitConverter]::GetBytes([uint32] $payload.Length), 0, $header, 16, 4)
            $NetStream.Write($header, 0, 20)
            $NetStream.Write($payload, 0, $payload.Length)
            $NetStream.Flush()
        }

        function Receive-Dvrip {
            param($NetStream)
            $header = New-Object byte[] 20
            $read = 0
            while ($read -lt 20) {
                $chunk = $NetStream.Read($header, $read, 20 - $read)
                if ($chunk -le 0) { return $null }
                $read += $chunk
            }
            $length = [BitConverter]::ToUInt32($header, 16)
            if ($length -le 0 -or $length -gt 4MB) { return $null }
            $body = New-Object byte[] $length
            $read = 0
            while ($read -lt $length) {
                $chunk = $NetStream.Read($body, $read, $length - $read)
                if ($chunk -le 0) { break }
                $read += $chunk
            }
            return ([System.Text.Encoding]::UTF8.GetString($body, 0, $read)).Trim([char]0, [char]10)
        }

        $login = @{
            EncryptType = 'MD5'
            LoginType   = 'DVRIP-Web'
            UserName    = $Username
            PassWord    = (Get-SofiaHash $Password)
        } | ConvertTo-Json -Compress
        Send-Dvrip $stream 0 0 1000 $login
        $reply = Receive-Dvrip $stream
        if (-not $reply) {
            $found.Detail = 'Port 34567 is open but the box did not answer its own protocol.'
            return $found
        }
        $parsed = $reply | ConvertFrom-Json
        $sessionHex = [string] $parsed.SessionID
        $sessionId = 0
        if ($sessionHex) { $sessionId = [Convert]::ToInt32($sessionHex.Replace('0x', ''), 16) }
        if (-not $sessionId) {
            $found.Detail = 'Speaks Xiongmai DVRIP, but refused these credentials.'
            $found.Challenged = $true
            return $found
        }
        Send-Dvrip $stream $sessionId 1 1020 (@{ Name = 'SystemInfo' } | ConvertTo-Json -Compress)
        $sysinfo = Receive-Dvrip $stream
        if ($sysinfo) {
            $system = ($sysinfo | ConvertFrom-Json).SystemInfo
            if ($system) {
                $found.Model    = [string] $system.DeviceModel
                $found.Firmware = [string] $system.SoftWareVersion
                $found.Serial   = [string] $system.SerialNo
                if ($system.PSObject.Properties.Name -contains 'VideoInChannel') {
                    $found.Channels = [int] $system.VideoInChannel
                }
            }
        }
    } catch {
        $found.Detail = "Port 34567 is open but the handshake failed: $($_.Exception.Message)"
    } finally {
        $client.Close()
    }
    return $found
}

function Test-Onvif {
    <#
      Last, and deliberately so: a Hikvision and a Xiongmai both also speak
      ONVIF, and calling either of them "ONVIF" would trade their recording
      search away for nothing. GetSystemDateAndTime is the probe because ONVIF
      requires it to work WITHOUT credentials — so a wrong password cannot be
      mistaken for a wrong path.
    #>
    param([string] $Address, [int[]] $CandidatePorts)
    $paths = @('/onvif/device_service', '/onvif/Device', '/onvif/services', '/onvif/device')
    $envelope = @'
<?xml version="1.0" encoding="UTF-8"?>
<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope"
            xmlns:tds="http://www.onvif.org/ver10/device/wsdl">
  <s:Body><tds:GetSystemDateAndTime/></s:Body>
</s:Envelope>
'@
    foreach ($onvifPort in $CandidatePorts) {
        foreach ($path in $paths) {
            $url = "http://${Address}:${onvifPort}${path}"
            $answer = Invoke-DeviceRequest -Url $url -Method 'POST' -Body $envelope `
                -ContentType 'application/soap+xml; charset=utf-8'
            if (Test-BodyIsFromDevice $answer.Body @('GetSystemDateAndTimeResponse')) {
                return [ordered]@{
                    Brand = 'onvif'; Model = ''; Firmware = ''; Serial = ''
                    Channels = 0; Challenged = $false
                    Detail = "Answered ONVIF on ${path} (port ${onvifPort})."
                }
            }
        }
    }
    return $null
}

# ---------------------------------------------------------------------------
# Reporting
# ---------------------------------------------------------------------------

function Get-RecorderReport {
    param([string] $Address)

    $openPorts = @()
    foreach ($entry in $script:PortsOfInterest) {
        if (Test-TcpPort -Address $Address -TcpPort $entry.Port) {
            $openPorts += [pscustomobject]@{ Port = $entry.Port; What = $entry.What }
        }
    }

    # Order matches drivers/registry.py: Hikvision, Dahua, Xiongmai, ONVIF.
    $identity = $null
    $httpPorts = @($Port) + @(80, 8000, 8080, 8899 | Where-Object { $_ -ne $Port })
    $httpPorts = $httpPorts | Where-Object { $openPorts.Port -contains $_ } | Select-Object -Unique
    foreach ($httpPort in $httpPorts) {
        $identity = Test-Hikvision -Address $Address -HttpPort $httpPort
        if ($identity) { break }
        $identity = Test-Dahua -Address $Address -HttpPort $httpPort
        if ($identity) { break }
    }
    if (-not $identity) { $identity = Test-Xiongmai -Address $Address }
    if (-not $identity -and $httpPorts) { $identity = Test-Onvif -Address $Address -CandidatePorts $httpPorts }

    $brand = if ($identity) { $identity.Brand } else { '' }
    $rtspOpen = ($openPorts.Port -contains $RtspPort) -or ($openPorts.Port -contains 554)
    if (-not $brand -and $rtspOpen) {
        # No control protocol we understand, but a stream to point at: exactly
        # what generic_rtsp exists for. Live tiles and nothing more.
        $brand = 'generic_rtsp'
        $identity = [ordered]@{
            Brand = 'generic_rtsp'; Model = ''; Firmware = ''; Serial = ''; Channels = 0
            Challenged = $false
            Detail = 'No control protocol answered, but RTSP is open. Pointy can show live video if you supply the stream address.'
        }
    }

    return [pscustomobject]@{
        Host         = $Address
        Reachable    = ($openPorts.Count -gt 0)
        OpenPorts    = $openPorts
        Brand        = $brand
        Model        = if ($identity) { $identity.Model } else { '' }
        Firmware     = if ($identity) { $identity.Firmware } else { '' }
        Serial       = if ($identity) { $identity.Serial } else { '' }
        Channels     = if ($identity) { $identity.Channels } else { 0 }
        NeedsPassword= if ($identity) { [bool] $identity.Challenged } else { $false }
        Detail       = if ($identity) { [string] $identity.Detail } else { '' }
        Capabilities = if ($brand) { $script:Capabilities[$brand] } else { $null }
    }
}

function Write-Report {
    param($Report)

    function Write-Field { param($Label, $Value)
        Write-Host ("  {0,-14} {1}" -f $Label, $Value) }

    Write-Host ''
    if (-not $Report.Reachable) {
        Write-Host "NOTHING ANSWERED at $($Report.Host)" -ForegroundColor Red
        Write-Host '  Check the address, that the recorder is powered on, and that this'
        Write-Host '  PC is on the same network as the cameras (not a guest wifi).'
        return
    }

    Write-Host "OPEN PORTS on $($Report.Host)" -ForegroundColor Cyan
    foreach ($entry in $Report.OpenPorts) {
        Write-Host ("  {0,-6} {1}" -f $entry.Port, $entry.What)
    }

    Write-Host ''
    if (-not $Report.Brand) {
        Write-Host 'NOT IDENTIFIED' -ForegroundColor Yellow
        Write-Host '  Something is answering, but it speaks none of the dialects Pointy'
        Write-Host '  knows and has no open RTSP port. If this really is the recorder,'
        Write-Host '  send this output on — it is the useful half of the answer.'
        return
    }

    Write-Host 'IDENTIFIED' -ForegroundColor Green
    Write-Field 'driver'   $Report.Brand
    Write-Field 'model'    $(if ($Report.Model)    { $Report.Model }    else { '—' })
    Write-Field 'firmware' $(if ($Report.Firmware) { $Report.Firmware } else { '—' })
    Write-Field 'serial'   $(if ($Report.Serial)   { $Report.Serial }   else { '—' })
    Write-Field 'channels' $(if ($Report.Channels) { $Report.Channels } else { '—' })
    if ($Report.Detail) { Write-Host "  $($Report.Detail)" -ForegroundColor DarkGray }
    if ($Report.NeedsPassword) {
        Write-Host ''
        Write-Host '  The brand is certain, the details are not: run again with' -ForegroundColor Yellow
        Write-Host '  -Password to get the model, firmware and channel list.' -ForegroundColor Yellow
    }

    Write-Host ''
    Write-Host 'WHAT POINTY CAN DO WITH IT' -ForegroundColor Cyan
    $caps = $Report.Capabilities
    $rows = @(
        @{ Label = 'live video';      Able = $caps.Live;     Note = 'camera tiles on the till' }
        @{ Label = 'snapshots';       Able = $caps.Snapshot; Note = 'live view without ffmpeg' }
        @{ Label = 'recording search';Able = $caps.Search;   Note = 'needed for invoice footage' }
        @{ Label = 'playback';        Able = $caps.Playback; Note = 'watching a sale back' }
    )
    foreach ($row in $rows) {
        if ($null -eq $row.Able) {
            $mark = 'maybe'; $colour = 'Yellow'
        } elseif ($row.Able) {
            $mark = 'yes  '; $colour = 'Green'
        } else {
            $mark = 'no   '; $colour = 'Red'
        }
        Write-Host ("  {0,-18} " -f $row.Label) -NoNewline
        Write-Host $mark -ForegroundColor $colour -NoNewline
        Write-Host "  $($row.Note)"
    }
    if ($Report.Brand -eq 'onvif') {
        Write-Host ''
        Write-Host '  ONVIF boxes differ: search and playback depend on whether this one' -ForegroundColor DarkGray
        Write-Host '  exposes the Replay and Search services. Pointy settles that when' -ForegroundColor DarkGray
        Write-Host '  the recorder is added.' -ForegroundColor DarkGray
    }
    Write-Host ''
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

if ($PSCmdlet.ParameterSetName -eq 'Scan') {
    $local = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' } |
        Select-Object -First 1
    if (-not $local) { throw 'Could not work out this PC''s address. Pass -RecorderHost instead.' }
    $prefix = ($local.IPAddress -split '\.')[0..2] -join '.'

    Write-Host ''
    Write-Host "Sweeping ${prefix}.1-254 for recorders (this takes about a minute)…" -ForegroundColor Cyan
    Write-Host 'A recorder is a host with 34567, 554, or an 80/8000/8080/8899 that answers a camera dialect.'
    Write-Host ''

    $candidates = @()
    foreach ($octet in 1..254) {
        $address = "$prefix.$octet"
        Write-Progress -Activity 'Scanning the local network' -Status $address `
            -PercentComplete (($octet / 254) * 100)
        # Two cheap, specific ports first. Sweeping every host with the full
        # probe would take an hour; almost every recorder answers one of these.
        $looksLikely = (Test-TcpPort -Address $address -TcpPort 34567 -Milliseconds 250) -or
                       (Test-TcpPort -Address $address -TcpPort 554   -Milliseconds 250)
        if (-not $looksLikely) {
            if (-not (Test-TcpPort -Address $address -TcpPort 80 -Milliseconds 250)) { continue }
            # Port 80 alone is almost always a router or a printer, so it only
            # earns a full probe, never a mention on its own.
        }
        $candidates += $address
    }
    Write-Progress -Activity 'Scanning the local network' -Completed

    if (-not $candidates) {
        Write-Host 'No candidates found. Is this PC on the same network as the cameras?' -ForegroundColor Yellow
        return
    }
    Write-Host "Probing $($candidates.Count) candidate(s)…" -ForegroundColor Cyan
    $reports = foreach ($address in $candidates) { Get-RecorderReport -Address $address }
    $found = $reports | Where-Object { $_.Brand }
    if ($Json) {
        $found | ConvertTo-Json -Depth 6
    } else {
        if (-not $found) {
            Write-Host 'Hosts answered, but none of them is a recorder Pointy recognises.' -ForegroundColor Yellow
            return
        }
        foreach ($report in $found) { Write-Report -Report $report }
        Write-Host 'Run again with -RecorderHost <address> -Password <password> for the details.'
    }
    return
}

$report = Get-RecorderReport -Address $RecorderHost
if ($Json) { $report | ConvertTo-Json -Depth 6 } else { Write-Report -Report $report }
