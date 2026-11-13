#!/bin/bash
# Compatible with the Bash 3.2 shipped by macOS. No password is read by this script.
# Engine reference: https://github.com/guoquan/mountfs
MOUNTFS_VERSION=0.3.5
GUI=1
APP_ACTION=0
EXPECTED_IDENTITY=
AUTH_SESSION_PID=
AUTH_HELPER=
AUTH_PRIVILEGED=0
HELPER_COMMIT_CONFIRMED=0
BACKEND=kernel
DRIVER=
SESSION_DIR=
LOCK_DIR=
DEVICE=
VOLUME_NAME=
MOUNT_POINT=
VOLUME_UUID=
MOUNTED=false
READ_ONLY=true
INTERNAL=true
NEW_MOUNT_POINT=
RECOVERY_NEEDED=0
DRIVER_TERMINATION_UNCONFIRMED=0
USER_ID=
GROUP_ID=

diskutil_cmd() { /usr/sbin/diskutil "$@"; }
osascript_cmd() { /usr/bin/osascript "$@"; }

message() { printf '%s\n' "$*" >&2; }
fail() { message "Error: $*"; return 1; }

plist_value() {
    /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null
}

load_volume() {
    local target="$1" policy="${2:-ntfs}" expected_identity="${3:-}" info="$SESSION_DIR/info.plist" fs whole
    diskutil_cmd info -plist "$target" > "$info" || return 1
    DEVICE=$(plist_value "$info" DeviceIdentifier) || return 1
    case "$DEVICE" in
        disk[0-9]*s[0-9]*) ;;
        *) fail "Select an NTFS partition, not an entire disk."; return 1 ;;
    esac
    [[ "$DEVICE" =~ ^disk[0-9]+s[0-9]+(s[0-9]+)?$ ]] || return 1
    if [ "$policy" = ntfs ]; then
        fs=$(plist_value "$info" FilesystemType) || return 1
        [ "$fs" = ntfs ] || { fail "Selected partition is not NTFS ($fs)."; return 1; }
    fi
    whole=$(plist_value "$info" WholeDisk) || return 1
    [ "$whole" = false ] || return 1
    INTERNAL=$(plist_value "$info" Internal) || return 1
    [ "$INTERNAL" = false ] || { fail "Internal disks are not supported in this release."; return 1; }
    VOLUME_UUID=$(volume_identity "$info" "$expected_identity") || return 1
    VOLUME_NAME=$(plist_value "$info" VolumeName) || VOLUME_NAME="$DEVICE"
    load_mount_state "$info"
}

find_driver() {
    local candidate
    for candidate in /opt/homebrew/bin/ntfs-3g /usr/local/bin/ntfs-3g; do
        if [ -x "$candidate" ] && [ ! -d "$candidate" ]; then
            DRIVER="$candidate"
            return 0
        fi
    done
    fail "ntfs-3g was not found. Install: brew install gromgit/fuse/ntfs-3g-mac"
}

check_backend() {
    local version major minor
    case "$BACKEND" in
        kernel) return 0 ;;
        fskit)
            version=$(/usr/bin/sw_vers -productVersion) || return 1
            major=${version%%.*}
            minor=${version#*.}; minor=${minor%%.*}
            if [ "$major" -lt 15 ] || { [ "$major" -eq 15 ] && [ "$minor" -lt 4 ]; }; then
                fail "FSKit requires macOS 15.4 or later."
                return 1
            fi
            ;;
        *) fail "Unknown backend: $BACKEND"; return 1 ;;
    esac
}
