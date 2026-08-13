# Multi Session Dashboard

Multi Session Dashboard is a Windows-oriented session manager for hosting multiple local RDP-backed streaming sessions with isolated Sunshine runtimes and a shared Moonlight client.

## Layout

The installer creates the following system-wide layout:

```text
C:\Program Files\Muti Session Dashboard\
├── Dashboard.ps1
├── Stream\
│   ├── Moonlight\
│   └── Sunshine\
├── Config\
└── Users\
```

RDP Wrapper is installed separately at `C:\Program Files\RDP Wrapper` using `https://github.com/sergiye/rdpWrapper/releases/latest/download/rdpWrapper_x64.exe`.

## Scripts

- `install.ps1` is the URL-based entry point (`irm ... | iex`). It stages the scripts below from raw GitHub and runs the installer with a forced dependency refresh, so it doubles as the update command.
- `scripts/Install-MultiSessionDashboard.ps1` downloads, installs, configures, and verifies RDP Wrapper, Remote Desktop Plus, Moonlight Portable, and Sunshine Portable, and installs the dashboard.
- `scripts/Dashboard.ps1` provides the operator dashboard with Create User, Start, Connect RDP, Connect Moonlight, Stop, Refresh, and Update Sunshine actions.
  - **Start / Connect RDP** both launch [Remote Desktop Plus](https://www.donkz.nl/) (`rdp.exe`) against `127.0.0.2:3389` with the account's username passed as both `/u:` and `/p:`, so the login is fully automatic — no saved-credential prompt to click through. Dashboard-created accounts always get the username as their Windows password so this always succeeds; Start then hands the session off to the console with `tscon` so it survives the client disconnecting, and Connect RDP reconnects to that same Windows session. A background monitor polls every Remote Desktop Users member's real session state every 2 seconds, so the dashboard reflects RDP connections made outside the dashboard too (e.g. a manual `rdp.exe`/mstsc connection), and keeps handing disconnected RDP sessions back to the console via `tscon`.
  - **Sunshine per-user isolation**: each dashboard-created user gets its own copy of Sunshine under `%LOCALAPPDATA%\Muti Session Dashboard\Sunshine`, its own `sunshine.conf`/`apps.json`, a unique port, and — since Moonlight has no supported way to target a non-default Sunshine port from the command line — its own dedicated loopback address (`127.0.0.3`, `127.0.0.4`, ...; `.2` is reserved by the RDP handoff trick above) that Sunshine binds to via `bind_address`. Sunshine is never launched by the elevated dashboard process itself (which would run it under the operator's account, not the target user); instead a Startup-folder shortcut is created for the user at creation time, so Sunshine starts automatically, correctly, under that user's own identity at their next interactive logon. Start polls and verifies (process owner + listening port) that Sunshine actually came up before reporting the session running, instead of just trusting that launching it worked.
  - **Update Sunshine** re-copies the current master Sunshine install (`Stream\Sunshine`) into the selected, already-created user's per-user copy and refreshes their config and Startup-folder shortcut — for pushing a newer Sunshine release (installed via `Install-SunshinePortable`/the URL installer) out to existing users without recreating their Windows account. The user's `apps.json` is left alone if it already exists, so operator customizations survive.
  - **Connect Moonlight** launches `Moonlight.exe stream <user's loopback address> Desktop --display-mode windowed --resolution 1920x1080 --absolute-mouse`, targeting the selected user's dedicated Sunshine instance with mouse mode optimized for remote-desktop-style use.
  - A background monitor re-derives both RDP and Sunshine status from live Windows/process state every tick — never from a stored flag alone.
  - **Port allocation** accounts for Sunshine's fixed port *family*: the configured `port` is a base value with HTTPS/HTTP/Web/RTSP/Video/Control/Audio/Mic all at fixed offsets from it (see [Sunshine's configuration docs](https://docs.lizardbyte.dev/projects/sunshine/master/md_docs_2configuration.html)), so two users whose base ports are adjacent can still collide on a derived port even though their base ports don't match. `Get-AllocatedPort` checks every offset — not just the base port — against real listeners before assigning a base port to a user.
- `scripts/MultiSessionDashboard.psm1` contains the reusable implementation for dependency verification, user creation, per-user Sunshine isolation, port/loopback allocation, RDP session handoff, and Moonlight launching.

## Quick start

### Install / update from a URL

The recommended way to install or update is a single command from an elevated
PowerShell prompt — no local checkout required:

```powershell
irm https://raw.githubusercontent.com/Chr0mX/Muti-Session-Dashboard/main/install.ps1 | iex
```

The same command is used to update: it always fetches the latest scripts and
dependency releases (RDP Wrapper, Moonlight, Sunshine) and re-runs the
installer over the existing installation.

Then launch the dashboard:

```powershell
powershell.exe -ExecutionPolicy Bypass -File "C:\Program Files\Muti Session Dashboard\Dashboard.ps1"
```

### Install from a local checkout

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
.\scripts\Install-MultiSessionDashboard.ps1
powershell.exe -ExecutionPolicy Bypass -File "C:\Program Files\Muti Session Dashboard\Dashboard.ps1"
```

RDP Wrapper is installed with the upstream-supported console argument `-install`. The upstream source treats `-offline` as a flag that disables update checks, so the dashboard installer no longer uses it by default because it can prevent the installer from fetching current wrapper metadata. To pass explicit installer arguments, use `-RdpWrapperInstallArguments`; to change the wait, use `-RdpWrapperInstallTimeoutSeconds`.

Moonlight and Sunshine downloads are resolved from `https://api.github.com/repos/moonlight-stream/moonlight-qt/releases/latest` and `https://api.github.com/repos/LizardByte/Sunshine/releases/latest`, then matched against portable Windows ZIP asset name patterns before downloading.

The installer caches dependency archives under `C:\Program Files\Muti Session Dashboard\Config\Downloads` and reuses them on later runs, so repeated installs do not re-download files unnecessarily. Use `-RefreshDownloadCache` to clear the cache before installing.

The installer fails closed: if any required dependency cannot be downloaded, configured, or verified, it reports the failed checks and does not mark installation complete. If the network is unavailable but a valid cached archive exists, the installer uses the cached archive and continues verification.
