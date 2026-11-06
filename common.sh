#!/system/bin/sh
# Shell lifecycle only. Android package reads/writes live in the Java helper.
# State lives outside the module so upgrades/removal cannot erase recovery.

STATE_DIR=/data/adb/fuckotaupdate
INSTALLED_MODULE=/data/adb/modules/FuckOTAUpdate
LOGFILE="$STATE_DIR/ota.log"
OP_LOCK="$STATE_DIR/operation.flock"
SERVICE_LOCK="$STATE_DIR/service.flock"
WORKER_LOCK="$STATE_DIR/restore-worker.flock"
RESTORE_LAUNCHER=/data/adb/service.d/fuckotaupdate-restore.sh
RESTORE_LAUNCHER_MARKER='# FuckOTAUpdate-owned-restore-v1'
OP_LOCK_HELD=0
SERVICE_LOCK_HELD=0
WORKER_LOCK_HELD=0
umask 077

read_mode() {
    local mode
    if [ ! -f "$STATE_DIR/mode" ]; then
        printf '%s\n' uninitialized
        return
    fi
    IFS= read -r mode < "$STATE_DIR/mode"
    case "$mode" in
        active|paused|restoring|restored|pending-restore) printf '%s\n' "$mode" ;;
        *) printf '%s\n' error ;;
    esac
}

write_mode() {
    case "$1" in active|paused|restoring|restored|pending-restore) ;; *) return 1 ;; esac
    printf '%s\n' "$1" > "$STATE_DIR/mode.$$" \
        && mv -f "$STATE_DIR/mode.$$" "$STATE_DIR/mode"
}

setup_state() {
    mkdir -p "$STATE_DIR" || return 1
    chmod 700 "$STATE_DIR" || return 1
    if [ ! -f "$STATE_DIR/config.conf" ]; then
        # A data file, never sourced as shell. Existing configuration survives.
        printf '%s\n' \
            '# Comma-separated profile IDs; optional: setupwizard,factory-ota' \
            'ENABLED_PROFILES=gms,gsf' \
            'CHECK_INTERVAL=15' \
            'REAPPLY_INTERVAL=300' \
            'MAX_RETRY=60' > "$STATE_DIR/config.conf" || return 1
    fi
    [ -f "$STATE_DIR/mode" ] || write_mode active
}

valid_number() {
    case "$1" in ''|*[!0-9]*|??????????*) return 1 ;; esac
    # Reject leading zeroes to avoid shell arithmetic's octal interpretation.
    case "$1" in 0|[1-9]|[1-9][0-9]*) ;; *) return 1 ;; esac
    [ "$1" -ge "$2" ] && [ "$1" -le "$3" ]
}

load_config() {
    local line key value profile old_ifs
    ENABLED_PROFILES=gms,gsf
    CHECK_INTERVAL=15
    REAPPLY_INTERVAL=300
    MAX_RETRY=60
    [ -f "$STATE_DIR/config.conf" ] || return 0
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in ''|'#'*) continue ;; esac
        case "$line" in *=*) key=${line%%=*}; value=${line#*=} ;; *) return 1 ;; esac
        case "$key" in
            ENABLED_PROFILES)
                case "$value" in ''|,*|*,|*,,*|*[!a-z0-9,_-]*) return 1 ;; esac
                old_ifs=$IFS; IFS=,
                for profile in $value; do
                    case "$profile" in [a-z]*|[0-9]*) ;; *) IFS=$old_ifs; return 1 ;; esac
                done
                IFS=$old_ifs
                ENABLED_PROFILES=$value
                ;;
            CHECK_INTERVAL) valid_number "$value" 5 300 || return 1; CHECK_INTERVAL=$value ;;
            REAPPLY_INTERVAL) valid_number "$value" 30 86400 || return 1; REAPPLY_INTERVAL=$value ;;
            MAX_RETRY) valid_number "$value" 5 60 || return 1; MAX_RETRY=$value ;;
            *) return 1 ;;
        esac
    done < "$STATE_DIR/config.conf"
}

runtime_is_valid() {
    local suffix
    case "$1" in "$STATE_DIR"/runtime.*) ;; *) return 1 ;; esac
    suffix=${1#"$STATE_DIR"/runtime.}
    case "$suffix" in ''|*[!a-zA-Z0-9._-]*) return 1 ;; esac
    [ -r "$1/common.sh" ] && [ -r "$1/helper/classes.dex" ] \
        && [ -r "$1/restore-worker.sh" ] && [ -d "$1/profiles" ]
}

read_runtime() {
    RUNTIME=
    [ -f "$STATE_DIR/runtime.path" ] || return 1
    IFS= read -r RUNTIME < "$STATE_DIR/runtime.path"
    runtime_is_valid "$RUNTIME"
}

