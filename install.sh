#!/usr/bin/env bash
#
# Installs the "Claude Code Waiting" panel widget.
#
# DEFAULT (single user): just run  ./install.sh  and both halves install into
# your home, watching ~/.local/share/claude-waiting. No group or permission
# setup is needed.
#
# It has two halves that, in the less-common cross-user case, may live in
# DIFFERENT users' homes:
#
#   * hook half      — runs as the user who runs Claude Code.
#                      Writes marker files into the watch directory.
#   * extension half — runs as the user whose GNOME desktop you look at.
#                      Reads the watch directory.
#
# Cross-user setup (Claude user != desktop user):
#   as the Claude user :  ./install.sh --hooks-only
#   as root            :  sudo ./secure-perms.sh CLAUDE_USER DESKTOP_USER
#   as the desktop user:  ./install.sh --extension-only \
#                             --watch-dir /home/CLAUDE_USER/.local/share/claude-waiting
#
# Safe to re-run.

set -u

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UUID="claude-waiting@linetra.com"

DEFAULT_WATCH_DIR="$HOME/.local/share/claude-waiting"

# --- options ---------------------------------------------------------------
do_hooks=1
do_extension=1
do_settings=1
open_perms=0
watch_dir=""

usage() {
    cat <<EOF
Usage: ./install.sh [options]

  --watch-dir PATH    Directory the marker files live in (the shared contract
                      between the two halves). Default: $DEFAULT_WATCH_DIR
                      In a cross-user setup, point the extension half at the
                      Claude user's directory, e.g.
                      /home/CLAUDE_USER/.local/share/claude-waiting

  --hooks-only        Install just the hook half (run as the user who runs
                      Claude Code).
  --extension-only    Install just the GNOME extension half (run as the
                      desktop user).
  --no-settings       Do not touch ~/.claude/settings.json (you'll add the
                      hooks by hand). Only affects the hook half.
  --open-perms        Print the cross-user setup command. Cross-user access is
                      granted via a shared group (secure-perms.sh) so NO
                      world-readable files are created.
  -h, --help          This help.

Examples:
  Single user (default, simplest):
      ./install.sh

  Cross-user (Claude user != desktop user):
      # as the Claude user:
      ./install.sh --hooks-only
      # as root:
      sudo ./secure-perms.sh CLAUDE_USER DESKTOP_USER
      # as the desktop user:
      ./install.sh --extension-only \\
          --watch-dir /home/CLAUDE_USER/.local/share/claude-waiting
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --watch-dir)     watch_dir="${2:-}"; shift 2 ;;
        --hooks-only)    do_extension=0; shift ;;
        --extension-only) do_hooks=0; do_settings=0; shift ;;
        --no-settings)   do_settings=0; shift ;;
        --open-perms)    open_perms=1; shift ;;
        -h|--help)       usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage; exit 2 ;;
    esac
done

[ -n "$watch_dir" ] || watch_dir="$DEFAULT_WATCH_DIR"

echo "Watch directory: $watch_dir"
echo

