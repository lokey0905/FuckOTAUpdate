#!/system/bin/sh
# Early-boot uninstall never waits for Android framework or the worker.
MODULE_DIR=${0%/*}
. "$MODULE_DIR/common.sh"
setup_state || exit 1
write_mode pending-restore || exit 1
publish_runtime "$MODULE_DIR" || exit 1
schedule_restore || exit 1
# service.d retries next boot if this background attempt cannot complete.
/system/bin/sh "$RUNTIME/restore-worker.sh" 7>&- 8>&- 9>&- </dev/null >/dev/null 2>&1 &
exit 0
