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
- `scripts/Install-MultiSessionDashboard.ps1` downloads, installs, configures, and verifies RDP Wrapper from the release executable, resolves the latest Moonlight Portable and Sunshine Portable archives through the GitHub releases API, and installs the dashboard.
- `scripts/Dashboard.ps1` provides the operator dashboard with Create User, Start, Connect RDP, Connect Moonlight, Stop, and Refresh actions. Start opens a native RDP login for the selected user and hands it off to the console with `tscon` so the session survives the client disconnecting; Connect RDP reconnects to that same Windows session. A background monitor polls every Remote Desktop Users member's real session state every 2 seconds, so the dashboard reflects RDP connections made outside the dashboard too (e.g. a manual mstsc connection), and keeps handing disconnected RDP sessions back to the console via `tscon`.
- `scripts/MultiSessionDashboard.psm1` contains the reusable implementation for dependency verification, user creation, per-user Sunshine isolation, port allocation, RDP session handoff, and Moonlight launching.

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
