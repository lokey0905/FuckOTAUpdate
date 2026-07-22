#!/system/bin/sh

# Shared OTA component handling for service.sh, action.sh, and uninstall.sh.
MODDIR=${MODDIR:-${0%/*}}
LOGFILE="$MODDIR/disable_ota.log"
COMPONENT_CACHE="$MODDIR/ota_components.cache"

FACTORY_OTA_PACKAGE="com.google.android.factoryota"
WATCHED_PACKAGES="com.google.android.gms com.google.android.gsf com.google.android.setupwizard"

# Known Pixel OTA entry points.  The legacy entries are intentionally kept so
# the module also covers older GMS/GSF releases.  Missing components are skipped.
STATIC_OTA_COMPONENTS='
com.google.android.gms/.update.SystemUpdateService
com.google.android.gms/.update.SystemUpdateGcmTaskService
com.google.android.gms/.update.UpdateFromSdCardService
com.google.android.gms/.update.SystemUpdatePersistentListenerService
com.google.android.gms/.update.UucNotificationReceiverService
com.google.android.gms/.update.UpdateJobService
com.google.android.gms/.update.SystemUpdateActivity
com.google.android.gms/.update.phone.PopupDialog
com.google.android.gms/.update.UpdateFromSdCardActivity
com.google.android.gms/.update.OtaSuggestionActivity
com.google.android.gms/.update.OtaSuggestionSummaryProvider
com.google.android.gms/.update.resumeonreboot.ResumeOnRebootEscrowService
com.google.android.gms/.update.SystemUpdateService$ActiveReceiver
com.google.android.gms/.update.SystemUpdateService$Receiver
com.google.android.gms/.update.SystemUpdateService$SecretCodeReceiver
com.google.android.gsf/.update.SystemUpdateActivity
com.google.android.gsf/.update.SystemUpdatePanoActivity
com.google.android.gsf/.update.SystemUpdateService
com.google.android.gsf/.update.SystemUpdateService$Receiver
com.google.android.gsf/.update.SystemUpdateService$SecretCodeReceiver
com.google.android.setupwizard/.update.OtaUpdateActivity
com.google.android.setupwizard/.update.PostCheckinAndUpdateActivity
com.google.android.setupwizard/.update.CompleteInFlightUpdates
com.google.android.setupwizard/.update.OtaUpdateCheck
com.google.android.setupwizard/.update.CompatEarlyUpdate
com.google.android.setupwizard/.update.EarlyUpdate
'

log_print() {
    LOG_MESSAGE="$1"
    echo "$(date '+%Y-%m-%d %H:%M:%S') $LOG_MESSAGE" >> "$LOGFILE"

    # Keep roughly the most recent 300 lines once the log exceeds 100 KiB.
    LOG_SIZE="$(wc -c < "$LOGFILE" 2>/dev/null)"
    case "$LOG_SIZE" in
        ''|*[!0-9]*) LOG_SIZE=0 ;;
    esac

    if [ "$LOG_SIZE" -gt 102400 ]; then
        tail -n 300 "$LOGFILE" > "$LOGFILE.$$.tmp" 2>/dev/null \
            && mv -f "$LOGFILE.$$.tmp" "$LOGFILE"
    fi
}

get_users() {
    USERS="$(pm list users 2>/dev/null | sed -n 's/.*UserInfo{\([0-9][0-9]*\):.*/\1/p')"
    [ -z "$USERS" ] && USERS="0"
    echo "$USERS"
}

discover_ota_components() {
    # dumpsys exposes components with intent filters/providers.  Static entries
    # above cover important services that have no intent filter and older builds.
    dumpsys package com.google.android.gms 2>/dev/null \
        | grep -oE 'com\.google\.android\.gms/\.update\.[A-Za-z0-9_.$]+' \
        | sort -u
    dumpsys package com.google.android.gsf 2>/dev/null \
        | grep -oE 'com\.google\.android\.gsf/\.update\.[A-Za-z0-9_.$]+' \
        | sort -u
    dumpsys package com.google.android.setupwizard 2>/dev/null \
        | grep -oE 'com\.google\.android\.setupwizard/\.update\.[A-Za-z0-9_.$]+' \
        | sort -u
}

refresh_component_cache() {
    CACHE_TMP="$COMPONENT_CACHE.$$.tmp"
    {
        printf '%s\n' "$STATIC_OTA_COMPONENTS"
        discover_ota_components
    } | sed '/^[[:space:]]*$/d' | sort -u > "$CACHE_TMP"

    if [ -s "$CACHE_TMP" ]; then
        mv -f "$CACHE_TMP" "$COMPONENT_CACHE"
        return 0
    fi

    rm -f "$CACHE_TMP"
    return 1
}

get_ota_components() {
    if [ -s "$COMPONENT_CACHE" ]; then
        cat "$COMPONENT_CACHE"
    else
        printf '%s\n' "$STATIC_OTA_COMPONENTS" | sed '/^[[:space:]]*$/d' | sort -u
    fi
}

package_fingerprint() {
    for FP_PACKAGE in $WATCHED_PACKAGES; do
        FP_PATH="$(pm path "$FP_PACKAGE" 2>/dev/null | sed -n '1p')"
        printf '%s=%s\n' "$FP_PACKAGE" "$FP_PATH"
    done
}

disable_component() {
    DC_USER="$1"
    DC_COMPONENT="$2"
    DC_OUT="$(pm disable --user "$DC_USER" "$DC_COMPONENT" 2>&1)"
    DC_RC=$?

    [ "$DC_RC" -eq 0 ] && return 0

    case "$DC_OUT" in
        *"does not exist"*|*"Unknown package"*|*"Unknown component"*|*"not installed for"*)
            return 2
            ;;
    esac

    DC_SUMMARY="$(printf '%s\n' "$DC_OUT" | sed '/^[[:space:]]*$/d' | sed -n '1p')"
    [ -z "$DC_SUMMARY" ] && DC_SUMMARY="pm disable exited with code $DC_RC"
    log_print "WARN user=$DC_USER component=$DC_COMPONENT error=[$DC_SUMMARY]"
    return 1
}

