#!/bin/sh
#
# PadDisplay iOS 10.3.3 kiosk layer
#
# Apply only AFTER tools/debloat-ios10.sh has proven stable.
# This layer is separately reversible and intentionally keeps core:
# Wi-Fi/DNS, USB/lockdown, SpringBoard/backboardd, power, audio/media,
# security/AMFI, preferences, activation, and jailbreak services.
#
# Usage:
#   sh kiosk-ios10.sh dry-run
#   su root -c 'sh kiosk-ios10.sh apply'
#   sh kiosk-ios10.sh status
#   su root -c 'sh kiosk-ios10.sh restore'
#

set -u

STATE_DIR="/var/mobile/Library/PadDisplayKiosk"
STATE_FILE="$STATE_DIR/disabled-by-pad-display-kiosk.txt"
LOG_FILE="$STATE_DIR/kiosk.log"

AUTOLAUNCH_PLIST="/Library/LaunchDaemons/com.ipaddisplay.kiosk-autolaunch.plist"
AUTOLAUNCH_HELPER="/usr/local/bin/paddisplay-kiosk-launch.sh"
AUTOLAUNCH_LABEL="com.ipaddisplay.kiosk-autolaunch"
PADDISPLAY_BUNDLE_ID="com.ipaddisplay.client"

install_autolaunch() {
    need_root apply

    if [ ! -x /usr/bin/uiopen ]; then
        log "WARN uiopen not found/executable; skipping PadDisplay autolaunch."
        return 0
    fi

    mkdir -p /usr/local/bin

    cat > "$AUTOLAUNCH_HELPER" <<'EOF'
#!/bin/sh
# Wait for SpringBoard to be usable, then launch PadDisplay as mobile.
i=0
while [ "$i" -lt 60 ]; do
    if launchctl list 2>/dev/null | grep -Fq "com.apple.SpringBoard"; then
        break
    fi
    if ps ax 2>/dev/null | grep -v grep | grep -q "[S]pringBoard"; then
        break
    fi
    i=$((i + 1))
    sleep 1
done

sleep 5

if [ -x /usr/bin/uiopen ]; then
    su mobile -c "/usr/bin/uiopen --bundleid com.ipaddisplay.client" >/dev/null 2>&1 ||     /usr/bin/uiopen --bundleid com.ipaddisplay.client >/dev/null 2>&1 || true
fi
EOF
    chmod 755 "$AUTOLAUNCH_HELPER"

    cat > "$AUTOLAUNCH_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$AUTOLAUNCH_LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$AUTOLAUNCH_HELPER</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>LaunchOnlyOnce</key>
    <true/>
</dict>
</plist>
EOF
    chmod 644 "$AUTOLAUNCH_PLIST"

    launchctl unload "$AUTOLAUNCH_PLIST" >/dev/null 2>&1 || true
    launchctl load "$AUTOLAUNCH_PLIST" >/dev/null 2>&1 || true
    log "INSTALLED PadDisplay autolaunch."
}

remove_autolaunch() {
    need_root restore
    if [ -f "$AUTOLAUNCH_PLIST" ]; then
        launchctl unload "$AUTOLAUNCH_PLIST" >/dev/null 2>&1 || true
        rm -f "$AUTOLAUNCH_PLIST"
    fi
    rm -f "$AUTOLAUNCH_HELPER"
    log "REMOVED PadDisplay autolaunch."
}

autolaunch_status() {
    if [ -f "$AUTOLAUNCH_PLIST" ] && [ -x "$AUTOLAUNCH_HELPER" ]; then
        echo "autolaunch  installed"
    else
        echo "autolaunch  not installed"
    fi
}

SERVICES="
/System/Library/LaunchDaemons/com.apple.homed.plist
/System/Library/LaunchDaemons/com.apple.suggestd.plist
/System/Library/LaunchDaemons/com.apple.familycircled.plist
/System/Library/LaunchDaemons/com.apple.familynotificationd.plist
/System/Library/LaunchDaemons/com.apple.CallHistorySyncHelper.plist
/System/Library/LaunchDaemons/com.apple.printd.plist
/System/Library/LaunchDaemons/com.apple.screensharingserver.plist
/System/Library/LaunchDaemons/com.apple.carkitd.plist
/System/Library/LaunchDaemons/com.apple.quicklook.ThumbnailsAgent.plist
/System/Library/LaunchDaemons/com.apple.languageassetd.plist
/System/Library/LaunchDaemons/com.apple.mobilestoredemod.plist
/System/Library/LaunchDaemons/com.apple.mobilestoredemodhelper.plist
/System/Library/LaunchDaemons/com.apple.managedconfiguration.mdmd.plist
/System/Library/LaunchDaemons/com.apple.managedconfiguration.teslad.plist
/System/Library/LaunchDaemons/com.apple.imtransferagent.plist
/System/Library/LaunchDaemons/com.apple.imautomatichistorydeletionagent.plist
/System/Library/LaunchDaemons/com.apple.nanoregistryd.plist
/System/Library/LaunchDaemons/com.apple.nanotimekitcompaniond.plist
/System/Library/LaunchDaemons/com.apple.nanoregistrylaunchd.plist
/System/Library/LaunchDaemons/com.apple.companion_proxy.plist
/System/Library/LaunchDaemons/com.apple.duetexpertd.plist
/System/Library/LaunchDaemons/com.apple.coreduetd.plist
"