runtime_fingerprint() {
    (
        cd "$1" || exit 1
        sha256sum common.sh service.sh action.sh cli.sh restore-worker.sh \
            restore-boot.sh helper/classes.dex profiles/* 2>/dev/null
    ) | sha256sum | cut -d ' ' -f 1
}

publish_runtime() {
    local source fingerprint previous generation script
    source=$1
    for script in common.sh service.sh action.sh cli.sh restore-worker.sh restore-boot.sh helper/classes.dex; do
        [ -r "$source/$script" ] || return 1
    done
    [ -d "$source/profiles" ] || return 1
    fingerprint=$(runtime_fingerprint "$source")
    case "$fingerprint" in ''|*[!a-f0-9]*) return 1 ;; esac
    if read_runtime; then
        previous=
        [ ! -f "$RUNTIME/fingerprint" ] || IFS= read -r previous < "$RUNTIME/fingerprint"
        [ "$fingerprint" != "$previous" ] || return 0
    fi
    # A reader sees either the old complete generation or the new complete one.
    # Previous generations remain available to in-flight restoration workers.
    generation="$STATE_DIR/runtime.$fingerprint.$$"
    mkdir "$generation" || return 1
    mkdir "$generation/helper" || return 1
    for script in common.sh service.sh action.sh cli.sh restore-worker.sh restore-boot.sh; do
        cp "$source/$script" "$generation/$script" || return 1
        chmod 700 "$generation/$script" || return 1
    done
    cp "$source/helper/classes.dex" "$generation/helper/classes.dex" || return 1
    cp -R "$source/profiles" "$generation/profiles" || return 1
    [ "$(runtime_fingerprint "$generation")" = "$fingerprint" ] || return 1
    printf '%s\n' "$fingerprint" > "$generation/fingerprint" || return 1
    printf '%s\n' "$generation" > "$STATE_DIR/runtime.path.$$" \
        && mv -f "$STATE_DIR/runtime.path.$$" "$STATE_DIR/runtime.path" || return 1
    RUNTIME=$generation
}

choose_readonly_runtime() {
    read_runtime && return 0
    RUNTIME=$1
    [ -r "$RUNTIME/helper/classes.dex" ] && [ -d "$RUNTIME/profiles" ]
}

run_flock() {
    local candidate
    for candidate in /data/adb/ksu/bin/busybox /data/adb/magisk/busybox /data/adb/ap/bin/busybox; do
        if [ -x "$candidate" ]; then
            # Android mksh marks descriptors >2 close-on-exec. A self-dup on
            # the external command explicitly passes the one lock descriptor.
            case "$2" in
                9) "$candidate" flock "$@" 9>&9 ;;
                8) "$candidate" flock "$@" 8>&8 ;;
                7) "$candidate" flock "$@" 7>&7 ;;
                *) return 4 ;;
            esac
            return $?
        fi
    done
    command -v flock >/dev/null 2>&1 || return 4
    case "$2" in
        9) flock "$@" 9>&9 ;;
        8) flock "$@" 8>&8 ;;
        7) flock "$@" 7>&7 ;;
        *) return 4 ;;
    esac
}

acquire_lock() {
    local lock maximum waited descriptor
    lock=$1; maximum=$2; waited=0
    # Fixed descriptors and known paths avoid eval or arbitrary lock filenames.
    # flock is released by the kernel on exit; a leftover file is never a lock.
    case "$lock" in
        "$OP_LOCK") exec 9>"$OP_LOCK" || return 1; descriptor=9 ;;
        "$SERVICE_LOCK") exec 8>"$SERVICE_LOCK" || return 1; descriptor=8 ;;
        "$WORKER_LOCK") exec 7>"$WORKER_LOCK" || return 1; descriptor=7 ;;
        *) return 1 ;;
    esac
    while ! run_flock -n "$descriptor"; do
        if [ "$waited" -ge "$maximum" ]; then
            case "$descriptor" in 9) exec 9>&- ;; 8) exec 8>&- ;; 7) exec 7>&- ;; esac
            return 1
        fi
        sleep 1
        waited=$((waited + 1))
    done
}

release_lock() {
    case "$1" in
        "$OP_LOCK") run_flock -u 9; exec 9>&- ;;
        "$SERVICE_LOCK") run_flock -u 8; exec 8>&- ;;
        "$WORKER_LOCK") run_flock -u 7; exec 7>&- ;;
        *) return 1 ;;
    esac
}

cleanup_locks() {
    [ "$OP_LOCK_HELD" -eq 0 ] || release_lock "$OP_LOCK"
    [ "$SERVICE_LOCK_HELD" -eq 0 ] || release_lock "$SERVICE_LOCK"
    [ "$WORKER_LOCK_HELD" -eq 0 ] || release_lock "$WORKER_LOCK"
}

take_operation_lock() {
    acquire_lock "$OP_LOCK" "${1:-30}" || return 1
    OP_LOCK_HELD=1
}

drop_operation_lock() {
    [ "$OP_LOCK_HELD" -eq 0 ] || release_lock "$OP_LOCK"
    OP_LOCK_HELD=0
}

log_print() {
    local size
    # All log writers share the operation lock, including rotation.
    [ "$OP_LOCK_HELD" -eq 1 ] || return 1
    printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$LOGFILE"
    size=$(wc -c < "$LOGFILE" 2>/dev/null)
    case "$size" in ''|*[!0-9]*) return ;; esac
    if [ "$size" -gt 102400 ]; then
        tail -n 300 "$LOGFILE" > "$LOGFILE.$$.tmp" \
            && mv -f "$LOGFILE.$$.tmp" "$LOGFILE"
    fi
}

module_is_enabled() {
    [ -d "$MODULE_DIR" ] && [ ! -e "$MODULE_DIR/disable" ] && [ ! -e "$MODULE_DIR/remove" ] || return 1
    # A manually started, pending-install copy must honor manager markers in
    # the installed stub too; KernelSU keeps these directories separately.
    case "$MODULE_DIR" in
        /data/adb/modules_update/FuckOTAUpdate)
            [ ! -e "$INSTALLED_MODULE/disable" ] && [ ! -e "$INSTALLED_MODULE/remove" ]
            ;;
        *) return 0 ;;
    esac
}

framework_ready() {
    [ "$(getprop sys.boot_completed 2>/dev/null)" = 1 ] \
        && bounded_run 5 cmd package path android >/dev/null 2>&1
}

collect_users() {
    local output ids user
    output=$(bounded_run 5 pm list users 2>/dev/null) || return 1
    ids=$(printf '%s\n' "$output" | sed -n 's/.*UserInfo{\([0-9][0-9]*\):.*/\1/p')
    USERS_CSV=
    [ -n "$ids" ] || return 1
    for user in $ids; do
        case "$user" in ''|*[!0-9]*) return 1 ;; esac
        USERS_CSV=${USERS_CSV:+$USERS_CSV,}$user
    done
    [ -n "$USERS_CSV" ]
}

