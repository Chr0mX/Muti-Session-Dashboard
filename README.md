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
├── Aardwolf\
├── Config\
└── Users\
```

RDP Wrapper is installed separately at `C:\Program Files\RDP Wrapper` using `https://github.com/sergiye/rdpWrapper/releases/latest/download/rdpWrapper_x64.exe`.

## Scripts

- `scripts/Install-MultiSessionDashboard.ps1` downloads, silently installs, configures, and verifies RDP Wrapper from the release executable, Moonlight Portable, Sunshine Portable, Aardwolf CLI/GUI, and the dashboard.
- `scripts/Dashboard.ps1` provides the operator dashboard with Create User, Start, Connect RDP, Connect Moonlight, Stop, and Refresh actions.
- `scripts/MultiSessionDashboard.psm1` contains the reusable implementation for dependency verification, user creation, per-user Sunshine isolation, port allocation, Aardwolf integration, and Moonlight launching.

## Quick start

Run from an elevated PowerShell prompt on Windows:

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
.\scripts\Install-MultiSessionDashboard.ps1
powershell.exe -ExecutionPolicy Bypass -File "C:\Program Files\Muti Session Dashboard\Dashboard.ps1"
```

RDP Wrapper is installed with the upstream-supported console argument `-install`. The upstream source treats `-offline` as a flag that disables update checks, so the dashboard installer no longer uses it by default because it can prevent the installer from fetching current wrapper metadata. To pass explicit installer arguments, use `-RdpWrapperInstallArguments`; to change the wait, use `-RdpWrapperInstallTimeoutSeconds`.

The installer caches dependency archives under `C:\Program Files\Muti Session Dashboard\Config\Downloads` and reuses them on later runs, so repeated installs do not re-download files unnecessarily. Use `-RefreshDownloadCache` to clear the cache before installing.

The installer fails closed: if any required dependency cannot be downloaded, configured, or verified, it reports the failed checks and does not mark installation complete. If the network is unavailable but a valid cached archive exists, the installer uses the cached archive and continues verification.
