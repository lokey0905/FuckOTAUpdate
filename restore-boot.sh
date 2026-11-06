#!/system/bin/sh
# FuckOTAUpdate-owned-restore-v1
# Created in service.d only during uninstall; never holds up boot.
STATE_DIR=/data/adb/fuckotaupdate
[ -f "$STATE_DIR/restore.pending" ] || exit 0
[ -r "$STATE_DIR/runtime.path" ] || exit 1
IFS= read -r RUNTIME < "$STATE_DIR/runtime.path"
case "$RUNTIME" in "$STATE_DIR"/runtime.*) ;; *) exit 1 ;; esac
SUFFIX=${RUNTIME#"$STATE_DIR"/runtime.}
case "$SUFFIX" in ''|*[!a-zA-Z0-9._-]*) exit 1 ;; esac
[ -r "$RUNTIME/restore-worker.sh" ] || exit 1
/system/bin/sh "$RUNTIME/restore-worker.sh" 7>&- 8>&- 9>&- </dev/null >/dev/null 2>&1 &
exit 0