log() {
    echo "$*"
    if [ -d "$STATE_DIR" ]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG_FILE" 2>/dev/null || true
    fi
}

need_root() {
    if [ "$(id -u)" != "0" ]; then
        echo "ERROR: this action must be run as root."
        echo "Try: su root -c 'sh $0 $1'"
        exit 1
    fi
}

ensure_state_dir() {
    mkdir -p "$STATE_DIR"
    chmod 755 "$STATE_DIR" 2>/dev/null || true
}

service_label() {
    plist="$1"
    base="${plist##*/}"
    echo "${base%.plist}"
}

is_loaded() {
    label="$(service_label "$1")"
    launchctl list 2>/dev/null | grep -Fq "$label"
}

disable_one() {
    plist="$1"
    if [ ! -f "$plist" ]; then
        log "SKIP missing: $plist"
        return 0
    fi
    if grep -Fxq "$plist" "$STATE_FILE" 2>/dev/null; then
        log "SKIP already recorded: $plist"
        return 0
    fi
    if is_loaded "$plist"; then
        if launchctl unload -w "$plist" >/dev/null 2>&1; then
            echo "$plist" >> "$STATE_FILE"
            log "DISABLED: $plist"
        else
            log "WARN could not unload: $plist"
        fi
    else
        log "SKIP already unloaded before kiosk layer: $plist"
    fi
}

restore_one() {
    plist="$1"
    if [ ! -f "$plist" ]; then
        log "SKIP restore missing: $plist"
        return 0
    fi
    if launchctl load -w "$plist" >/dev/null 2>&1; then
        log "RESTORED: $plist"
    else
        log "WARN could not restore: $plist"
    fi
}

show_status() {
    echo "PadDisplay iOS 10.3.3 kiosk status"
    echo "State file: $STATE_FILE"
    echo
    for plist in $SERVICES; do
        if [ ! -f "$plist" ]; then
            printf "%-10s %s\n" "missing" "$plist"
        elif is_loaded "$plist"; then
            printf "%-10s %s\n" "loaded" "$plist"
        elif grep -Fxq "$plist" "$STATE_FILE" 2>/dev/null; then
            printf "%-10s %s\n" "disabled*" "$plist"
        else
            printf "%-10s %s\n" "unloaded" "$plist"
        fi
    done
    echo
    echo "* disabled by this kiosk script"
    echo
    autolaunch_status
}

dry_run() {
    echo "PadDisplay iOS 10.3.3 kiosk dry run"
    echo
    for plist in $SERVICES; do
        if [ ! -f "$plist" ]; then
            echo "MISSING  $plist"
        elif is_loaded "$plist"; then
            echo "WOULD DISABLE  $plist"
        else
            echo "LEAVE ALONE (already unloaded)  $plist"
        fi
    done
    echo
    echo "No changes made."
}

apply_changes() {
    need_root apply
    ensure_state_dir
    touch "$STATE_FILE"
    log "=== PadDisplay kiosk layer: apply ==="
    for plist in $SERVICES; do
        disable_one "$plist"
    done
    install_autolaunch
    log "Kiosk layer applied."
    echo
    echo "Reboot, then verify jailbreak, Wi-Fi, USB streaming, touch,"
    echo "and local audio playback before adding any more services."
}

restore_changes() {
    need_root restore
    ensure_state_dir
    if [ ! -s "$STATE_FILE" ]; then
        log "Nothing recorded to restore."
        exit 0
    fi
    log "=== PadDisplay kiosk layer: restore ==="
    remove_autolaunch
    while IFS= read -r plist; do
        [ -n "$plist" ] && restore_one "$plist"
    done < "$STATE_FILE"
    cp "$STATE_FILE" "$STATE_FILE.restored.$(date +%Y%m%d-%H%M%S)" 2>/dev/null || true
    : > "$STATE_FILE"
    log "Kiosk layer restored."
    echo "Reboot recommended."
}

case "${1:-}" in
    dry-run) dry_run ;;
    apply) apply_changes ;;
    status) ensure_state_dir; show_status ;;
    restore) restore_changes ;;
    *) echo "Usage: sh $0 {dry-run|apply|status|restore}"; exit 2 ;;
esac
