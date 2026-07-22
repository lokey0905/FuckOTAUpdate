#!/system/bin/sh

while [ "$(getprop sys.boot_completed)" != "1" ]; do
    sleep 2
done

sleep 10

get_users() {
    USERS="$(pm list users 2>/dev/null | sed -n 's/.*UserInfo{\([0-9][0-9]*\):.*/\1/p')"
    [ -z "$USERS" ] && USERS="0"
    echo "$USERS"
}

restore_component() {
    USER_ID="$1"
    COMPONENT="$2"

    # Prefer default state instead of forced enable.
    pm default-state --user "$USER_ID" "$COMPONENT" >/dev/null 2>&1 \
        || cmd package set-enabled-setting "$COMPONENT" default --user "$USER_ID" >/dev/null 2>&1 \
        || pm enable --user "$USER_ID" "$COMPONENT" >/dev/null 2>&1
}

restore_user() {
    USER_ID="$1"

    cmd package install-existing --user "$USER_ID" com.google.android.factoryota >/dev/null 2>&1

    restore_component "$USER_ID" "com.google.android.gms/.update.SystemUpdateActivity"
    restore_component "$USER_ID" "com.google.android.gms/.update.SystemUpdateService"
    restore_component "$USER_ID" "com.google.android.gms/.update.SystemUpdateService\$ActiveReceiver"
    restore_component "$USER_ID" "com.google.android.gms/.update.SystemUpdateService\$Receiver"
    restore_component "$USER_ID" "com.google.android.gms/.update.SystemUpdateService\$SecretCodeReceiver"

    restore_component "$USER_ID" "com.google.android.gsf/.update.SystemUpdateActivity"
    restore_component "$USER_ID" "com.google.android.gsf/.update.SystemUpdatePanoActivity"
    restore_component "$USER_ID" "com.google.android.gsf/.update.SystemUpdateService"
    restore_component "$USER_ID" "com.google.android.gsf/.update.SystemUpdateService\$Receiver"
    restore_component "$USER_ID" "com.google.android.gsf/.update.SystemUpdateService\$SecretCodeReceiver"
}

for USER_ID in $(get_users); do
    restore_user "$USER_ID"
done
