#!/usr/bin/env bash
#
# secure-perms.sh — lock the cross-user watch directory to a shared group so
# ONLY the Claude user and the desktop user can read/delete markers. No world
# (other) read or write bits are left anywhere.
#
# Run with sudo:
#   sudo ./secure-perms.sh CLAUDE_USER DESKTOP_USER [WATCH_DIR] [GROUP]
#
# Example:
#   sudo ./secure-perms.sh "$CLAUDE_USER" "$DESKTOP_USER"
#
# Idempotent. After running, the DESKTOP user must log out / back in so its
# GNOME session picks up the new group membership.

set -u

if [ "$(id -u)" -ne 0 ]; then
    echo "Please run with sudo (need to create a group and change ownership)." >&2
    exit 1
fi

CLAUDE_USER="${1:-}"
DESKTOP_USER="${2:-}"
if [ -z "$CLAUDE_USER" ] || [ -z "$DESKTOP_USER" ]; then
    echo "Usage: sudo ./secure-perms.sh CLAUDE_USER DESKTOP_USER [WATCH_DIR] [GROUP]" >&2
    exit 2
fi

CLAUDE_HOME="$(getent passwd "$CLAUDE_USER" | cut -d: -f6)"
[ -n "$CLAUDE_HOME" ] || { echo "Unknown user: $CLAUDE_USER" >&2; exit 2; }

WATCH_DIR="${3:-$CLAUDE_HOME/.local/share/claude-waiting}"
GROUP="${4:-claudewatch}"

echo "Claude user : $CLAUDE_USER ($CLAUDE_HOME)"
echo "Desktop user: $DESKTOP_USER"
echo "Watch dir   : $WATCH_DIR"
echo "Group       : $GROUP"
echo

echo "==> Ensuring group '$GROUP' exists and both users are members"
groupadd -f "$GROUP"
usermod -aG "$GROUP" "$CLAUDE_USER"
usermod -aG "$GROUP" "$DESKTOP_USER"

echo "==> Locking the watch directory (setgid, group rwx, no world bits)"
mkdir -p "$WATCH_DIR"
chown "$CLAUDE_USER":"$GROUP" "$WATCH_DIR"
# 2770 = rwxrws--- : owner+group full access, setgid so new markers inherit the
# group, no world bits. No sticky bit, so the desktop user can delete markers.
chmod 2770 "$WATCH_DIR"

echo "==> Tightening any existing markers to owner+group only (0640)"
find "$WATCH_DIR" -maxdepth 1 -type f -name '*.json' -exec chgrp "$GROUP" {} + 2>/dev/null
find "$WATCH_DIR" -maxdepth 1 -type f -name '*.json' -exec chmod 0640 {} + 2>/dev/null

echo "==> Making intermediate dirs group-traversable, removing world bits"
# Every directory between the watch dir and the Claude user's home needs the
# desktop user to be able to traverse (x) it -- but NOT read/list it. We grant
# that via the shared group and strip the world (other) bits that an earlier
# --open-perms run may have set.
d="$(dirname "$WATCH_DIR")"
while [ "$d" != "$CLAUDE_HOME" ] && [ "$d" != "/" ] && [ -n "$d" ]; do
    chgrp "$GROUP" "$d" 2>/dev/null || true
    chmod g+x,o-rwx "$d" 2>/dev/null || true
    echo "    $d -> $(stat -c '%A %U:%G' "$d" 2>/dev/null)"
    d="$(dirname "$d")"
done

echo "==> Ensuring the home directory is traversable (execute only, not readable)"
# A home dir needs the x bit for the desktop user to descend into it. We grant
# it to the shared group rather than the world. (Ubuntu's default is already
# 0711; this removes even that world-execute bit in favour of group-execute.)
chgrp "$GROUP" "$CLAUDE_HOME" 2>/dev/null || true
chmod g+x,o-rwx "$CLAUDE_HOME" 2>/dev/null || true
echo "    $CLAUDE_HOME -> $(stat -c '%A %U:%G' "$CLAUDE_HOME" 2>/dev/null)"

echo
echo "Done. Summary:"
echo "    $WATCH_DIR -> $(stat -c '%A %U:%G' "$WATCH_DIR")"
echo
echo "NEXT: have the desktop user LOG OUT and back in so its GNOME session joins"
echo "the '$GROUP' group. Until then the extension cannot read the markers."
echo
echo "Verify afterwards (as the desktop user):  id -nG | tr ' ' '\\n' | grep $GROUP"
