# ibgw-watchdog

**Headless IB Gateway auto-recovery watchdog for Linux.**

Keeps Interactive Brokers Gateway running unattended — restarts it when it crashes, automatically logs back in when the session expires, and handles every known error dialog that blocks recovery.

---

## What it handles

| Scenario | Action |
|---|---|
| Port down (crash, maintenance restart) | Restarts binary, polls until port is up |
| Login required after restart | Drives the login form via `xdotool` |
| **Login Error dialog** (wrong credentials, locked account) | Clicks OK, sends CRITICAL alert, restarts |
| **Gateway error dialog** (soft-token expiry, SSL, connection failure) | Clicks OK, sends WARNING alert, restarts |
| **"Existing session detected"** dialog | Kills the process and restarts clean |
| Mid-session IB server disconnect | Re-drives the login form without killing the process |
| Wrong window focus before typing credentials | Safety abort — credentials never typed, CRITICAL alert sent |

---

## Quick start

```bash
# 1. Install dependencies
sudo apt install -y xdotool scrot curl

# 2. Clone and configure
git clone https://github.com/oager/ibgw-watchdog.git
cd ibgw-watchdog
cp ibgw_watchdog.conf.example ibgw_watchdog.conf
chmod 600 ibgw_watchdog.conf
# Edit ibgw_watchdog.conf — set your alert channel, verify port

# 3. Create credentials file (kept separate so you can safely commit the config)
touch ~/.ibgw_creds && chmod 600 ~/.ibgw_creds
echo "IB_USER=your_ibkr_username" >> ~/.ibgw_creds
echo "IB_PASS=your_ibkr_password" >> ~/.ibgw_creds

# 4. Calibrate coordinates (first time only — open IB Gateway login dialog first)
bash ibgw_watchdog.sh --calibrate

# 5a. Start now (foreground test / one-off)
nohup bash ibgw_watchdog.sh >> ~/logs/ibgw_watchdog.log 2>&1 &

# 5b. …or install as a boot service so it auto-starts on every reboot (recommended)
./install.sh
```

---

## Auto-start on boot

`./install.sh` registers the watchdog as a **systemd user service** and enables
[linger](https://www.freedesktop.org/software/systemd/man/loginctl.html#enable-linger%20USER%E2%80%A6)
so it starts at boot without an interactive login. It asks one question — how IB
Gateway gets an X display:

| Mode | Use when | Hands-off at boot? |
|---|---|---|
| **attach** | You have a desktop or VNC session (physical or remote) | Only if the desktop **auto-logs-in** — otherwise the watchdog waits until you log in |
| **xvfb** | Headless box, no desktop | Yes — the watchdog owns a virtual display (`:99`); attach a VNC viewer to `:99` to see/calibrate the Gateway |

```bash
./install.sh                 # interactive: pick attach or xvfb

systemctl --user status ibgw-watchdog       # check it
journalctl --user-unit ibgw-watchdog -f     # follow logs
systemctl --user disable --now ibgw-watchdog # remove from boot
```

> **attach mode + true hands-off boot:** the watchdog can only drive IB Gateway
> once an X session exists. If your box requires a manual desktop login after a
> reboot, enable your display manager's auto-login (e.g. GDM:
> `AutomaticLoginEnable=true` / `AutomaticLogin=<user>` in `/etc/gdm3/custom.conf`),
> or use **xvfb** mode, which needs no desktop login at all.

---

## Configuration

All settings live in `ibgw_watchdog.conf`:

```bash
IBGW_PORT=4002                      # 4002=paper, 4001=live. Leave blank to auto-detect.
IBGW_BIN=                           # Path to ibgateway binary. Leave blank to auto-detect.
PAPER_TRADING=true                  # Auto-dismiss paper trading warning popup

# Alerts — configure one or more:
ALERT_DISCORD_WEBHOOK=https://discord.com/api/webhooks/...
ALERT_TELEGRAM_TOKEN=123456:ABC...
ALERT_TELEGRAM_CHAT_ID=987654321
ALERT_WEBHOOK_URL=https://yourserver.com/hook    # any JSON POST endpoint
```

See `ibgw_watchdog.conf.example` for the full list with descriptions.

---

## Alerts

Sends alerts on: watchdog start, recovery success, gateway/login error dialogs, credential safety abort, and escalation after repeated failures.

**Supported channels:** Discord webhook · Telegram bot · any HTTP endpoint (Slack, ntfy.sh, PagerDuty, custom)

---

## Auto-detection

Leave `IBGW_PORT` and `IBGW_BIN` blank — the watchdog will:

- **Port:** parse `~/Jts/jts.ini`, scan 4002/4001/4003, default to 4002
- **Binary:** read from running process `/proc/<pid>/cwd`, search `~/Jts/ibgateway/*/`, `/opt/ibgateway/*/`, fall back to `which ibgateway`

---

## Calibration

The `--calibrate` flag runs an interactive setup: with the IB Gateway login dialog open, hover over the username field, password field, and login button when prompted and press Enter. Coordinates are saved to your config automatically.

The **default coordinates work for IB Gateway 1037** on a standard Linux desktop — calibration is a fallback for other versions.

---

## How it works

```
every 30s:
  is port up?
  NO  → kill stale process → launch ibgateway → wait 60s
          if still down → xdotool login → poll 30s
  YES → Login Error dialog?         → alert CRITICAL → kill+restart
        Gateway error modal?        → alert WARNING  → kill+restart
        Existing session dialog?    → kill+restart
        Mid-session login form?     → xdotool login (no restart)
```

### Why kill+restart for "Existing session detected"?

IB Gateway uses Java Swing, which filters synthetic click events (`XSendEvent`) via `XFilterEvent`. Programmatic clicks on Java Swing dialogs silently fail. Kill and restart is more reliable and takes the same time.

---

## Requirements

- Linux with an X display (physical, VNC, or Xvfb)
- IB Gateway installed (not TWS)
- `xdotool`, `scrot`, `curl`, `bash 4+`

---

## Related

[IBC (IbcAlpha)](https://github.com/IbcAlpha/IBC) — Java-based alternative that integrates more deeply with Gateway internals. This watchdog fills specific gaps: soft-token/SSL error dialog recovery, credential-leak safety, and kill+restart for session conflicts.

---

## License

MIT
