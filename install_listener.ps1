# =============================================================================
# ESP32 Command Listener v1.1.0
# Protocol: UDP / Port 9000
# Auth    : Timestamp only (30s replay window)
# Commands: shutdown | restart | sleep | lock | cancel
# =============================================================================

param(
    [int]   $Port      = 9000,
    [string]$AllowedIP = "0.0.0.0",
    [string]$LogFile   = "$PSScriptRoot\esp32-cmd-listener.log"
)

function Write-Log {
    param([string]$Level, [string]$Message, [string]$Color = "White")
    $ts   = Get-Date -Format "yyyy-MM-dd HH:mm:ss UTC" -AsUTC
    $line = "[$ts] [$Level] $Message"
    Write-Host $line -ForegroundColor $Color
    Add-Content -Path $LogFile -Value $line -Encoding UTF8
}

function Log-Info  { param([string]$m) Write-Log "INFO " $m "Cyan"    }
function Log-Ok    { param([string]$m) Write-Log "OK   " $m "Green"   }
function Log-Warn  { param([string]$m) Write-Log "WARN " $m "Yellow"  }
function Log-Error { param([string]$m) Write-Log "ERROR" $m "Red"     }
function Log-Cmd   { param([string]$m) Write-Log "CMD  " $m "Magenta" }

function Invoke-PCCommand {
    param([string]$Command)
    Log-Cmd "Executing: $Command"
    if ($Command -eq "shutdown") {
        Log-Warn "System will shut down in 10 seconds."
        shutdown.exe /s /t 10
    }
    elseif ($Command -eq "restart") {
        Log-Warn "System will restart in 10 seconds."
        shutdown.exe /r /t 10
    }
    elseif ($Command -eq "sleep") {
        Log-Info "Suspending system..."
        rundll32.exe powrprof.dll,SetSuspendState 0,1,0
    }
    elseif ($Command -eq "lock") {
        Log-Info "Locking workstation..."
        rundll32.exe user32.dll,LockWorkStation
    }
    elseif ($Command -eq "cancel") {
        Log-Info "Cancelling pending shutdown/restart..."
        shutdown.exe /a
    }
    else {
        Log-Warn "Unknown command: '$Command' — ignored."
    }
}

Log-Info "============================================================"
Log-Info "  ESP32 Command Listener  v1.1.0"
Log-Info "  Listening on UDP port : $Port"
Log-Info "  Allowed source IP     : $(if ($AllowedIP -eq '0.0.0.0') { 'Any' } else { $AllowedIP })"
Log-Info "  Log file              : $LogFile"
Log-Info "============================================================"

try {
    $endpoint  = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, $Port)
    $udpClient = New-Object System.Net.Sockets.UdpClient($Port)
    $udpClient.Client.ReceiveTimeout = 0
    Log-Ok "UDP socket bound to port $Port — waiting for commands..."
}
catch {
    Log-Error "Failed to bind UDP socket on port ${Port}: $_"
    exit 1
}

while ($true) {
    try {
        $data    = $udpClient.Receive([ref]$endpoint)
        $payload = [System.Text.Encoding]::UTF8.GetString($data).Trim()
        $srcIP   = $endpoint.Address.ToString()

        Log-Info "Packet received from ${srcIP}: $payload"

        if ($AllowedIP -ne "0.0.0.0" -and $srcIP -ne $AllowedIP) {
            Log-Error "Rejected: source IP '$srcIP' not allowed."
            continue
        }

        $parts = $payload -split ":"
        if ($parts.Count -lt 2) {
            Log-Error "Rejected: malformed payload (expected 'cmd:timestamp')."
            continue
        }

        $cmd       = $parts[0].ToLower()
        $timestamp = 0L
        if (-not [long]::TryParse($parts[1], [ref]$timestamp)) {
            Log-Error "Rejected: invalid timestamp '$($parts[1])'."
            continue
        }

        $now  = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        $diff = [Math]::Abs($now - $timestamp)
        if ($diff -gt 30) {
            Log-Error "Rejected: timestamp out of window (diff=${diff}s)."
            continue
        }

        Log-Ok "Command '$cmd' accepted from $srcIP (latency: ${diff}s)."
        Invoke-PCCommand -Command $cmd
    }
    catch [System.Net.Sockets.SocketException] {
        Log-Error "Socket error: $_"
    }
    catch {
        Log-Error "Unexpected error: $_"
    }
}
