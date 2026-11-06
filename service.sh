#!/system/bin/sh
# late_start hook returns immediately; readiness waits run in the daemon.
MODULE_DIR=${2:-${0%/*}}
. "${0%/*}/common.sh"

if [ "${1:-}" != --daemon ]; then
    /system/bin/sh "$MODULE_DIR/service.sh" --daemon "$MODULE_DIR" \
        7>&- 8>&- 9>&- </dev/null >/dev/null 2>&1 &
    exit 0
fi

setup_state || exit 1
publish_runtime "$MODULE_DIR" || exit 1
acquire_lock "$SERVICE_LOCK" 5 || exit 0
SERVICE_LOCK_HELD=1
trap cleanup_locks EXIT
trap 'exit 0' HUP INT TERM

LAST_METADATA=
SINCE_PASS=0
RETRY_WAIT=5
NEXT_DELAY=0
NEED_PASS=1

while module_is_enabled; do
    [ "$(read_mode)" = active ] || exit 0
    if [ "$NEXT_DELAY" -gt 0 ]; then
        sleep "$NEXT_DELAY"
        SINCE_PASS=$((SINCE_PASS + NEXT_DELAY))
    fi
    module_is_enabled && [ "$(read_mode)" = active ] || exit 0
    if ! load_config; then
        # Invalid data must not silently broaden the target set.
        NEXT_DELAY=60
        continue
    fi
    CURRENT_METADATA=$(package_metadata)
    if [ "$CURRENT_METADATA" != "$LAST_METADATA" ] || [ "$SINCE_PASS" -ge "$REAPPLY_INTERVAL" ]; then
        NEED_PASS=1
    fi
    if [ "$NEED_PASS" -eq 1 ]; then
        if ! framework_ready; then
            NEXT_DELAY=$RETRY_WAIT
            RETRY_WAIT=$((RETRY_WAIT * 2))
            [ "$RETRY_WAIT" -le "$MAX_RETRY" ] || RETRY_WAIT=$MAX_RETRY
            continue
        fi
        if ! take_operation_lock 5; then
            NEXT_DELAY=5
            continue
        fi
        if ! module_is_enabled || [ "$(read_mode)" != active ]; then
            drop_operation_lock
            exit 0
        fi
        if ! read_runtime; then
            log_print 'service exit=4 missing persistent runtime'
            drop_operation_lock
            NEXT_DELAY=$MAX_RETRY
            continue
        fi
        BACKEND_OUTPUT=$(run_backend apply 2>&1)
        BACKEND_RC=$?
        log_print "service exit=$BACKEND_RC $BACKEND_OUTPUT"
        if [ "$BACKEND_RC" -eq 0 ]; then
            # Acknowledge only the metadata observed before this pass. Changes
            # during inventory (including new users/config) need a follow-up.
            # Our own writes may cause one harmless, difference-only extra pass.
            LAST_METADATA=$CURRENT_METADATA
            SINCE_PASS=0
            NEED_PASS=0
            RETRY_WAIT=5
            NEXT_DELAY=$CHECK_INTERVAL
        else
            NEED_PASS=1
            NEXT_DELAY=$RETRY_WAIT
            RETRY_WAIT=$((RETRY_WAIT * 2))
            [ "$RETRY_WAIT" -le "$MAX_RETRY" ] || RETRY_WAIT=$MAX_RETRY
        fi
        drop_operation_lock
    else
        NEXT_DELAY=$CHECK_INTERVAL
    fi
done
