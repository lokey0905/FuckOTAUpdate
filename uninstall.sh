#!/system/bin/sh

MODDIR=${0%/*}
. "$MODDIR/common.sh"

while [ "$(getprop sys.boot_completed)" != "1" ]; do
    sleep 2
done

until pm path android >/dev/null 2>&1; do
    sleep 2
done

sleep 5
restore_ota_defaults
