#!/usr/bin/env bash
# =============================================================================
# ibgw_watchdog.sh — IB Gateway auto-recovery watchdog
# =============================================================================
#
# Monitors IB Gateway's API port and automatically recovers from:
#   Port down (crash / maintenance restart)
#   Login Error dialogs (wrong credentials, locked account)
#   Gateway error dialogs (soft-token expiry, SSL failures, connection errors)
#   "Existing session detected" dialogs (kills and restarts cleanly)
#   Mid-session IB server disconnects (re-drives the login form)
#
# Requirements:
#   apt install -y xdotool scrot curl
#
# Quick start:
#   1. Copy ibgw_watchdog.conf.example to ibgw_watchdog.conf and fill it in
#   2. chmod 600 ibgw_watchdog.conf   (contains credentials)
#   3. bash ibgw_watchdog.sh --calibrate   (interactive coordinate setup)
#   4. nohup bash ibgw_watchdog.sh >> ~/logs/ibgw_watchdog.log 2>&1 &
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Config search order: same dir as script > XDG config > home
CONFIG_FILE=""
for candidate in \
    "$SCRIPT_DIR/ibgw_watchdog.conf" \
    "${XDG_CONFIG_HOME:-$HOME/.config}/ibgw_watchdog.conf" \
    "$HOME/ibgw_watchdog.conf"; do
    if [[ -f "$candidate" ]]; then
        CONFIG_FILE="$candidate"
        break
    fi
done

if [[ -z "$CONFIG_FILE" && "${1:-}" != "--help" && "${1:-}" != "-h" ]]; then
    echo "ERROR: No config file found. Copy ibgw_watchdog.conf.example and edit it."
    exit 1
fi

[[ -n "$CONFIG_FILE" ]] && source "$CONFIG_FILE"

# Defaults
IBGW_PORT="${IBGW_PORT:-}"
IBGW_BIN="${IBGW_BIN:-}"
DISPLAY_ENV="${DISPLAY_ENV:-${DISPLAY:-:1}}"
CREDS_FILE="${CREDS_FILE:-$HOME/.ibgw_creds}"
LOG_DIR="${LOG_DIR:-$HOME/logs}"
SCREENSHOT_DIR="${SCREENSHOT_DIR:-$LOG_DIR/ibgw_screenshots}"
CHECK_INTERVAL="${CHECK_INTERVAL:-30}"
PORT_UP_TIMEOUT="${PORT_UP_TIMEOUT:-60}"
LOGIN_WAIT="${LOGIN_WAIT:-30}"
WINDOW_SETTLE="${WINDOW_SETTLE:-2}"
ESCALATION_CAP="${ESCALATION_CAP:-6}"
PAPER_TRADING="${PAPER_TRADING:-true}"
ALERT_DISCORD_WEBHOOK="${ALERT_DISCORD_WEBHOOK:-}"
ALERT_TELEGRAM_TOKEN="${ALERT_TELEGRAM_TOKEN:-}"
ALERT_TELEGRAM_CHAT_ID="${ALERT_TELEGRAM_CHAT_ID:-}"
ALERT_WEBHOOK_URL="${ALERT_WEBHOOK_URL:-}"
UNAME_X="${UNAME_X:-410}"; UNAME_Y="${UNAME_Y:-250}"
PASS_X="${PASS_X:-410}";   PASS_Y="${PASS_Y:-310}"
BTN_X="${BTN_X:-395}";     BTN_Y="${BTN_Y:-375}"
WARN_BTN_X="${WARN_BTN_X:-0}"; WARN_BTN_Y="${WARN_BTN_Y:-0}"

consecutive_failures=0

mkdir -p "${LOG_DIR:-$HOME/logs}" "${SCREENSHOT_DIR:-$HOME/logs/ibgw_screenshots}"

# ── Helpers ───────────────────────────────────────────────────────────────────

log() {
    echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*" | tee -a "${LOG_DIR}/ibgw_watchdog.log"
}

