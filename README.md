# kodi-caddy

Serve a local media library to Kodi over HTTP using [Caddy](https://caddyserver.com/docs/install).

## Requirements

- Windows PowerShell 5.1 or later
- Caddy available on `PATH`

## Configuration

Edit [`kodi-caddy.json`](kodi-caddy.json) and set:

- `mediaRoot`: root directory containing your media
- `port`: HTTP port used to serve media
- `adminPort`: Caddy admin port, bound to loopback only

Stop the server before changing the configuration, then start it again.

## Usage

Run from this directory:

```powershell
.\kodi-caddy.ps1 start
.\kodi-caddy.ps1 status
.\kodi-caddy.ps1 stop
.\kodi-caddy.ps1 enable-autostart
.\kodi-caddy.ps1 disable-autostart
```

Autostart runs at user logon without elevation or stored credentials.

## Kodi setup

Add each movie or TV folder as a separate source:

```text
http://<server>:8000/<folder>/
```

Replace `<server>` with the PC's LAN IP address or hostname, and use the configured HTTP port.

Set the appropriate Kodi content type for each source and keep the trailing slash.

## Network access

Media, including linked directories, is served read-only and without authentication. Use this server only on a trusted LAN.

To allow access through Windows Firewall, run the following from an elevated PowerShell prompt, adjusting the executable path, port, and network profile as needed:

```powershell
New-NetFirewallRule -DisplayName "kodi-caddy HTTP" -Direction Inbound -Action Allow -Protocol TCP -LocalPort 8000 -RemoteAddress LocalSubnet -Program "<full-path-to-caddy.exe>" -Profile Private
```

To restrict access to a single device, replace `LocalSubnet` with that device's reserved IP address. Disable broader existing allow rules.

## License

[0BSD](LICENSE)