run_backend() {
    local backend_rc
    collect_users || { printf '%s\n' 'RESULT|error' 'ERROR|Cannot enumerate Android users'; return 4; }
    CLASSPATH="$RUNTIME/helper/classes.dex" bounded_run "${2:-120}" /system/bin/app_process /system/bin \
        dev.lokey.otablocker.Main "$1" "$STATE_DIR" "$RUNTIME/profiles" "$ENABLED_PROFILES" "$USERS_CSV" 7>&- 8>&-
    backend_rc=$?
    case "$backend_rc" in
        0|2|3|4) return "$backend_rc" ;;
        *) printf 'ERROR|Backend exited or timed out (exit=%s)\nRESULT|error\n' "$backend_rc"; return 4 ;;
    esac
}

bounded_run() {
    local seconds candidate
    seconds=$1; shift
    # Root-manager BusyBox and Android Toybox both support timeout -k.
    for candidate in /data/adb/ksu/bin/busybox /data/adb/magisk/busybox /data/adb/ap/bin/busybox; do
        if [ -x "$candidate" ]; then
            if [ "$OP_LOCK_HELD" -eq 1 ]; then
                # Keep the operation locked until even an interrupted helper
                # exits. mksh otherwise closes fd9 when executing timeout.
                "$candidate" timeout -k 3 "$seconds" "$@" 9>&9
            else
                "$candidate" timeout -k 3 "$seconds" "$@"
            fi
            return $?
        fi
    done
    if command -v timeout >/dev/null 2>&1; then
        if [ "$OP_LOCK_HELD" -eq 1 ]; then
            timeout -k 3 "$seconds" "$@" 9>&9
        else
            timeout -k 3 "$seconds" "$@"
        fi
        return $?
    fi
    printf '%s\n' 'ERROR|A bounded timeout command is required' >&2
    return 4
}

monotonic_seconds() {
    local uptime rest
    read -r uptime rest < /proc/uptime || return 1
    printf '%s\n' "${uptime%%.*}"
}

package_metadata() {
    # No package dumps, hashes or per-package Binder calls in the fast poll.
    # Nanosecond metadata where available plus inode/size catch replacements.
    stat -c '%n:%i:%s:%y:%z' /data/system/packages.xml \
        /data/system/users/userlist.xml /data/system/users/*/package-restrictions.xml \
        "$STATE_DIR/config.conf" 2>/dev/null
}

launcher_is_owned() {
    [ -f "$RESTORE_LAUNCHER" ] \
        && grep -qxF "$RESTORE_LAUNCHER_MARKER" "$RESTORE_LAUNCHER"
}

schedule_restore() {
    local temp
    write_mode pending-restore || return 1
    printf '%s\n' pending > "$STATE_DIR/restore.pending" || return 1
    mkdir -p /data/adb/service.d || return 1
    if [ -e "$RESTORE_LAUNCHER" ] && ! launcher_is_owned; then
        printf '%s\n' 'Restore launcher path is occupied by an unrelated file.' >&2
        return 1
    fi
    temp="$RESTORE_LAUNCHER.$$"
    cp "$RUNTIME/restore-boot.sh" "$temp" && chmod 700 "$temp" \
        && mv -f "$temp" "$RESTORE_LAUNCHER"
}

finish_restore_job() {
    # Called only under the lock after exact restoration has been verified.
    write_mode restored || return 1
    rm -f "$STATE_DIR/restore.pending"
    if launcher_is_owned; then
        rm -f "$RESTORE_LAUNCHER"
    fi
}