send_alert() {
    local level="$1" title="$2" message="$3"
    if [[ -n "$ALERT_DISCORD_WEBHOOK" ]]; then
        local color
        case "$level" in
            CRITICAL) color=16711680 ;;
            WARNING)  color=16744448 ;;
            *)        color=49151    ;;
        esac
        curl -sf -X POST "$ALERT_DISCORD_WEBHOOK" \
            -H "Content-Type: application/json" \
            -d "{\"embeds\":[{\"title\":\"$title\",\"description\":\"$message\",\"color\":$color}]}" \
            >/dev/null 2>&1 || true
    fi
    if [[ -n "$ALERT_TELEGRAM_TOKEN" && -n "$ALERT_TELEGRAM_CHAT_ID" ]]; then
        curl -sf "https://api.telegram.org/bot${ALERT_TELEGRAM_TOKEN}/sendMessage" \
            -d "chat_id=${ALERT_TELEGRAM_CHAT_ID}" \
            -d "text=[${level}] ${title}: ${message}" \
            >/dev/null 2>&1 || true
    fi
    if [[ -n "$ALERT_WEBHOOK_URL" ]]; then
        curl -sf -X POST "$ALERT_WEBHOOK_URL" \
            -H "Content-Type: application/json" \
            -d "{\"level\":\"$level\",\"title\":\"$title\",\"message\":\"$message\",\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}" \
            >/dev/null 2>&1 || true
    fi
}

discord_alert() { send_alert "$@"; }   # backwards compat

port_up() { timeout 2 bash -c ">/dev/tcp/127.0.0.1/${IBGW_PORT}" 2>/dev/null; }

wait_for_port() {
    local deadline=$(( $(date +%s) + PORT_UP_TIMEOUT ))
    log "Waiting up to ${PORT_UP_TIMEOUT}s for port ${IBGW_PORT}..."
    while [[ $(date +%s) -lt $deadline ]]; do
        port_up && return 0
        sleep 5
    done
    return 1
}

screenshot() {
    DISPLAY="$DISPLAY_ENV" scrot \
        "${SCREENSHOT_DIR}/${1}_$(date -u +%Y%m%dT%H%M%S).png" 2>/dev/null || true
}

# ── Auto-detection ────────────────────────────────────────────────────────────

detect_port() {
    [[ -n "$IBGW_PORT" ]] && return 0
    for f in "$HOME/Jts/jts.ini" "$HOME/.Jts/jts.ini"; do
        if [[ -f "$f" ]]; then
            local p
            p=$(grep -iE "^(port|apiport|socketport)\s*=" "$f" 2>/dev/null \
                | grep -oP '\d{4}' | head -1)
            if [[ -n "$p" ]]; then
                IBGW_PORT="$p"
                log "Port $IBGW_PORT detected from $f"
                return 0
            fi
        fi
    done
    for p in 4002 4001 4003; do
        if timeout 2 bash -c ">/dev/tcp/127.0.0.1/$p" 2>/dev/null; then
            IBGW_PORT="$p"
            log "Port $IBGW_PORT detected (active scan)"
            return 0
        fi
    done
    IBGW_PORT=4002
    log "Port not detected, defaulting to $IBGW_PORT. Set IBGW_PORT= in config to override."
}

