#!/system/bin/sh
# status/diagnose perform no filesystem or package writes.
SOURCE_DIR=${0%/*}
. "$SOURCE_DIR/common.sh"
MODULE_DIR=$SOURCE_DIR
case "$SOURCE_DIR" in "$STATE_DIR"/runtime.*) MODULE_DIR=$INSTALLED_MODULE ;; esac
COMMAND=${1:-help}

case "$COMMAND" in
    help|-h|--help)
        printf '%s\n' \
            'Usage: sh cli.sh status|diagnose|apply|restore|resume|help' \
            'status/diagnose: read-only verification/inventory; no initialization' \
            'apply: rescan and repair only while mode is active' \
            'restore: pause blocking, then restore journaled original states' \
            'resume: explicitly activate blocking and apply now' \
            "Configuration: $STATE_DIR/config.conf" \
            "Log: $LOGFILE"
        exit 0
        ;;
    status|diagnose)
        printf 'MODE|%s\n' "$(read_mode)"
        if ! load_config; then
            echo 'RESULT|error'; echo 'ERROR|Invalid configuration'; exit 4
        fi
        choose_readonly_runtime "$SOURCE_DIR" || { echo 'RESULT|error'; echo 'ERROR|Missing runtime'; exit 4; }
        framework_ready || { echo 'RESULT|error'; echo 'ERROR|Android framework not ready'; exit 4; }
        if [ "$COMMAND" = diagnose ]; then
            run_backend inventory
        else
            run_backend status
        fi
        exit $?
        ;;
    apply|restore|resume) ;;
    *) echo "Unknown command: $COMMAND" >&2; exit 4 ;;
esac

setup_state || exit 4
if [ "$SOURCE_DIR" = "$MODULE_DIR" ]; then
    # Content hashing also recognizes same-version development rebuilds.
    publish_runtime "$MODULE_DIR" || { [ "$COMMAND" = restore ] && read_runtime; } || exit 4
else
    read_runtime || exit 4
fi
trap cleanup_locks EXIT
trap 'exit 4' HUP INT TERM

if [ "$COMMAND" = restore ]; then
    # Gate set before waiting for any active apply to finish.
    write_mode restoring || exit 4
    # Bad profile configuration must never prevent journal recovery.
    ENABLED_PROFILES=gms,gsf
elif ! load_config; then
    echo 'RESULT|error'; echo 'ERROR|Invalid configuration'; exit 4
elif ! module_is_enabled; then
    echo 'RESULT|error'; echo 'ERROR|Module is disabled, removed or unavailable'; exit 4
elif [ "$COMMAND" = apply ] && [ "$(read_mode)" != active ]; then
    printf 'MODE|%s\n' "$(read_mode)"
    echo 'RESULT|error'; echo 'ERROR|Not active; use resume explicitly'; exit 4
fi

take_operation_lock 30 || { echo 'RESULT|error'; echo 'ERROR|Operation is busy; mode retained'; exit 4; }
if [ "$COMMAND" = resume ]; then
    if [ -f "$STATE_DIR/restore.pending" ]; then
        echo 'RESULT|error'; echo 'ERROR|Uninstall restoration pending; run restore first'; exit 4
    fi
    write_mode active || exit 4
    # Start retries even if the immediate framework/backend check fails.
    # The daemon observes the operation lock held by this CLI invocation.
    /system/bin/sh "$MODULE_DIR/service.sh" >/dev/null 2>&1
elif [ "$COMMAND" = apply ] && [ "$(read_mode)" != active ]; then
    echo 'RESULT|error'; echo 'ERROR|Mode changed; blocking skipped'; exit 4
fi
framework_ready || { echo 'RESULT|error'; echo 'ERROR|Android framework not ready; mode retained'; exit 4; }
BACKEND_COMMAND=apply
[ "$COMMAND" != restore ] || BACKEND_COMMAND=restore
BACKEND_OUTPUT=$(run_backend "$BACKEND_COMMAND" 2>&1)
BACKEND_RC=$?
printf '%s\n' "$BACKEND_OUTPUT"
log_print "manual command=$COMMAND exit=$BACKEND_RC $BACKEND_OUTPUT"
if [ "$COMMAND" = restore ] && [ "$BACKEND_RC" -eq 0 ]; then
    finish_restore_job || exit 4
fi
drop_operation_lock
exit "$BACKEND_RC"
