#!/system/bin/sh

MODDIR=${0%/*}
. "$MODDIR/common.sh"

echo "Fuck OTA Update: refreshing component list..."
refresh_component_cache

if apply_ota_block; then
    RESULT="OK"
else
    RESULT="ERROR"
fi

close_update_screen_if_open
log_print "reason=manual-action users=[$OTA_USERS] disabled=$OTA_DISABLED missing=$OTA_MISSING failed=$OTA_FAILED factoryota_removed=$OTA_FACTORY_REMOVED"

echo "Result: $RESULT"
echo "Users: $OTA_USERS"
echo "Disabled existing components: $OTA_DISABLED"
echo "Unavailable/legacy targets skipped: $OTA_MISSING"
echo "Failures: $OTA_FAILED"
echo "Factory OTA packages removed now: $OTA_FACTORY_REMOVED"
echo "Log: $LOGFILE"

[ "$OTA_FAILED" -eq 0 ]
