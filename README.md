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
├── MultiSessionDashboard.psm1
├── SessionManager.psm1
├── UserManager.psm1
├── RdpManager.psm1
├── HeadlessManager.psm1
├── Config\
└── Users\
```

RDP Wrapper is installed separately at `C:\Program Files\RDP Wrapper`, resolved through its [GitHub releases](https://github.com/sergiye/rdpWrapper/releases).

## Scripts

- `install.ps1` is the URL-based entry point (`irm ... | iex`). It stages the scripts below from raw GitHub and runs the installer, so it doubles as the update command.
- `scripts/Install-MultiSessionDashboard.ps1` downloads, installs, configures, and verifies RDP Wrapper and Remote Desktop Plus, and installs the dashboard, including all four backend modules below.
- `scripts/Dashboard.ps1` is the WinForms UI **only** — Create User, Start, Connect RDP, Stop, Refresh, and Open RDP Wrapper buttons, a grid, and a 2-second status timer. It holds no session-management logic itself; every button click and every timer tick just dispatches a named module command and renders whatever comes back.
  - Both **Start** and **Connect RDP** launch [Remote Desktop Plus](https://www.donkz.nl/) (`rdp.exe`) against `127.0.0.2:3389` with the account's username passed as both `/u:` and `/p:` (plus a generated `.rdp` file carrying settings like `smart sizing:i:1` that have no dedicated CLI flag), so the login is fully automatic — no saved-credential prompt to click through. Dashboard-created accounts always get the username as their Windows password so this always succeeds.
  - **Start** arms a **headless RDP loopback**: the same automated login, launched minimized so no RDP window appears (window title `RDP-<user>-Headless`), then verified by polling the account's real, live-detected session ID (never a hard-coded session number) until it shows up Active. This keeps the user's session alive and "ready" without anyone looking at it. See [Headless RDP Loopback](#headless-rdp-loopback) below. In practice this is a manual "do it now" shortcut — every RDS user gets armed automatically anyway (see the background monitor below).
  - **Connect RDP** launches a real, visible, interactive client (window title `RDP-<user>`). Reconnecting to a session that already exists — whether disconnected or headless-armed — takes it over: standard RDP behavior, where a new client connecting to an existing session disconnects whichever client held it before. So Connect RDP alone (without ever pressing Start first) still works exactly like a normal connect/reconnect.
  - **Stop** stops any armed headless loopback, signs the selected user's real session off, and then polls (does not assume) until that session is actually gone before reporting Stopped. A Stopped user is left alone by the background monitor — it will not auto-arm them again until Start or Connect RDP is used.
  - **Open RDP Wrapper** launches the RDP Wrapper manager UI (`C:\Program Files\RDP Wrapper\rdpWrapper_x64.exe`) directly, for manual inspection/reconfiguration.
  - A background monitor polls every Remote Desktop Users member's real session state every 2 seconds, so the dashboard reflects RDP connections made outside the dashboard too (e.g. a manual `rdp.exe`/mstsc connection) — a pure status reflection of live Windows state, never a stored flag alone. **Every RDS user is kept headless-armed automatically**: whenever a user's RDP status shows Disconnected (whether their interactive session just closed, they were never started at all, or a previous arm attempt failed) and they haven't been explicitly Stopped, the monitor waits for their session to genuinely finish closing and re-arms the headless loopback right there — no manual Start required, ever, for a user that hasn't been Stopped.
  - **None of this blocks the UI.** RDP launches, session waits, sign-off verification, and headless re-arming all run on background runspaces (`Start-DashboardBackgroundTask`, in `MultiSessionDashboard.psm1`) and marshal every UI update back onto the WinForms thread via `Control.BeginInvoke` — the window stays responsive and never reports "Not Responding" while any of this is in flight. No `tscon`, no console hand-off, anywhere in this flow.
- `scripts/MultiSessionDashboard.psm1` is the public interface/coordinator: install-path management, dashboard state persistence, RDP Wrapper install/verify, `Start-DashboardBackgroundTask`, and the top-level workflows (`Connect-DashboardRdp`, `Update-DashboardMonitorState`, `Test-DashboardInstallation`) that tie the four backend modules below together. It's the only module `Dashboard.ps1` and the installer import directly.
- `scripts/SessionManager.psm1` — Windows session detection: enumerates real Terminal Services sessions via the WTS API (`WTSEnumerateSessions`, the same API `quser`/`query session` call internally — not text-parsed `quser` output, which can under-report a session `query session` shows as genuinely Active), and the blocking wait helpers (`Wait-DashboardRdpSession`, `Wait-DashboardSessionClosed`) used to verify a session actually came up or actually closed.
- `scripts/RdpManager.psm1` — RDP launching/stopping: resolving/installing Remote Desktop Plus, generating the per-user `.rdp` file (smart sizing and friends), launching `rdp.exe`, titling and minimizing its window, and opening the RDP Wrapper manager.
- `scripts/HeadlessManager.psm1` — headless loopback start/re-arm: arming a minimized anchor connection and tearing it down.
- `scripts/UserManager.psm1` — user/session sign-off: local account creation, reading the "Remote Desktop Users" group, and `Stop-DashboardSession`.
- `scripts/BetterRDP/` contains [Upinel/BetterRDP](https://github.com/Upinel/BetterRDP)'s host-side RDP performance tweaks (`UpinelBetterRDP.reg`, `BetterRDP.ps1`), applied manually and separately from the dashboard install. The `.ps1` copy here is modified to detect the RDP server's current primary monitor refresh rate and match the frame-rate-related registry values to it, instead of the upstream script's fixed ~60Hz assumption.

## Headless RDP Loopback

```text
                         DASHBOARD
                             │
             ┌───────────────┼────────────────┐
             │               │                │
           START           CONNECT           STOP
             │               │                │
             ▼               ▼                ▼
      Arm Headless      Launch Interactive   Stop Headless
      Loopback RDP      RDP Connection       Loopback RDP
             │               │                │
             ▼               ▼                ▼
      HEADLESS READY    Headless loopback    Sign off
                              displaced       User Session
                                 │                │
                                 ▼                ▼
                           USER CONNECTED       STOPPED
                                 │
                          User closes RDP
                                 │
                                 ▼
                         Wait for RDP session
                              to close
                                 │
                                 ▼
                         Start Headless
                         Loopback RDP
                                 │
                                 ▼
                          HEADLESS READY
```

A headless loopback connection is just an ordinary automated RDP login (same as Connect RDP) that gets minimized right after it comes up, so it never shows a window, and titled `RDP-<user>-Headless` (a real interactive session is titled `RDP-<user>`) so the two are distinguishable in Task Manager if you ever need to check. Its only purpose is to keep the account's session alive and immediately reconnect-able. Nothing about it is special at the RDP protocol level — the "displacement" when Connect RDP is used afterward is just RDP's normal single-active-client-per-session behavior.

Every RDS user is kept headless-armed by default, automatically, by the background monitor described above — Start exists as a manual shortcut, not a requirement.

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
