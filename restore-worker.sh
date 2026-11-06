#!/system/bin/sh
# Persistent recovery worker, safe after the module directory is deleted.
RUNTIME=${0%/*}
. "$RUNTIME/common.sh"
[ -f "$STATE_DIR/restore.pending" ] || exit 0
acquire_lock "$WORKER_LOCK" 5 || exit 0
WORKER_LOCK_HELD=1
trap cleanup_locks EXIT
trap 'exit 4' HUP INT TERM

DEADLINE=$(( $(monotonic_seconds) + 300 ))
while [ "$(monotonic_seconds)" -lt "$DEADLINE" ]; do
    [ -f "$STATE_DIR/restore.pending" ] || exit 0
    if framework_ready; then
        if take_operation_lock 5; then
            [ -f "$STATE_DIR/restore.pending" ] || exit 0
            write_mode pending-restore || exit 4
            # Restore uses the journal, not current target profile choices.
            ENABLED_PROFILES=gms,gsf
            REMAINING=$((DEADLINE - $(monotonic_seconds) - 8))
            [ "$REMAINING" -gt 0 ] || exit 4
            [ "$REMAINING" -le 120 ] || REMAINING=120
            BACKEND_OUTPUT=$(run_backend restore "$REMAINING" 2>&1)
            BACKEND_RC=$?
            log_print "uninstall-restore exit=$BACKEND_RC $BACKEND_OUTPUT"
            if [ "$BACKEND_RC" -eq 0 ]; then
                finish_restore_job || exit 4
                exit 0
            fi
            drop_operation_lock
        fi
    fi
    sleep 5
done
# Preserve journal and owned launcher for a next-boot retry.
exit 4