detect_ibgw_binary() {
    [[ -n "$IBGW_BIN" && -x "$IBGW_BIN" ]] && return 0
    local pid
    pid=$(pgrep -f "i4j_jres.*java" | head -1 2>/dev/null || true)
    if [[ -n "$pid" ]]; then
        local cwd
        cwd=$(readlink "/proc/$pid/cwd" 2>/dev/null || true)
        if [[ -n "$cwd" ]]; then
            local c
            c=$(find "$cwd" -maxdepth 3 -name "ibgateway" -type f -perm /111 2>/dev/null | head -1)
            if [[ -n "$c" ]]; then
                IBGW_BIN="$c"; log "Binary detected from running process: $IBGW_BIN"; return 0
            fi
        fi
    fi
    local found
    found=$(ls -dt \
        "$HOME"/Jts/ibgateway/*/ibgateway \
        "$HOME"/ibgateway/*/ibgateway \
        /opt/ibgateway/*/ibgateway \
        2>/dev/null | head -1 || true)
    if [[ -n "$found" && -x "$found" ]]; then
        IBGW_BIN="$found"; log "Binary detected: $IBGW_BIN"; return 0
    fi
    local w
    w=$(which ibgateway 2>/dev/null || true)
    if [[ -n "$w" ]]; then
        IBGW_BIN="$w"; log "Binary detected via PATH: $IBGW_BIN"; return 0
    fi
    log "ERROR: Cannot find ibgateway binary. Set IBGW_BIN= in $CONFIG_FILE."
    return 1
}

# ── Calibration mode ──────────────────────────────────────────────────────────

calibrate() {
    echo ""
    echo "================================================================="
    echo " IB Gateway Calibration — records login field coordinates"
    echo "================================================================="
    echo ""
    echo "Open IB Gateway so the LOGIN DIALOG (username/password) is visible."
    echo "Press Enter when ready..."
    read -r
    local win
    win=$(ibgw_windows | head -1)
    if [[ -z "$win" ]]; then
        echo "ERROR: No IB Gateway window found. Open IB Gateway login first."
        exit 1
    fi
    echo "Found window: $win  $(DISPLAY=$DISPLAY_ENV xdotool getwindowgeometry "$win" 2>/dev/null)"
    echo ""
    echo "Hover over the USERNAME field and press Enter..."
    read -r
    eval "$(DISPLAY="$DISPLAY_ENV" xdotool getmouselocation --shell 2>/dev/null)"
    local ux=$X uy=$Y
    echo "  USERNAME: ($ux, $uy)"
    echo ""
    echo "Hover over the PASSWORD field and press Enter..."
    read -r
    eval "$(DISPLAY="$DISPLAY_ENV" xdotool getmouselocation --shell 2>/dev/null)"
    local px=$X py=$Y
    echo "  PASSWORD: ($px, $py)"
    echo ""
    echo "Hover over the LOGIN BUTTON and press Enter..."
    read -r
    eval "$(DISPLAY="$DISPLAY_ENV" xdotool getmouselocation --shell 2>/dev/null)"
    local bx=$X by=$Y
    echo "  LOGIN BUTTON: ($bx, $by)"
    echo ""
    echo "If a 'Paper Trading Warning' popup appears after login, hover over"
    echo "its OK button and press Enter. Otherwise just press Enter to skip..."
    read -r
    eval "$(DISPLAY="$DISPLAY_ENV" xdotool getmouselocation --shell 2>/dev/null)"
    local wx=$X wy=$Y
    local save_warn=""
    if [[ "$wx" -ne "$bx" || "$wy" -ne "$by" ]]; then
        save_warn="WARN_BTN_X=$wx"$'\n'"WARN_BTN_Y=$wy"
        echo "  WARNING OK: ($wx, $wy)"
    fi
    {
        echo ""
        echo "# Calibrated $(date)"
        echo "UNAME_X=$ux"
        echo "UNAME_Y=$uy"
        echo "PASS_X=$px"
        echo "PASS_Y=$py"
        echo "BTN_X=$bx"
        echo "BTN_Y=$by"
        [[ -n "$save_warn" ]] && echo "$save_warn"
    } >> "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE"
    echo ""
    echo "Coordinates saved to $CONFIG_FILE"
    echo ""
    echo "Start watchdog:"
    echo "  nohup bash $0 >> ~/logs/ibgw_watchdog.log 2>&1 &"
    echo "================================================================="
}

# ── Process management ────────────────────────────────────────────────────────

kill_ibgw() {
    log "Killing IBGW process..."
    # Escalate SIGTERM -> SIGKILL. A hung gateway ignores SIGTERM and survives
    # to hold the IB login session, blocking port 4002 and triggering an endless
    # respawn loop (incident 2026-06-11). Confirm it is dead before returning so
    # the caller never stacks a duplicate gateway.
    pkill -TERM -f "i4j_jres.*java" 2>/dev/null || true
    pkill -TERM -f "ibgateway"      2>/dev/null || true
    local i
    for i in 1 2 3 4 5; do
        sleep 1
        pgrep -f "i4j_jres.*java" >/dev/null 2>&1 || { log "IBGW stopped (SIGTERM)"; return 0; }
    done
    log "IBGW survived SIGTERM -- escalating to SIGKILL"
    pkill -KILL -f "i4j_jres.*java" 2>/dev/null || true
    pkill -KILL -f "ibgateway"      2>/dev/null || true
    sleep 2
    if pgrep -f "i4j_jres.*java" >/dev/null 2>&1; then
        log "ERROR: IBGW still alive after SIGKILL -- manual intervention needed"
    else
        log "IBGW killed (SIGKILL)"
    fi
}

# IBKR rebrands the window TITLE between versions ("IB Gateway" → "IBKR Gateway"
# → …), which silently broke a --name "IB Gateway" search. The install4j
# WM_CLASS is stable across versions, so match on that, with a title-regex
# fallback for older builds.
IBGW_WM_CLASS="install4j-ibgateway-GWClient"

ibgw_windows() {
    local wins
    wins=$(DISPLAY="$DISPLAY_ENV" xdotool search --class "$IBGW_WM_CLASS" 2>/dev/null || true)
    [[ -z "$wins" ]] && wins=$(DISPLAY="$DISPLAY_ENV" xdotool search --name "IB.*Gateway" 2>/dev/null || true)
    echo "$wins"
}

# The login frame is a "…Gateway"-titled window narrower than the main window
# (≈790px vs ≈1850px). The width band also excludes the app's helper dialogs
# (Warning, Pending Tasks, Content window, 1×1 stubs), which share the class.
find_login_window() {
    local w name width
    for w in $(ibgw_windows); do
        name=$(DISPLAY="$DISPLAY_ENV" xdotool getwindowname "$w" 2>/dev/null || echo "")
        width=$(DISPLAY="$DISPLAY_ENV" xdotool getwindowgeometry "$w" 2>/dev/null \
            | grep -oP 'Geometry: \K\d+' | head -1)
        [[ -z "$width" ]] && continue
        if [[ "$name" == *[Gg]ateway* && "$width" -ge 100 && "$width" -lt 900 ]]; then
            echo "$w"; return 0
        fi
    done
    return 1
}

# True when IBGW's wide main dashboard (≥900px "…Gateway") is open — i.e. we are
# logged in. The login form and the post-login status window are the SAME ~790px
# window (it transforms in place), so the only reliable "logged in" tell is the
# main dashboard appearing alongside it.
ibgw_main_window_present() {
    local w name width
    for w in $(ibgw_windows); do
        name=$(DISPLAY="$DISPLAY_ENV" xdotool getwindowname "$w" 2>/dev/null || echo "")
        width=$(DISPLAY="$DISPLAY_ENV" xdotool getwindowgeometry "$w" 2>/dev/null \
            | grep -oP 'Geometry: \K\d+' | head -1)
        [[ -n "$width" && "$name" == *[Gg]ateway* && "$width" -ge 900 ]] && return 0
    done
    return 1
}

# IBKR rebrands the window TITLE between versions ("IB Gateway" → "IBKR Gateway"
# → …), which silently broke a --name "IB Gateway" search. The install4j
# WM_CLASS is stable across versions, so match on that, with a title-regex
# fallback for older builds.
IBGW_WM_CLASS="install4j-ibgateway-GWClient"

ibgw_windows() {
    local wins
    wins=$(DISPLAY="$DISPLAY_ENV" xdotool search --class "$IBGW_WM_CLASS" 2>/dev/null || true)
    [[ -z "$wins" ]] && wins=$(DISPLAY="$DISPLAY_ENV" xdotool search --name "IB.*Gateway" 2>/dev/null || true)
    echo "$wins"
}

# The login frame is a "…Gateway"-titled window narrower than the main window
# (≈790px vs ≈1850px). The width band also excludes the app's helper dialogs
# (Warning, Pending Tasks, Content window, 1×1 stubs), which share the class.
find_login_window() {
    local w name width
    for w in $(ibgw_windows); do
        name=$(DISPLAY="$DISPLAY_ENV" xdotool getwindowname "$w" 2>/dev/null || echo "")
        width=$(DISPLAY="$DISPLAY_ENV" xdotool getwindowgeometry "$w" 2>/dev/null \
            | grep -oP 'Geometry: \K\d+' | head -1)
        [[ -z "$width" ]] && continue
        if [[ "$name" == *[Gg]ateway* && "$width" -ge 100 && "$width" -lt 900 ]]; then
            echo "$w"; return 0
        fi
    done
    return 1
}

# True when IBGW's wide main dashboard (≥900px "…Gateway") is open — i.e. we are
# logged in. The login form and the post-login status window are the SAME ~790px
# window (it transforms in place), so the only reliable "logged in" tell is the
# main dashboard appearing alongside it.
ibgw_main_window_present() {
    local w name width
    for w in $(ibgw_windows); do
        name=$(DISPLAY="$DISPLAY_ENV" xdotool getwindowname "$w" 2>/dev/null || echo "")
        width=$(DISPLAY="$DISPLAY_ENV" xdotool getwindowgeometry "$w" 2>/dev/null \
            | grep -oP 'Geometry: \K\d+' | head -1)
        [[ -n "$width" && "$name" == *[Gg]ateway* && "$width" -ge 900 ]] && return 0
    done
    return 1
}

do_xdotool_login() {
    log "Attempting xdotool auto-login (DISPLAY=$DISPLAY_ENV)"
    screenshot "pre_login"
    local wid
    wid=$(find_login_window) || { log "No IB Gateway login window found"; return 1; }
    log "Using window ID: $wid"
    DISPLAY="$DISPLAY_ENV" xdotool windowfocus --sync "$wid" 2>/dev/null || true
    sleep "$WINDOW_SETTLE"
    screenshot "window_active"
    local active_win
    active_win=$(DISPLAY="$DISPLAY_ENV" xdotool getactivewindow 2>/dev/null || true)
    if [[ "$active_win" != "$wid" ]]; then
        local aname
        aname=$(DISPLAY="$DISPLAY_ENV" xdotool getwindowname "$active_win" 2>/dev/null || echo "unknown")
        log "SAFETY ABORT: WID $active_win ('$aname') stole focus — credentials NOT typed"
        send_alert "CRITICAL" "IBGW Login Aborted — Focus Mismatch" \
            "WID $active_win ('$aname') has focus. Credentials not typed. Manual login required."
        screenshot "focus_mismatch_abort"
        return 1
    fi
    log "Focus confirmed on WID $wid — proceeding with login"
    local IB_USER IB_PASS
    IB_USER=$(grep "^IB_USER=" "$CREDS_FILE" 2>/dev/null | cut -d= -f2-)
    IB_PASS=$(grep "^IB_PASS=" "$CREDS_FILE" 2>/dev/null | cut -d= -f2-)
    if [[ -z "$IB_USER" || -z "$IB_PASS" ]]; then
        log "ERROR: credentials missing in $CREDS_FILE"
        unset IB_USER IB_PASS; return 1
    fi
    DISPLAY="$DISPLAY_ENV" xdotool mousemove --window "$wid" "$UNAME_X" "$UNAME_Y"
    DISPLAY="$DISPLAY_ENV" xdotool click 1; sleep 0.3
    DISPLAY="$DISPLAY_ENV" xdotool key --clearmodifiers ctrl+a
    DISPLAY="$DISPLAY_ENV" xdotool type --clearmodifiers --delay 50 "$IB_USER"; sleep 0.2
    DISPLAY="$DISPLAY_ENV" xdotool mousemove --window "$wid" "$PASS_X" "$PASS_Y"
    DISPLAY="$DISPLAY_ENV" xdotool click 1; sleep 0.3
    DISPLAY="$DISPLAY_ENV" xdotool key --clearmodifiers ctrl+a
    DISPLAY="$DISPLAY_ENV" xdotool type --clearmodifiers --delay 50 "$IB_PASS"; sleep 0.2
    unset IB_USER IB_PASS
    DISPLAY="$DISPLAY_ENV" xdotool mousemove --window "$wid" "$BTN_X" "$BTN_Y"
    DISPLAY="$DISPLAY_ENV" xdotool click 1
    log "Login submitted"
    screenshot "post_login"
    if [[ "$PAPER_TRADING" == "true" ]]; then
        sleep 5
        local warn_wid
        warn_wid=$(DISPLAY="$DISPLAY_ENV" xdotool search --name "Warning" 2>/dev/null | head -1 || true)
        if [[ -n "$warn_wid" ]]; then
            log "Dismissing paper-trading Warning popup (WID=$warn_wid)"
            _dismiss_ok "$warn_wid"
            screenshot "post_accept"
        fi
    fi
}

restart_and_login() {
    detect_ibgw_binary || {
        log "ERROR: Cannot find IBGW binary"
        send_alert "CRITICAL" "IBGW Cannot Restart" \
            "ibgateway binary not found. Set IBGW_BIN= in $CONFIG_FILE."
        return 1
    }
    kill_ibgw
    log "Starting IBGW: $IBGW_BIN"
    DISPLAY="$DISPLAY_ENV" nohup "$IBGW_BIN" >/dev/null 2>&1 &
    if wait_for_port; then
        log "Port ${IBGW_PORT} up after restart"
        consecutive_failures=0
        send_alert "INFO" "IBGW Recovered" "Port ${IBGW_PORT} is up after restart."
        return 0
    fi
    log "Port ${IBGW_PORT} still down — attempting xdotool login"
    if do_xdotool_login; then
        sleep 5
        local deadline=$(( $(date +%s) + LOGIN_WAIT ))
        while [[ $(date +%s) -lt $deadline ]]; do
            if port_up; then
                log "Port ${IBGW_PORT} up after login"
                consecutive_failures=0
                send_alert "INFO" "IBGW Logged In" "Port ${IBGW_PORT} is up."
                return 0
            fi
            sleep 3
        done
    fi
    consecutive_failures=$(( consecutive_failures + 1 ))
    send_alert "WARNING" "IBGW Still Down" \
        "Port ${IBGW_PORT} down after restart. Consecutive failures: $consecutive_failures."
    if [[ $consecutive_failures -ge $ESCALATION_CAP ]]; then
        send_alert "CRITICAL" "IBGW — Manual Intervention Required" \
            "$consecutive_failures consecutive failures. Cannot recover automatically."
    fi
    return 1
}

# ── Dialog handlers ───────────────────────────────────────────────────────────

# Dismiss a Swing dialog by triggering its default button.
#
# CRITICAL: use XTEST events (plain `xdotool key`/`click`, NO --window). The
# --window form sends XSendEvent, which Java Swing drops via XFilterEvent, so
# those keystrokes/clicks silently do nothing. XTEST is real input and reaches
# Swing — the login typing works for exactly this reason.
#
# The default button is focused, so Return usually does it. Fallback clicks the
# button by position: on IBKR dialogs (e.g. the paper-trading "I understand and
# accept") it sits low — ~88% of dialog height, not the 3/4 mark.
_dismiss_ok() {
    local dlg="$1" X Y WIDTH HEIGHT ys
    # Default button is focused, so Return usually does it.
    DISPLAY="$DISPLAY_ENV" xdotool windowactivate --sync "$dlg" 2>/dev/null || true
    sleep 0.4
    DISPLAY="$DISPLAY_ENV" xdotool key Return 2>/dev/null || true
    sleep 1
    # Fallback: click the default button via XTEST (real input -- Swing drops
    # XSendEvent/--window clicks). The button bar sits ~22px above the dialog
    # bottom edge regardless of dialog height, so target (bottom - N), not a
    # height percentage. The old 88%-of-height aim landed ~10px high and left
    # the paper-trading Warning stuck (incident 2026-06-11). Try a few offsets
    # and bail the instant the dialog is gone.
    for ys in 24 18 30; do
        DISPLAY="$DISPLAY_ENV" xwininfo -id "$dlg" 2>/dev/null | grep -q IsViewable || return 0
        eval "$(DISPLAY="$DISPLAY_ENV" xdotool getwindowgeometry --shell "$dlg" 2>/dev/null)"
        [[ -n "${WIDTH:-}" && -n "${HEIGHT:-}" ]] || return 0
        DISPLAY="$DISPLAY_ENV" xdotool mousemove $(( X + WIDTH / 2 )) $(( Y + HEIGHT - ys )) 2>/dev/null || true
        sleep 0.3
        DISPLAY="$DISPLAY_ENV" xdotool click 1 2>/dev/null || true
        sleep 1
    done
}

handle_login_error_dialog() {
    local dlg
    dlg=$(DISPLAY="$DISPLAY_ENV" xdotool search --name "Login Error" 2>/dev/null | head -1 || true)
    [[ -z "$dlg" ]] && return 1
    log "Login Error dialog (WID=$dlg) — credentials or account issue"
    send_alert "CRITICAL" "IBGW Login Error" \
        "Login failed. Credentials may be invalid or account locked. Performing clean restart."
    screenshot "login_error_dialog"
    _dismiss_ok "$dlg"
    return 0
}

handle_gateway_error_dialog() {
    # "GATEWAY" matches case-insensitively, so it also hits the main window
    # (>700px) and install4j's 1px stub windows (whose class contains
    # "gateway"). A real error modal sits in between — only act on that band,
    # or the handler kills a healthy logged-in session.
    local dlg="" w width
    for w in $(DISPLAY="$DISPLAY_ENV" xdotool search --name "GATEWAY" 2>/dev/null || true); do
        width=$(DISPLAY="$DISPLAY_ENV" xdotool getwindowgeometry "$w" 2>/dev/null \
            | grep -oP 'Geometry: \K\d+' | head -1)
        [[ -n "$width" && "$width" -ge 100 && "$width" -le 700 ]] && dlg=$w && break
    done
    [[ -z "$dlg" ]] && return 1
    log "Gateway error dialog (WID=$dlg, ${width}px) — clicking OK then restart"
    send_alert "WARNING" "IBGW Gateway Error" "Error modal WID=$dlg. Restarting for clean session."
    screenshot "gateway_error_dialog"
    _dismiss_ok "$dlg"
    return 0
}

handle_existing_session_dialog() {
    local win
    win=$(DISPLAY="$DISPLAY_ENV" xdotool search --name "Existing session detected" 2>/dev/null | head -1 || true)
    [[ -z "$win" ]] && return 1
    log "Existing session dialog (WID=$win) — killing and restarting"
    send_alert "WARNING" "IBGW Existing Session Conflict" "Killing IBGW for clean restart."
    kill_ibgw; sleep 3; restart_and_login || true
    return 0
}

check_midsession_login_dialog() {
    local wid
    wid=$(find_login_window) || return 1
    # If the main dashboard is open we are logged in, and this ~790px window is
    # the connected status view — NOT a login prompt. Re-typing credentials into
    # it would be wrong, so only act when the dashboard is absent (genuinely back
    # at the login screen). Trade-off: a mid-session re-auth prompt shown while
    # the dashboard stays open won't auto-recover here; a true disconnect that
    # drops port 4002 is still caught by the port-down restart path.
    ibgw_main_window_present && return 1
    log "Mid-session login dialog (WID=$wid) — port up but IB servers disconnected"
    do_xdotool_login || true
    return 0
}

# ── Entry point ───────────────────────────────────────────────────────────────

case "${1:-}" in
    --calibrate|-c) calibrate; exit 0 ;;
    --help|-h)
        cat <<HELP
Usage: ibgw_watchdog.sh [--calibrate] [--help]

  --calibrate   Interactive setup: hover over login fields to record coordinates
  --help        Show this help

Config: $CONFIG_FILE
HELP
        exit 0 ;;
esac

detect_port
detect_ibgw_binary || true

log "ibgw_watchdog started (PID $$, port ${IBGW_PORT}, interval ${CHECK_INTERVAL}s)"
send_alert "INFO" "IBGW Watchdog Started" "Monitoring port ${IBGW_PORT}. PID $$."

while true; do
    if ! port_up; then
        restart_and_login || true
    else
        if handle_login_error_dialog; then
            kill_ibgw; sleep 3; restart_and_login || true
        elif handle_gateway_error_dialog; then
            kill_ibgw; sleep 3; restart_and_login || true
        else
            handle_existing_session_dialog || true
            check_midsession_login_dialog  || true
        fi
    fi
    sleep "$CHECK_INTERVAL"
done
