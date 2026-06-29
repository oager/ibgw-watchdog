#!/usr/bin/env bash
# =============================================================================
# install.sh — set up ibgw-watchdog to auto-start on boot via systemd (user)
# =============================================================================
# Interactive. Asks how IB Gateway gets a display, writes a systemd user
# service, enables linger so it starts at boot without an interactive login.
#
#   attach  — watchdog attaches to an existing X session (physical desktop or
#             VNC). Fully hands-off at boot only if the desktop auto-logs-in.
#   xvfb    — watchdog owns a headless virtual display (:99). No desktop login
#             needed; attach a VNC viewer to :99 to see/calibrate the Gateway.
#
# Re-running is safe — it overwrites the unit(s) and reloads.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WATCHDOG_SCRIPT="$SCRIPT_DIR/ibgw_watchdog.sh"
TEMPLATE_DIR="$SCRIPT_DIR/systemd"
USER_UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"

say()  { printf '%s\n' "$*"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*"; }
die()  { printf '\033[31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# ── IBC backend (recommended): in-JVM login via IbcAlpha/IBC ───────────────────
# Installs ibc-gateway.service (IBC launches + logs into the Gateway) and
# ibc-health.service (this watchdog in --monitor-only mode: port watch + alerts,
# no login). Units are generated with the resolved HOME/display so nothing is
# hard-coded. IBC itself must already be installed — see ibc/README.md.
install_ibc() {
    local IBC_DIR="$HOME/ibc"
    local GATEWAYSTART="$IBC_DIR/gatewaystart.sh"
    say ""
    ok "IBC backend — IBC owns login; watchdog runs as a health probe"
    [[ -x "$GATEWAYSTART" ]] || die "IBC not found at $GATEWAYSTART. Install IBC first — see ibc/README.md."
    [[ -f "$IBC_DIR/config.ini" ]] || warn "No $IBC_DIR/config.ini yet (real creds) — see ibc/config.ini.snippet, then chmod 600 it."
    command -v curl >/dev/null 2>&1 || warn "curl missing — health-probe alerts need it: sudo apt install -y curl"

    # Gateway is a GUI even under IBC — resolve the X display + Xauthority it renders on.
    local DISP XAUTH XN XAUTH_LINE
    DISP="${DISPLAY:-}"
    if [[ -z "$DISP" ]]; then
        for sock in /tmp/.X11-unix/X*; do [[ -e "$sock" ]] && DISP=":${sock##*/X}" && break; done
    fi
    DISP="${DISP:-:0}"
    read -r -p "X display the Gateway renders on (default ${DISP}): " d
    DISP="${d:-$DISP}"
    XN="${DISP#:}"; XN="${XN%%.*}"

    XAUTH="${XAUTHORITY:-}"
    [[ -z "$XAUTH" && -f "$HOME/.Xauthority" ]] && XAUTH="$HOME/.Xauthority"
    [[ -z "$XAUTH" ]] && XAUTH="$(find "/run/user/$(id -u)" -maxdepth 2 -iname '*xauth*' 2>/dev/null | head -1 || true)"
    read -r -p "XAUTHORITY file (default ${XAUTH:-none}): " x
    XAUTH="${x:-$XAUTH}"
    XAUTH_LINE=""; [[ -n "$XAUTH" ]] && XAUTH_LINE="Environment=XAUTHORITY=${XAUTH}"

    mkdir -p "$USER_UNIT_DIR"

    cat > "$USER_UNIT_DIR/ibc-gateway.service" <<EOF
[Unit]
Description=IB Gateway via IBC (port from config.ini)
Wants=network-online.target
After=network-online.target graphical-session.target
StartLimitIntervalSec=0

[Service]
Type=simple
Environment=DISPLAY=${DISP}
${XAUTH_LINE}
ExecStartPre=/bin/bash -c 'for i in \$(seq 1 30); do [ -e /tmp/.X11-unix/X${XN} ] && exit 0; sleep 1; done; exit 0'
ExecStart=${GATEWAYSTART} -inline
Restart=on-failure
RestartSec=30

[Install]
WantedBy=default.target
EOF
    ok "Wrote $USER_UNIT_DIR/ibc-gateway.service (DISPLAY=${DISP})"

    cat > "$USER_UNIT_DIR/ibc-health.service" <<EOF
[Unit]
Description=IBC gateway health monitor + alerts (port watch, no login)
After=ibc-gateway.service

[Service]
Type=simple
ExecStart=/usr/bin/env bash ${WATCHDOG_SCRIPT} --monitor-only
Restart=always
RestartSec=15

[Install]
WantedBy=default.target
EOF
    ok "Wrote $USER_UNIT_DIR/ibc-health.service"

    if [[ "$(loginctl show-user "$USER" -p Linger --value 2>/dev/null)" == "yes" ]]; then
        ok "Linger already enabled for $USER"
    elif loginctl enable-linger "$USER" 2>/dev/null; then
        ok "Enabled linger for $USER (services start at boot)"
    else
        warn "Could not enable linger automatically. Run:  sudo loginctl enable-linger $USER"
    fi

    systemctl --user daemon-reload
    systemctl --user enable --now ibc-gateway.service ibc-health.service
    ok "Enabled + started ibc-gateway.service + ibc-health.service"

    say ""
    say "================================================================="
    say " IBC mode installed. IBC logs the Gateway in; the watchdog watches the port."
    say "================================================================="
    say ""
    say "Status:   systemctl --user status ibc-gateway ibc-health"
    say "Logs:     journalctl --user-unit ibc-gateway -f"
    say "Disable:  systemctl --user disable --now ibc-gateway ibc-health"
    say "Switch to the xdotool watchdog instead: re-run ./install.sh, choose backend 2"
    say ""
}

[[ -f "$WATCHDOG_SCRIPT" ]] || die "ibgw_watchdog.sh not found next to install.sh"

say ""
say "================================================================="
say " ibgw-watchdog installer — auto-start on boot (systemd user)"
say "================================================================="
say ""

# ── 0. Login backend ──────────────────────────────────────────────────────────
say "Login backend — how does the Gateway authenticate?"
say "  1) IBC      — in-JVM login via IbcAlpha/IBC (recommended: robust, no X focus race)"
say "  2) xdotool  — this watchdog drives the login form over X11 (legacy fallback)"
say ""
read -r -p "Choose [1/2] (default 1): " backend_choice
case "${backend_choice:-1}" in
    1) install_ibc; exit 0 ;;
    2) ok "xdotool backend — configuring the login watchdog" ;;
    *) die "Invalid choice '$backend_choice'" ;;
