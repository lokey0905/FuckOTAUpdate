#!/system/bin/sh
# Root manager installer: no Android framework calls here.
. "$MODPATH/common.sh"
ui_print '- Preparing persistent OTA recovery state'
setup_state || abort '! Cannot prepare /data/adb/fuckotaupdate'
publish_runtime "$MODPATH" || abort '! Cannot prepare complete persistent runtime'
for SCRIPT in common.sh service.sh action.sh cli.sh uninstall.sh restore-worker.sh restore-boot.sh; do
    set_perm "$MODPATH/$SCRIPT" 0 0 0755
done
ui_print '- Default profiles: gms,gsf; existing configuration and journal retained'
ui_print '- Status: sh /data/adb/modules/FuckOTAUpdate/cli.sh status'
