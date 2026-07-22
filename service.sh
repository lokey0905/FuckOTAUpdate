#!/system/bin/sh

MODDIR=${0%/*}
. "$MODDIR/common.sh"

CHECK_INTERVAL=${CHECK_INTERVAL:-15}
REAPPLY_INTERVAL=${REAPPLY_INTERVAL:-300}
PACKAGE_SETTLE_DELAY=${PACKAGE_SETTLE_DELAY:-5}
HEARTBEAT_INTERVAL=${HEARTBEAT_INTERVAL:-3600}
BOOT_SETTLE_DELAY=${BOOT_SETTLE_DELAY:-10}

# Wait for Android and PackageManager to be ready.
while [ "$(getprop sys.boot_completed)" != "1" ]; do
    sleep 2
done

until pm path android >/dev/null 2>&1; do
    sleep 2
done

sleep "$BOOT_SETTLE_DELAY"
refresh_component_cache
apply_ota_block
BOOT_RC=$?
close_update_screen_if_open
log_print "reason=boot users=[$OTA_USERS] disabled=$OTA_DISABLED missing=$OTA_MISSING failed=$OTA_FAILED factoryota_removed=$OTA_FACTORY_REMOVED"

LAST_FINGERPRINT="$(package_fingerprint)"
REAPPLY_ELAPSED=0
HEARTBEAT_ELAPSED=0

# Poll the package paths so a Play services replacement is caught quickly.
# The periodic pass also repairs state changes that do not replace an APK.
while true; do
    sleep "$CHECK_INTERVAL"
    CURRENT_FINGERPRINT="$(package_fingerprint)"
    REASON=""

    if [ "$CURRENT_FINGERPRINT" != "$LAST_FINGERPRINT" ]; then
        sleep "$PACKAGE_SETTLE_DELAY"
        refresh_component_cache
        CURRENT_FINGERPRINT="$(package_fingerprint)"
        REASON="package-replaced"
    else
        REAPPLY_ELAPSED=$((REAPPLY_ELAPSED + CHECK_INTERVAL))
        HEARTBEAT_ELAPSED=$((HEARTBEAT_ELAPSED + CHECK_INTERVAL))
        if [ "$REAPPLY_ELAPSED" -ge "$REAPPLY_INTERVAL" ]; then
            REASON="periodic"
        fi
    fi

    [ -z "$REASON" ] && continue

    apply_ota_block
    APPLY_RC=$?
    close_update_screen_if_open
    REAPPLY_ELAPSED=0
    LAST_FINGERPRINT="$CURRENT_FINGERPRINT"

    if [ "$REASON" = "package-replaced" ] \
        || [ "$APPLY_RC" -ne 0 ] \
        || [ "$HEARTBEAT_ELAPSED" -ge "$HEARTBEAT_INTERVAL" ]; then
        log_print "reason=$REASON users=[$OTA_USERS] disabled=$OTA_DISABLED missing=$OTA_MISSING failed=$OTA_FAILED factoryota_removed=$OTA_FACTORY_REMOVED"
        HEARTBEAT_ELAPSED=0
    fi
done