esac

# xdotool backend needs the systemd unit template:
[[ -f "$TEMPLATE_DIR/ibgw-watchdog.service" ]] || die "systemd/ibgw-watchdog.service template missing"

# ── 1. Display mode ───────────────────────────────────────────────────────────
say "How does IB Gateway get an X display?"
say "  1) attach  — use the existing desktop / VNC session (recommended)"
say "  2) xvfb    — headless virtual display, no desktop login needed"
say ""
read -r -p "Choose [1/2] (default 1): " mode_choice
case "${mode_choice:-1}" in
    1) MODE="attach" ;;
    2) MODE="xvfb" ;;
    *) die "Invalid choice '$mode_choice'" ;;
esac

# ── 2. Dependencies ───────────────────────────────────────────────────────────
missing=()
for bin in xdotool scrot curl; do
    command -v "$bin" >/dev/null 2>&1 || missing+=("$bin")
done
if [[ "$MODE" == "xvfb" ]] && ! command -v Xvfb >/dev/null 2>&1; then
    missing+=("xvfb")
fi
if [[ ${#missing[@]} -gt 0 ]]; then
    warn "Missing dependencies: ${missing[*]}"
    say  "    Install with:  sudo apt install -y ${missing[*]}"
    read -r -p "    Continue anyway? [y/N]: " cont
    [[ "${cont:-N}" =~ ^[Yy]$ ]] || die "Install the dependencies, then re-run."
else
    ok "Dependencies present"
fi

# ── 3. Resolve display + Xauthority ───────────────────────────────────────────
if [[ "$MODE" == "xvfb" ]]; then
    DISPLAY_VAL=":99"
    XAUTH_VAL=""
    AFTER="ibgw-xvfb.service"
    EXTRA_UNIT="Requires=ibgw-xvfb.service"
    WANTED_BY="default.target"
    ok "Headless mode: IB Gateway will run on virtual display :99"
else
    DISPLAY_VAL="${DISPLAY:-}"
    if [[ -z "$DISPLAY_VAL" ]]; then
        for sock in /tmp/.X11-unix/X*; do
            [[ -e "$sock" ]] && DISPLAY_VAL=":${sock##*/X}" && break
        done
    fi
    DISPLAY_VAL="${DISPLAY_VAL:-:0}"
    read -r -p "X display to attach to (default ${DISPLAY_VAL}): " d
    DISPLAY_VAL="${d:-$DISPLAY_VAL}"

    XAUTH_VAL="${XAUTHORITY:-}"
    [[ -z "$XAUTH_VAL" && -f "$HOME/.Xauthority" ]] && XAUTH_VAL="$HOME/.Xauthority"
    if [[ -z "$XAUTH_VAL" ]]; then
        # GDM/GNOME keeps it at /run/user/<uid>/gdm/Xauthority (depth 2)
        XAUTH_VAL="$(find "/run/user/$(id -u)" -maxdepth 2 -iname '*xauth*' 2>/dev/null | head -1 || true)"
    fi
    read -r -p "XAUTHORITY file (default ${XAUTH_VAL:-none}): " x
    XAUTH_VAL="${x:-$XAUTH_VAL}"

    AFTER="graphical-session.target"
    EXTRA_UNIT="PartOf=graphical-session.target"
    WANTED_BY="graphical-session.target"
    ok "Attach mode: DISPLAY=${DISPLAY_VAL}  XAUTHORITY=${XAUTH_VAL:-<none>}"
fi

# Keep the watchdog's own DISPLAY_ENV aligned with the chosen display
CONF_FILE=""
for c in "$SCRIPT_DIR/ibgw_watchdog.conf" "${XDG_CONFIG_HOME:-$HOME/.config}/ibgw_watchdog.conf" "$HOME/ibgw_watchdog.conf"; do
    [[ -f "$c" ]] && CONF_FILE="$c" && break
done
if [[ -n "$CONF_FILE" ]]; then
    if grep -q '^DISPLAY_ENV=' "$CONF_FILE"; then
        sed -i "s|^DISPLAY_ENV=.*|DISPLAY_ENV=${DISPLAY_VAL}|" "$CONF_FILE"
    else
        printf '\nDISPLAY_ENV=%s\n' "$DISPLAY_VAL" >> "$CONF_FILE"
    fi
    ok "Set DISPLAY_ENV=${DISPLAY_VAL} in $CONF_FILE"
else
    warn "No ibgw_watchdog.conf yet — copy ibgw_watchdog.conf.example and set DISPLAY_ENV=${DISPLAY_VAL}"
fi

# ── 4. Write the unit(s) ──────────────────────────────────────────────────────
mkdir -p "$USER_UNIT_DIR"

if [[ -n "$XAUTH_VAL" ]]; then
    XAUTH_LINE="Environment=XAUTHORITY=${XAUTH_VAL}"
else
    XAUTH_LINE=""
fi

sed \
    -e "s|@AFTER@|${AFTER}|g" \
    -e "s|@EXTRA_UNIT@|${EXTRA_UNIT}|g" \
    -e "s|@DISPLAY@|${DISPLAY_VAL}|g" \
    -e "s|@XAUTH_LINE@|${XAUTH_LINE}|g" \
    -e "s|@SCRIPT_PATH@|${WATCHDOG_SCRIPT}|g" \
    -e "s|@WANTED_BY@|${WANTED_BY}|g" \
    "$TEMPLATE_DIR/ibgw-watchdog.service" > "$USER_UNIT_DIR/ibgw-watchdog.service"
ok "Wrote $USER_UNIT_DIR/ibgw-watchdog.service"

if [[ "$MODE" == "xvfb" ]]; then
    cp "$TEMPLATE_DIR/ibgw-xvfb.service" "$USER_UNIT_DIR/ibgw-xvfb.service"
    ok "Wrote $USER_UNIT_DIR/ibgw-xvfb.service"
fi

# ── 5. Enable linger (start at boot without an interactive login) ─────────────
if [[ "$(loginctl show-user "$USER" -p Linger --value 2>/dev/null)" == "yes" ]]; then
    ok "Linger already enabled for $USER"
elif loginctl enable-linger "$USER" 2>/dev/null; then
    ok "Enabled linger for $USER (services start at boot)"
else
    warn "Could not enable linger automatically. Run:  sudo loginctl enable-linger $USER"
fi

# ── 6. Enable + start ─────────────────────────────────────────────────────────
systemctl --user daemon-reload
if [[ "$MODE" == "xvfb" ]]; then
    systemctl --user enable --now ibgw-xvfb.service
    ok "Enabled + started ibgw-xvfb.service"
fi
systemctl --user enable --now ibgw-watchdog.service
ok "Enabled + started ibgw-watchdog.service"

# ── 7. Report ─────────────────────────────────────────────────────────────────
say ""
say "================================================================="
say " Installed. The watchdog now starts on boot."
say "================================================================="
say ""
say "Status:   systemctl --user status ibgw-watchdog"
say "Logs:     journalctl --user-unit ibgw-watchdog -f"
say "Stop:     systemctl --user stop ibgw-watchdog"
say "Disable:  systemctl --user disable ibgw-watchdog"
say ""
if [[ "$MODE" == "attach" ]]; then
    say "NOTE: attach mode is hands-off at boot ONLY if your desktop auto-logs-in."
    say "      Otherwise the watchdog waits until you log into the desktop."
fi
if [[ "$MODE" == "xvfb" ]]; then
    say "NOTE: to calibrate the headless Gateway, attach a VNC viewer to :99:"
    say "      x11vnc -display :99 -localhost -nopw -forever &"
fi
say ""
