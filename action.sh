#!/system/bin/sh
# Root manager Action never resumes a paused or restored mode.
MODULE_DIR=${0%/*}
echo 'Fuck OTA Update v1.2'
APPLY_OUTPUT=$(/system/bin/sh "$MODULE_DIR/cli.sh" apply 2>&1)
APPLY_RC=$?
printf '%s\n' "$APPLY_OUTPUT" | sed -n '/^MODE|/p; /^COUNTS|/p; /^RESULT|/p; /^ERROR|/p'
if [ "$APPLY_RC" -ne 0 ]; then
    printf '%s\n' "$APPLY_OUTPUT" | sed -n '/^DIAG|/p' | head -n 5
fi
echo 'Current verification:'
STATUS_OUTPUT=$(/system/bin/sh "$MODULE_DIR/cli.sh" status 2>&1)
STATUS_RC=$?
printf '%s\n' "$STATUS_OUTPUT" | sed -n '/^MODE|/p; /^COUNTS|/p; /^RESULT|/p; /^ERROR|/p'
echo 'Log: /data/adb/fuckotaupdate/ota.log'
[ "$APPLY_RC" -ne 0 ] || APPLY_RC=$STATUS_RC
exit "$APPLY_RC"
