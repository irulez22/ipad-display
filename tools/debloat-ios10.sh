#!/bin/sh
#
# PadDisplay iOS 10.3.3 conservative debloat
#
# Usage:
#   sh debloat-ios10.sh dry-run
#   sudo sh debloat-ios10.sh apply
#   sh debloat-ios10.sh status
#   sudo sh debloat-ios10.sh restore
#
# This script does NOT delete or rename system files.
# It only unloads a small allowlist of nonessential launch daemons and records
# exactly what it changed so the operation can be reversed.
#

set -u

STATE_DIR="/var/mobile/Library/PadDisplayDebloat"
STATE_FILE="$STATE_DIR/disabled-by-pad-display.txt"
LOG_FILE="$STATE_DIR/debloat.log"

# Conservative allowlist for a dedicated display iPad.
# Core networking, DNS, USB/lockdown, SpringBoard/backboardd, audio,
# security, preferences, activation, and jailbreak-critical services are
# intentionally not touched.
SERVICES="
/System/Library/LaunchDaemons/com.apple.mDNSResponderHelper.plist
/System/Library/LaunchDaemons/com.apple.captiveagent.plist
/System/Library/LaunchDaemons/com.apple.parsecd.plist
/System/Library/LaunchDaemons/com.apple.OTACrashCopier.plist
/System/Library/LaunchDaemons/com.apple.ReportCrash.Jetsam.plist
/System/Library/LaunchDaemons/com.apple.ReportCrash.SafetyNet.plist
/System/Library/LaunchDaemons/com.apple.ReportCrash.plist
/System/Library/LaunchDaemons/com.apple.CrashHousekeeping.plist
/System/Library/LaunchDaemons/com.apple.DumpBasebandCrash.plist
/System/Library/LaunchDaemons/com.apple.DumpPanic.plist
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
        # Do not claim ownership of a daemon that was already disabled.
        log "SKIP already unloaded before PadDisplay: $plist"
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
    echo "PadDisplay iOS 10.3.3 debloat status"
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
    echo "* disabled by this script"
}

dry_run() {
    echo "PadDisplay iOS 10.3.3 debloat dry run"
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

    log "=== PadDisplay conservative debloat: apply ==="
    for plist in $SERVICES; do
        disable_one "$plist"
    done

    log "Apply complete."
    echo
    echo "Recommended: reboot the iPad, then verify Wi-Fi, USB streaming,"
    echo "touch, and audio before considering any further debloat."
    echo
    echo "Restore with:"
    echo "  su root -c 'sh $0 restore'"
}

restore_changes() {
    need_root restore
    ensure_state_dir

    if [ ! -s "$STATE_FILE" ]; then
        log "Nothing recorded to restore."
        exit 0
    fi

    log "=== PadDisplay conservative debloat: restore ==="

    # Restore only daemons this script actually disabled.
    while IFS= read -r plist; do
        [ -n "$plist" ] && restore_one "$plist"
    done < "$STATE_FILE"

    cp "$STATE_FILE" "$STATE_FILE.restored.$(date +%Y%m%d-%H%M%S)" 2>/dev/null || true
    : > "$STATE_FILE"

    log "Restore complete."
    echo
    echo "Reboot recommended."
}

case "${1:-}" in
    dry-run)
        dry_run
        ;;
    apply)
        apply_changes
        ;;
    status)
        ensure_state_dir
        show_status
        ;;
    restore)
        restore_changes
        ;;
    *)
        echo "Usage: sh $0 {dry-run|apply|status|restore}"
        exit 2
        ;;
esac