apply_ota_block() {
    OTA_USERS="$(get_users)"
    OTA_COMPONENTS="$(get_ota_components)"
    OTA_DISABLED=0
    OTA_MISSING=0
    OTA_FAILED=0
    OTA_FACTORY_REMOVED=0

    for OTA_USER in $OTA_USERS; do
        if pm list packages --user "$OTA_USER" "$FACTORY_OTA_PACKAGE" 2>/dev/null \
            | grep -qx "package:$FACTORY_OTA_PACKAGE"; then
            if pm uninstall -k --user "$OTA_USER" "$FACTORY_OTA_PACKAGE" >/dev/null 2>&1; then
                OTA_FACTORY_REMOVED=$((OTA_FACTORY_REMOVED + 1))
            else
                OTA_FAILED=$((OTA_FAILED + 1))
                log_print "WARN user=$OTA_USER package=$FACTORY_OTA_PACKAGE could not remove for user"
            fi
        fi

        for OTA_COMPONENT in $OTA_COMPONENTS; do
            disable_component "$OTA_USER" "$OTA_COMPONENT"
            OTA_RC=$?
            case "$OTA_RC" in
                0) OTA_DISABLED=$((OTA_DISABLED + 1)) ;;
                2) OTA_MISSING=$((OTA_MISSING + 1)) ;;
                *) OTA_FAILED=$((OTA_FAILED + 1)) ;;
            esac
        done
    done

    [ "$OTA_FAILED" -eq 0 ]
}

close_update_screen_if_open() {
    OTA_FOCUS="$(dumpsys window 2>/dev/null | grep -E 'mCurrentFocus|mFocusedApp')"

    case "$OTA_FOCUS" in
        *com.google.android.gms*SystemUpdateActivity*)
            am force-stop com.google.android.gms >/dev/null 2>&1
            log_print "closed foreground GMS SystemUpdateActivity"
            ;;
    esac

    case "$OTA_FOCUS" in
        *com.google.android.gsf*SystemUpdate*)
            am force-stop com.google.android.gsf >/dev/null 2>&1
            log_print "closed foreground GSF SystemUpdate activity"
            ;;
    esac
}

restore_component() {
    RC_USER="$1"
    RC_COMPONENT="$2"

    pm default-state --user "$RC_USER" "$RC_COMPONENT" >/dev/null 2>&1 \
        || cmd package default-state --user "$RC_USER" "$RC_COMPONENT" >/dev/null 2>&1
}

restore_ota_defaults() {
    refresh_component_cache >/dev/null 2>&1
    RESTORE_USERS="$(get_users)"
    RESTORE_COMPONENTS="$(get_ota_components)"

    for RESTORE_USER in $RESTORE_USERS; do
        cmd package install-existing --user "$RESTORE_USER" "$FACTORY_OTA_PACKAGE" >/dev/null 2>&1 \
            || pm install-existing --user "$RESTORE_USER" "$FACTORY_OTA_PACKAGE" >/dev/null 2>&1

        for RESTORE_COMPONENT in $RESTORE_COMPONENTS; do
            restore_component "$RESTORE_USER" "$RESTORE_COMPONENT"
        done
    done
}
