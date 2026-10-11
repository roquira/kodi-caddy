<#
.SYNOPSIS
Manages the kodi-caddy server.

.EXAMPLE
.\kodi-caddy.ps1 start

.EXAMPLE
.\kodi-caddy.ps1 enable-autostart
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet("start", "stop", "status", "enable-autostart", "disable-autostart")]
    [string] $Action = "status"
)

$ErrorActionPreference = "Stop"

$configPath = Join-Path $PSScriptRoot "kodi-caddy.json"
$config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
$mediaRoot = [Environment]::ExpandEnvironmentVariables([string] $config.mediaRoot)
$port = [int] $config.port
$adminPort = [int] $config.adminPort
$listenAddress = ":$port"
$adminAddress = "127.0.0.1:$adminPort"
$browseTemplate = (Join-Path $PSScriptRoot "kodi-browse.html") -replace '\\', '/'

if ([string]::IsNullOrWhiteSpace($mediaRoot)) {
    throw "mediaRoot is missing from kodi-caddy.json."
}
if ($port -notin 1..65535 -or $adminPort -notin 1..65535) {
    throw "port and adminPort must be between 1 and 65535."
}
if ($port -eq $adminPort) {
    throw "port and adminPort must be different."
}

function Get-CaddyCommand {
    $command = Get-Command caddy -ErrorAction SilentlyContinue
    if ($null -eq $command) {
        throw "Caddy was not found on PATH. Install Caddy or add caddy.exe to PATH."
    }
    return $command.Source
}

function Test-LocalPort([int] $Port) {
    $client = [System.Net.Sockets.TcpClient]::new()
    try {
        $connection = $client.ConnectAsync("127.0.0.1", $Port)
        return $connection.Wait(300) -and $client.Connected
    }
    catch {
        return $false
    }
    finally {
        $client.Dispose()
    }
}

function Set-CaddyEnvironment {
    $env:KODI_CADDY_ADMIN_ADDRESS = $adminAddress
    $env:KODI_CADDY_LISTEN_ADDRESS = $listenAddress
    $env:KODI_CADDY_MEDIA_ROOT = $mediaRoot -replace '\\', '/'
    $env:KODI_CADDY_BROWSE_TEMPLATE = $browseTemplate
}

function Get-KodiCaddyInstance {
    if (-not (Test-LocalPort $adminPort)) {
        return $null
    }

    try {
        $activeConfig = Invoke-RestMethod -Uri "http://$adminAddress/config/" -Method Get -TimeoutSec 2
    }
    catch {
        throw "Cannot verify the service on admin port $adminPort; leaving it alone."
    }

    foreach ($server in $activeConfig.apps.http.servers.PSObject.Properties.Value) {
        $handlers = @($server.routes | ForEach-Object { $_.handle })
        $fileServer = $handlers | Where-Object {
            $_.handler -eq "file_server" -and
            ($_.browse.template_file -replace '\\', '/') -eq $browseTemplate
        }
        if ($null -ne $fileServer) {
            $activeRoot = [string] ($handlers | Where-Object { $_.handler -eq "vars" }).root
            $rootMatches = ($activeRoot -replace '\\', '/').TrimEnd('/') -eq ($mediaRoot -replace '\\', '/').TrimEnd('/')
            $portMatches = @($server.listen | Where-Object { $_ -match (':' + $port + '$') }).Count -gt 0
            return [pscustomobject]@{
                SettingsMatch = $rootMatches -and $portMatches
                HttpReady = Test-LocalPort $port
            }
        }
    }

    throw "Admin port $adminPort is not a verified kodi-caddy instance for this checkout; leaving it alone."
}

