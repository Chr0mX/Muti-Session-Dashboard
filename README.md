# Multi Session Dashboard

Multi Session Dashboard gives multiple local Windows accounts their own independent, concurrently-active RDP session on one machine:

```text
                    Windows Host
                         │
          ┌──────────────┼──────────────┐
          ▼              ▼              ▼
      RDP :3389      RDP :3389      RDP :3389
          │              │              │
          ▼              ▼              ▼
       Session 3       Session 4       Session 5
       local1          local2          local3
          │              │              │
       Active          Active          Active
```

RDP Wrapper is what makes that concurrency possible — different accounts can each hold an active RDP session at the same time, which isn't otherwise available on a Windows client edition. The dashboard automates creating those accounts and connecting to them.

## Layout

The installer creates the following system-wide layout:

```text
C:\Program Files\Muti Session Dashboard\
├── Dashboard.ps1
├── Config\
└── Users\
```

RDP Wrapper is installed separately at `C:\Program Files\RDP Wrapper`, resolved through its [GitHub releases](https://github.com/sergiye/rdpWrapper/releases).

## Scripts

- `install.ps1` is the URL-based entry point (`irm ... | iex`). It stages the scripts below from raw GitHub and runs the installer, so it doubles as the update command.
- `scripts/Install-MultiSessionDashboard.ps1` downloads, installs, configures, and verifies RDP Wrapper and Remote Desktop Plus, and installs the dashboard.
- `scripts/Dashboard.ps1` provides the operator dashboard with Create User, Connect RDP, Stop, and Refresh actions.
  - **Connect RDP** launches [Remote Desktop Plus](https://www.donkz.nl/) (`rdp.exe`) against `127.0.0.2:3389` with the account's username passed as both `/u:` and `/p:`, so the login is fully automatic — no saved-credential prompt to click through. Dashboard-created accounts always get the username as their Windows password so this always succeeds. Connecting for a user who already has a disconnected session reconnects it — standard RDP behavior — so there's no separate "Start" step; one button covers both the first connect and any later reconnect.
  - **Stop** signs the selected user off.
  - A background monitor polls every Remote Desktop Users member's real session state every 2 seconds, so the dashboard reflects RDP connections made outside the dashboard too (e.g. a manual `rdp.exe`/mstsc connection) — a pure status reflection of live Windows state, never a stored flag alone.
- `scripts/MultiSessionDashboard.psm1` contains the reusable implementation: dependency install/verification, user creation, session detection, and the automated RDP connect flow.

## Quick start

### Install / update from a URL

The recommended way to install or update is a single command from an elevated
PowerShell prompt — no local checkout required:

```powershell
irm https://raw.githubusercontent.com/Chr0mX/Muti-Session-Dashboard/main/install.ps1 | iex
```

The same command is used to update: it re-runs the installer over the existing installation.

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

RDP Wrapper is resolved through the GitHub releases API and cached by the resolved release tag, so a re-run only re-downloads it when the upstream release actually changed, not on every run. Use `-RefreshDownloadCache` to force a full re-download regardless.

The installer fails closed: if any required dependency cannot be downloaded, configured, or verified, it reports the failed checks and does not mark installation complete. If the network is unavailable but a valid cached archive exists, the installer uses the cached archive and continues verification.
