# IBC mode — robust IB Gateway login (replaces xdotool)

The xdotool login (typing into the Swing dialog via X11) is fragile: AWT filters
synthetic events, the desktop steals focus at boot, and the X display drifts.
**IBC** ([IbcAlpha/IBC](https://github.com/IbcAlpha/IBC)) drives the login from
*inside the JVM* (reads the Swing dialog directly) — no X focus race. This dir
captures our setup. Paper gateway, API port 4002.

## Architecture
- **`ibc-gateway.service`** — runs `~/ibc/gatewaystart.sh -inline` (IBC launches +
  logs into the Gateway, handles the warning popup / 2FA / daily restart). Boot-robust:
  waits for the X display, ordered after network-online + graphical-session, never
  rate-limit-gives-up.
- **`ibc-health.service`** — runs `ibgw_watchdog.sh --monitor-only`: watches port 4002
  and sends Telegram alerts on down/recover (it does NOT log in — IBC owns that). Config
  in `ibgw_watchdog.conf` (gitignored; reuses the ops Telegram token from `cron-scripts/.env`).

## Install (new machine / rebuild)
1. Install the standalone IB Gateway (the usual IBKR installer) at `~/Jts/ibgateway/<VER>`.
2. Download IBC: `curl -L <release>/IBCLinux-<ver>.zip -o /tmp/ibc.zip && unzip -o /tmp/ibc.zip -d ~/ibc`
3. Edit `~/ibc/gatewaystart.sh`: `TWS_MAJOR_VRSN=<VER>`, `TRADING_MODE=paper`, `IBC_PATH=$HOME/ibc`.
4. Put the values from `config.ini.snippet` into `~/ibc/config.ini` (real creds), `chmod 600`.
5. Create `~/.ibgw_creds` (IB_USER=/IB_PASS=, chmod 600) — the health-monitor conf does not
   need it, but keep it for reference / the legacy watchdog.
6. Copy `ibc-gateway.service` + `ibc-health.service` to `~/.config/systemd/user/`,
   `systemctl --user daemon-reload`, `systemctl --user enable --now ibc-gateway ibc-health`.

## Verify
- `ss -tlnp | grep 4002` (API up); the consuming bots (gold/index ORB, client_ids 2/3) reconnect.
- A Telegram "started" alert should arrive on the ops chat.

## Rollback
The legacy xdotool watchdog (`ibgw_watchdog.sh`, full mode) is still here and works.
`systemctl --user disable --now ibc-gateway ibc-health && systemctl --user enable --now ibgw-watchdog`.

## Pinned versions (this deployment)
- IBC **3.24.0**, IB Gateway **10.37** (`TWS_MAJOR_VRSN=1037` in `gatewaystart.sh`).
- Paper trading, API port **4002**. Setting deltas from IBC stock: `config.ini.snippet`.
