#!/usr/bin/env bash
#
# claude-waiting-signal.sh
#
# Reads a Claude Code hook event (JSON on stdin) and updates a per-session
# "waiting for input" marker file that the GNOME panel extension watches.
#
#   wait  -> Claude finished its turn / needs you -> create the marker
#   clear -> you replied, or the session ended     -> remove the marker
#
# Optional 2nd argument, or $CLAUDE_WAITING_DIR, sets the marker directory.
# This matters in cross-user setups (Claude runs as one user, the GNOME desktop
# as another): both halves must agree on one directory that the desktop user
# can read. Default is the running user's own ~/.local/share/claude-waiting.
#
# The marker directory is the shared contract between Claude (any number of
# concurrent sessions, possibly in bare ttys) and the GNOME Shell extension
# running inside your desktop session. File present == that session is waiting.
#
# Designed to never fail the hook: it always exits 0.

action="${1:-wait}"
dir_arg="${2:-}"
state_dir="${dir_arg:-${CLAUDE_WAITING_DIR:-$HOME/.local/share/claude-waiting}}"

mkdir -p "$state_dir" 2>/dev/null || true

# Never create world-readable markers. With a setgid shared-group watch dir,
# new markers inherit the group, and 0640 keeps them readable by that group
# (the desktop user) but not by the world.
umask 027

# Slurp the hook JSON from stdin.
input="$(cat 2>/dev/null || true)"

# Extract a string field, preferring jq, falling back to a crude grep so the
# script still works on a box without jq installed.
field() {
  local key="$1"
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$input" | jq -r --arg k "$key" '.[$k] // empty' 2>/dev/null || true
  else
    printf '%s' "$input" \
      | grep -o "\"$key\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" 2>/dev/null \
      | head -1 \
      | sed 's/.*:[[:space:]]*"\(.*\)"/\1/' 2>/dev/null || true
  fi
}

# Find the long-lived Claude process by walking up the parent chain, so the
# marker's liveness pid survives the hook run. $PPID is only the throwaway shell
# Claude spawns to run the hook -- it exits immediately, which would make the
# panel extension prune the marker a few seconds later. We instead store the pid
# of the ancestor whose comm is "claude" (or "node" for node-based installs).
# Returns 0 if not found, which the extension treats as "unknown -> never prune".
find_claude_pid() {
  local pid="$PPID" guard=0 comm
  while [ -n "$pid" ] && [ "$pid" -gt 1 ] && [ "$guard" -lt 30 ]; do
    comm="$(cat "/proc/$pid/comm" 2>/dev/null)"
    if [ "$comm" = "claude" ] || [ "$comm" = "node" ]; then
      printf '%s' "$pid"
      return 0
    fi
    pid="$(awk '{print $4}' "/proc/$pid/stat" 2>/dev/null)"
    guard=$((guard + 1))
  done
  printf '0'
}

session_id="$(field session_id)"
[ -n "$session_id" ] || session_id="unknown-$$"

# Make the session id safe to use as a filename.
safe_id="$(printf '%s' "$session_id" | tr -c 'A-Za-z0-9_.-' '_')"
marker="$state_dir/$safe_id.json"

case "$action" in
  clear)
    rm -f "$marker" 2>/dev/null || true
    ;;

  wait)
    cwd="$(field cwd)"
    [ -n "$cwd" ] || cwd="$PWD"

    message="$(field message)"
    [ -n "$message" ] || message="Waiting for your input"

    ts="$(date +%s 2>/dev/null || echo 0)"

    # Liveness pid = the long-lived Claude process (see find_claude_pid). The
    # extension prunes the marker only if this pid later disappears (covers a
    # Claude killed without SessionEnd).
    owner_pid="$(find_claude_pid)"

    if command -v jq >/dev/null 2>&1; then
      jq -n \
        --arg session "$session_id" \
        --arg cwd "$cwd" \
        --arg message "$message" \
        --argjson ts "${ts:-0}" \
        --argjson pid "${owner_pid:-0}" \
        '{session:$session, cwd:$cwd, message:$message, ts:$ts, pid:$pid}' \
        > "$marker" 2>/dev/null || true
    else
      # Minimal manual JSON. Escape backslashes and double quotes in strings.
      esc() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
      printf '{"session":"%s","cwd":"%s","message":"%s","ts":%s,"pid":%s}\n' \
        "$(esc "$session_id")" "$(esc "$cwd")" "$(esc "$message")" \
        "${ts:-0}" "${owner_pid:-0}" \
        > "$marker" 2>/dev/null || true
    fi
    # Belt and suspenders: enforce owner+group only, regardless of umask.
    chmod 0640 "$marker" 2>/dev/null || true
    ;;

  *)
    echo "claude-waiting-signal.sh: unknown action '$action'" >&2
    ;;
esac

exit 0