function Start-KodiCaddy {
    $instance = Get-KodiCaddyInstance
    if ($null -ne $instance) {
        if (-not $instance.SettingsMatch) {
            throw "kodi-caddy is running with different settings. Stop it, then start it again."
        }
        if (-not $instance.HttpReady) {
            throw "kodi-caddy's admin endpoint is running, but HTTP port $port is not ready."
        }
        Write-Host "kodi-caddy is already running (admin port $adminPort)."
        return
    }

    $caddy = Get-CaddyCommand
    if (-not (Test-Path -LiteralPath $mediaRoot -PathType Container)) {
        throw "Media root does not exist: $mediaRoot"
    }

    if (Test-LocalPort $port) {
        throw "TCP port $port is already in use."
    }

    Set-CaddyEnvironment
    $caddyfile = Join-Path $PSScriptRoot "Caddyfile"

    # Windows PowerShell 5.1 turns redirected native stderr into error records.
    # Caddy writes normal validation diagnostics to stderr, so capture them
    # without allowing ErrorActionPreference=Stop to abort a valid startup.
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $validationOutput = & $caddy validate --config $caddyfile --adapter caddyfile 2>&1
        $validationExitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    if ($validationExitCode -ne 0) {
        $validationOutput | Write-Host
        throw "Caddyfile validation failed."
    }

    $process = Start-Process -FilePath $caddy `
        -ArgumentList @("run", "--config", ('"{0}"' -f $caddyfile), "--adapter", "caddyfile") `
        -WorkingDirectory $PSScriptRoot `
        -WindowStyle Hidden `
        -PassThru

    $startup = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        while ($startup.Elapsed.TotalSeconds -lt 10) {
            if ($process.HasExited) {
                throw "Caddy exited during startup (exit code $($process.ExitCode))."
            }
            try {
                $instance = Get-KodiCaddyInstance
            }
            catch {
                $instance = $null
            }
            if ($null -ne $instance -and $instance.SettingsMatch -and $instance.HttpReady) {
                Write-Host "kodi-caddy started: http://<this-PC-LAN-IP>:$port/"
                return
            }
            Start-Sleep -Milliseconds 250
        }

        throw "Caddy did not become ready on HTTP port $port and admin port $adminPort."
    }
    catch {
        if (-not $process.HasExited) {
            # Include launcher children, such as Chocolatey's Caddy process.
            Start-Process -FilePath "$env:SystemRoot\System32\taskkill.exe" `
                -ArgumentList @("/PID", [string] $process.Id, "/T", "/F") `
                -WindowStyle Hidden -Wait -ErrorAction SilentlyContinue
            if (-not $process.HasExited) {
                Write-Warning "Could not stop the process started by this attempt (PID $($process.Id))."
            }
        }
        throw
    }
    finally {
        $process.Dispose()
    }
}

function Stop-KodiCaddy {
    if ($null -eq (Get-KodiCaddyInstance)) {
        Write-Host "kodi-caddy is not running."
        return
    }

    $caddy = Get-CaddyCommand
    & $caddy stop --address $adminAddress
    if ($LASTEXITCODE -ne 0) {
        throw "Caddy could not be stopped through $adminAddress."
    }
    Write-Host "kodi-caddy stopped."
}

function Show-KodiCaddyStatus {
    try {
        $instance = Get-KodiCaddyInstance
    }
    catch {
        Write-Host $_.Exception.Message
        return
    }
    if ($null -eq $instance) {
        Write-Host "kodi-caddy is not running."
        if (Test-LocalPort $port) {
            Write-Host "TCP port $port is in use by another service."
        }
        return
    }
    if (-not $instance.SettingsMatch) {
        Write-Host "kodi-caddy is running with different settings. Stop it, then start it again."
        return
    }
    if (-not $instance.HttpReady) {
        Write-Host "kodi-caddy's admin endpoint is running, but HTTP port $port is not ready."
        return
    }

    Write-Host ("Admin  {0,-21} up" -f $adminAddress)
    Write-Host ("HTTP   {0,-21} up" -f $listenAddress)

    $addresses = @(
        try {
            [System.Net.Dns]::GetHostAddresses([System.Net.Dns]::GetHostName()) |
                Where-Object { $_.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork } |
                ForEach-Object { $_.IPAddressToString } |
                Where-Object { $_ -notlike "127.*" -and $_ -notlike "169.254.*" } |
                Sort-Object -Unique
        }
        catch {
            # A URL is helpful but not required to report the server state.
        }
    )

    if ($addresses.Count -eq 0) {
        Write-Host "LAN IP  unavailable"
        return
    }

    foreach ($address in $addresses) {
        Write-Host "URL     http://${address}:$port/"
    }
}

function Enable-KodiCaddyAutostart {
    $taskName = "kodi-caddy"
    $currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    $powershell = (Get-Command powershell.exe -ErrorAction Stop).Source
    $arguments = '-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}" start' -f $PSCommandPath

    $taskAction = New-ScheduledTaskAction -Execute $powershell -Argument $arguments
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $currentUser
    $principal = New-ScheduledTaskPrincipal -UserId $currentUser -LogonType Interactive -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -StartWhenAvailable

    Register-ScheduledTask `
        -TaskName $taskName `
        -Action $taskAction `
        -Trigger $trigger `
        -Principal $principal `
        -Settings $settings `
        -Description "Start the kodi-caddy LAN media server at user logon." `
        -Force | Out-Null

    Write-Host "Enabled autostart for $currentUser."
}

function Disable-KodiCaddyAutostart {
    $taskName = "kodi-caddy"
    $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($null -eq $task) {
        Write-Host "Autostart is not enabled."
        return
    }

    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
    Write-Host "Disabled autostart."
}

switch ($Action) {
    "start"             { Start-KodiCaddy }
    "stop"              { Stop-KodiCaddy }
    "status"            { Show-KodiCaddyStatus }
    "enable-autostart"  { Enable-KodiCaddyAutostart }
    "disable-autostart" { Disable-KodiCaddyAutostart }
}
