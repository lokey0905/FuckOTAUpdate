#!/usr/bin/env sh
# Portable host-only lifecycle checks. No Android device or root access needed.
# Every writable fixture is below a fresh temporary directory.
set -u
REPOSITORY=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd) || exit 1
. "$REPOSITORY/common.sh"

# A separate shell must open its own descriptor to test actual contention.
if [ "${1:-}" = --lock-probe ]; then
    STATE_DIR=$2
    OP_LOCK="$STATE_DIR/operation.flock"
    SERVICE_LOCK="$STATE_DIR/service.flock"
    WORKER_LOCK="$STATE_DIR/restore-worker.flock"
    case "$3" in
        operation) PROBE_LOCK=$OP_LOCK ;;
        service) PROBE_LOCK=$SERVICE_LOCK ;;
        worker) PROBE_LOCK=$WORKER_LOCK ;;
        *) exit 1 ;;
    esac
    acquire_lock "$PROBE_LOCK" 0 || exit 1
    release_lock "$PROBE_LOCK"
    exit $?
fi

TEST_SCRIPT="$REPOSITORY/tests/lifecycle-test.sh"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fuckotaupdate-lifecycle.XXXXXX") || exit 1
STATE_DIR="$TEST_ROOT/state"
LOGFILE="$STATE_DIR/ota.log"
OP_LOCK="$STATE_DIR/operation.flock"
SERVICE_LOCK="$STATE_DIR/service.flock"
WORKER_LOCK="$STATE_DIR/restore-worker.flock"
FAILURES=0
ASSERTIONS=0
cd "$TEST_ROOT" || exit 1

cleanup_fixtures() {
    # No recursive delete: only files this harness created are removed.
    rm -f "$STATE_DIR/config.conf" "$STATE_DIR/mode" "$STATE_DIR/ota.log" "$TEST_ROOT/sentinel" \
        "$OP_LOCK" "$SERVICE_LOCK" "$WORKER_LOCK"
    rmdir "$STATE_DIR" 2>/dev/null || :
    cd "$REPOSITORY" || return
    rmdir "$TEST_ROOT" 2>/dev/null || :
}
trap cleanup_fixtures EXIT
trap 'exit 1' HUP INT TERM

check() {
    ASSERTIONS=$((ASSERTIONS + 1))
    if "$@"; then
        printf 'PASS %s\n' "$*"
    else
        printf 'FAIL %s\n' "$*"
        FAILURES=$((FAILURES + 1))
    fi
}

# Read-only inspection must not initialize persistent state.
check test "$(read_mode)" = uninitialized
check test ! -e "$STATE_DIR"
check load_config
check test "$ENABLED_PROFILES" = gms,gsf
check test ! -e "$STATE_DIR"

# Setup initializes once and preserves an explicit restoration across upgrades.
check setup_state
check test "$(read_mode)" = active
check write_mode restored
check setup_state
check test "$(read_mode)" = restored

# Numeric settings are bounded decimal data, not shell expressions/octal.
check valid_number 15 5 300
check test "$(valid_number 015 5 300; echo $?)" != 0
check test "$(valid_number '15;touch bad' 5 300; echo $?)" != 0
printf '%s\n' 'ENABLED_PROFILES=gms,oem-example' 'CHECK_INTERVAL=10' \
    'REAPPLY_INTERVAL=600' 'MAX_RETRY=60' > "$STATE_DIR/config.conf"
check load_config
check test "$ENABLED_PROFILES" = gms,oem-example
check test "$CHECK_INTERVAL" = 10

# Configuration is parsed as data; no expansion, path traversal or unknown keys.
printf '%s\n' 'ENABLED_PROFILES=gms,$(touch sentinel)' > "$STATE_DIR/config.conf"
check test "$(load_config; echo $?)" != 0
check test ! -e "$TEST_ROOT/sentinel"
printf '%s\n' 'UNKNOWN=1' > "$STATE_DIR/config.conf"
check test "$(load_config; echo $?)" != 0
printf '%s\n' 'CHECK_INTERVAL=2' > "$STATE_DIR/config.conf"
check test "$(load_config; echo $?)" != 0
printf '%s\n' 'ENABLED_PROFILES=gms,,gsf' > "$STATE_DIR/config.conf"
check test "$(load_config; echo $?)" != 0
printf '%s\n' 'ENABLED_PROFILES=gms,../escape' > "$STATE_DIR/config.conf"
check test "$(load_config; echo $?)" != 0

# All log writes and rotation require the operation-lock flag.
OP_LOCK_HELD=0
log_print ignored || :
check test ! -e "$LOGFILE"
OP_LOCK_HELD=1
check log_print recorded
check grep -q recorded "$LOGFILE"
OP_LOCK_HELD=0

# Mock only the Android command boundary, keeping actual parsing under test.
bounded_run() { shift; "$@"; }
pm() {
    printf '%s\n' 'Users:' '    UserInfo{0:Owner:13} running' '    UserInfo{10:Work:30}'
}
check collect_users
check test "$USERS_CSV" = 0,10
pm() { printf '%s\n' 'Error: package manager is starting'; }
check test "$(collect_users; echo $?)" != 0

# On Linux/Android, verify kernel locks across exec for all three descriptors.
# In particular, Android mksh requires an explicit self-dup to pass fd7/8/9.
HAS_FLOCK=0
command -v flock >/dev/null 2>&1 && HAS_FLOCK=1
for CANDIDATE in /data/adb/ksu/bin/busybox /data/adb/magisk/busybox /data/adb/ap/bin/busybox; do
    [ ! -x "$CANDIDATE" ] || HAS_FLOCK=1
done
if [ "$HAS_FLOCK" -eq 1 ]; then
    for LOCK_KIND in operation service worker; do
        case "$LOCK_KIND" in
            operation) TEST_LOCK=$OP_LOCK ;;
            service) TEST_LOCK=$SERVICE_LOCK ;;
            worker) TEST_LOCK=$WORKER_LOCK ;;
        esac
        check acquire_lock "$TEST_LOCK" 0
        # Explicitly close inherited descriptors; the child is a new contender.
        sh "$TEST_SCRIPT" --lock-probe "$STATE_DIR" "$LOCK_KIND" 7>&- 8>&- 9>&-
        PROBE_RC=$?
        check test "$PROBE_RC" -ne 0
        check release_lock "$TEST_LOCK"
        check sh "$TEST_SCRIPT" --lock-probe "$STATE_DIR" "$LOCK_KIND"
    done
else
    printf '%s\n' 'SKIP real flock contention: no flock implementation on this host'
fi

printf '%s assertions, %s failures\n' "$ASSERTIONS" "$FAILURES"
exit "$FAILURES"