# --- hook half -------------------------------------------------------------
if [ "$do_hooks" = 1 ]; then
    HOOK_DST_DIR="$HOME/.claude/hooks"
    HOOK_DST="$HOOK_DST_DIR/claude-waiting-signal.sh"

    echo "==> Installing hook script"
    mkdir -p "$HOOK_DST_DIR"
    cp "$SRC_DIR/hooks/claude-waiting-signal.sh" "$HOOK_DST"
    chmod +x "$HOOK_DST"
    echo "    $HOOK_DST"

    echo "==> Creating watch directory (private by default)"
    mkdir -p "$watch_dir"
    chmod 0700 "$watch_dir" 2>/dev/null || true
    echo "    $watch_dir -> $(stat -c '%A' "$watch_dir" 2>/dev/null)"

    # The hook command passes the watch dir explicitly as the 2nd argument, so
    # it is unambiguous even when Claude runs in a bare env.
    wait_cmd="\$HOME/.claude/hooks/claude-waiting-signal.sh wait $watch_dir"
    clear_cmd="\$HOME/.claude/hooks/claude-waiting-signal.sh clear $watch_dir"

    if [ "$do_settings" = 1 ]; then
        SETTINGS="$HOME/.claude/settings.json"
        echo "==> Merging hooks into $SETTINGS"
        if ! command -v jq >/dev/null 2>&1; then
            echo "    !! jq not found. Add the hooks by hand (see README)."
        else
            mkdir -p "$(dirname "$SETTINGS")"
            [ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"

            backup="$SETTINGS.bak"; i=1
            while [ -e "$backup" ]; do backup="$SETTINGS.bak.$i"; i=$((i + 1)); done
            cp "$SETTINGS" "$backup"
            echo "    backup: $backup"
            echo "    (restore with: cp \"$backup\" \"$SETTINGS\")"

            tmp="$(mktemp)"
            if jq --arg wait "$wait_cmd" --arg clear "$clear_cmd" '
                def add_hook(arr; cmd):
                    ((arr // []) | map(.hooks[]?.command)) as $cmds
                    | if ($cmds | index(cmd)) then (arr // [])
                      else ((arr // []) + [{hooks: [{type: "command", command: cmd}]}])
                      end;
                .hooks = (.hooks // {})
                | .hooks.Stop             = add_hook(.hooks.Stop;             $wait)
                | .hooks.UserPromptSubmit = add_hook(.hooks.UserPromptSubmit; $clear)
                | .hooks.SessionEnd       = add_hook(.hooks.SessionEnd;       $clear)
            ' "$SETTINGS" > "$tmp" 2>/dev/null && [ -s "$tmp" ]; then
                mv "$tmp" "$SETTINGS"
                echo "    hooks merged"
            else
                rm -f "$tmp"
                echo "    !! jq merge failed; settings unchanged. Add hooks by hand."
            fi
        fi
    else
        echo "==> Skipping settings.json (--no-settings)."
        echo "    Add these hook commands to ~/.claude/settings.json by hand:"
        echo "      Stop             -> $wait_cmd"
        echo "      UserPromptSubmit -> $clear_cmd"
        echo "      SessionEnd       -> $clear_cmd"
    fi

    if [ "$open_perms" = 1 ]; then
        echo "==> Cross-user access requested (--open-perms)"
        echo "    For a cross-user setup, grant access via a SHARED GROUP (no"
        echo "    world-readable files). Run, as root:"
        echo
        echo "      sudo ./secure-perms.sh CLAUDE_USER DESKTOP_USER \\"
        echo "          $watch_dir"
        echo
        echo "    Then have the desktop user log out / back in."
    fi
    echo
fi

# --- extension half --------------------------------------------------------
if [ "$do_extension" = 1 ]; then
    EXT_DST="$HOME/.local/share/gnome-shell/extensions/$UUID"

    echo "==> Installing GNOME Shell extension"
    mkdir -p "$EXT_DST"
    cp "$SRC_DIR/extension/$UUID/"* "$EXT_DST/"
    echo "    $EXT_DST"

    # Tell the extension which directory to watch (may be another user's home).
    printf '%s\n' "$watch_dir" > "$EXT_DST/claude-waiting-dir.txt"
    echo "    watch dir configured: $watch_dir"

    echo "==> Enabling extension"
    if command -v gnome-extensions >/dev/null 2>&1; then
        gnome-extensions enable "$UUID" 2>/dev/null \
            && echo "    enabled" \
            || echo "    (could not enable now — enable it after the relog below)"
    else
        echo "    gnome-extensions CLI not found; enable via the Extensions app."
    fi
    echo
fi

cat <<EOF
Done.

NEXT STEP (Wayland): on the DESKTOP user, log out and back in so GNOME loads
the extension, then if needed:

    gnome-extensions enable $UUID

Test it (writes a marker the desktop user should see light up):
    "$HOME/.claude/hooks/claude-waiting-signal.sh" wait "$watch_dir" <<<'{"session_id":"demo","cwd":"'"\$PWD"'"}'
    # ...icon lights up. Then clear:
    "$HOME/.claude/hooks/claude-waiting-signal.sh" clear "$watch_dir" <<<'{"session_id":"demo"}'
EOF
