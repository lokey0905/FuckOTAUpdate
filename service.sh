#!/system/bin/sh

MODDIR=${0%/*}
LOGFILE="$MODDIR/disable_ota.log"

log_print() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOGFILE"

    # Avoid unlimited log growth.
    if [ -f "$LOGFILE" ] && [ "$(wc -c < "$LOGFILE")" -gt 102400 ]; then
        tail -n 200 "$LOGFILE" > "$LOGFILE.tmp"
        mv "$LOGFILE.tmp" "$LOGFILE"
    fi
}

get_users() {
    USERS="$(pm list users 2>/dev/null | sed -n 's/.*UserInfo{\([0-9][0-9]*\):.*/\1/p')"
    [ -z "$USERS" ] && USERS="0"
    echo "$USERS"
}

disable_component() {
    USER_ID="$1"
    COMPONENT="$2"

    # Important:
    # For components, use "pm disable", not "pm disable-user".
    # On some Android builds, "pm disable-user component" returns RC=0 but keeps the component enabled.
    OUT="$(pm disable --user "$USER_ID" "$COMPONENT" 2>&1)"

    case "$OUT" in
        *"new state: disabled"*|*"new state: disabled-user"*)
            return 0
            ;;
    esac

    # Fallback for ROMs where pm wrapper behaves differently.
    OUT2="$(cmd package set-enabled-setting "$COMPONENT" disabled --user "$USER_ID" 2>&1)"
    case "$OUT2" in
        *"disabled"*)
            return 0
            ;;
    esac

    log_print "WARN user=$USER_ID component=$COMPONENT pm=[$OUT] cmd=[$OUT2]"
    return 1
}

disable_ota_components_user() {
    USER_ID="$1"

    # Hide Pixel Factory OTA package if present.
    pm uninstall -k --user "$USER_ID" com.google.android.factoryota >/dev/null 2>&1

    # GMS OTA components.
    disable_component "$USER_ID" "com.google.android.gms/.update.SystemUpdateActivity"
    disable_component "$USER_ID" "com.google.android.gms/.update.SystemUpdateService"
    disable_component "$USER_ID" "com.google.android.gms/.update.SystemUpdateService\$ActiveReceiver"
    disable_component "$USER_ID" "com.google.android.gms/.update.SystemUpdateService\$Receiver"
    disable_component "$USER_ID" "com.google.android.gms/.update.SystemUpdateService\$SecretCodeReceiver"

    # GSF OTA components.
    disable_component "$USER_ID" "com.google.android.gsf/.update.SystemUpdateActivity"
    disable_component "$USER_ID" "com.google.android.gsf/.update.SystemUpdatePanoActivity"
    disable_component "$USER_ID" "com.google.android.gsf/.update.SystemUpdateService"
    disable_component "$USER_ID" "com.google.android.gsf/.update.SystemUpdateService\$Receiver"
    disable_component "$USER_ID" "com.google.android.gsf/.update.SystemUpdateService\$SecretCodeReceiver"
}

disable_ota_components() {
    for USER_ID in $(get_users); do
        disable_ota_components_user "$USER_ID"
    done
}

close_update_screen_if_open() {
    if dumpsys window 2>/dev/null | grep -E 'mCurrentFocus|mFocusedApp' | grep -q 'com.google.android.gms.*SystemUpdateActivity'; then
        am force-stop com.google.android.gms >/dev/null 2>&1
        log_print "closed foreground GMS SystemUpdateActivity"
    fi

    if dumpsys window 2>/dev/null | grep -E 'mCurrentFocus|mFocusedApp' | grep -q 'com.google.android.gsf.*SystemUpdate'; then
        am force-stop com.google.android.gsf >/dev/null 2>&1
        log_print "closed foreground GSF SystemUpdate activity"
    fi
}

# Wait until Android has finished booting.
while [ "$(getprop sys.boot_completed)" != "1" ]; do
    sleep 2
done

sleep 20
log_print "boot completed, applying OTA block"
disable_ota_components
close_update_screen_if_open

COUNT=0

# Keep re-applying because GMS/GSF updates can restore component states.
while true; do
    sleep 300
    disable_ota_components
    close_update_screen_if_open

    COUNT=$((COUNT + 1))
    if [ "$COUNT" -ge 12 ]; then
        log_print "periodic OTA block re-applied"
        COUNT=0
    fi
done
