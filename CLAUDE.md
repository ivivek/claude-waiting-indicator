# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A GNOME Shell widget that turns the top bar red whenever any running Claude Code
session is waiting for user input. There is **no build system, package manager,
or test framework** — it's shell + a GJS extension + JSON.

## Architecture

Two halves that **never talk directly** — they communicate only through marker
files on disk. Understanding this contract is the key to the whole project:

1. **Producer** — `hooks/claude-waiting-signal.sh`, invoked by Claude Code hooks
   configured in `~/.claude/settings.json`. Runs as the Claude user. Writes or
   removes one marker file per session.
2. **Consumer** — `extension/claude-waiting@linetra.com/extension.js`, a GNOME
   Shell extension running in the desktop user's session. Watches the marker
   directory and drives the panel.

**The marker directory is the entire interface.** Each marker is
`<watch-dir>/<session_id>.json` containing `{session, cwd, message, ts, pid}`.
**A marker existing ⇔ that session is waiting.** Default watch dir is
`~/.local/share/claude-waiting`.

Files (not D-Bus/sockets) are used deliberately: it supports cross-user setups
(Claude and the desktop running as *different* logins, with separate session
buses) and Claude sessions in bare ttys/over SSH. `inotify` makes it instant.

### Hook → action mapping

Configured by `install.sh`'s `jq` merge (and `settings-hooks-snippet.json`):

- **write marker (`wait`)**: `Stop` (turn ended), `Notification` with matcher
  `permission_prompt|elicitation_dialog` (permission / MCP prompt).
- **remove marker (`clear`)**: `UserPromptSubmit` (you replied), `PostToolUse`
  (clears a permission alert once the approved tool runs), `SessionEnd`.

### Liveness pid — the subtle part

The marker's `pid` lets the extension prune markers from crashed sessions. It
must be the **long-lived `claude` process**, NOT `$PPID` — `$PPID` is the
throwaway shell Claude spawns to run the hook, which exits immediately and would
cause the extension to prune the marker a few seconds later. `find_claude_pid()`
walks the parent chain to the `claude`/`node` ancestor; it returns `0`
("unknown → never prune") if not found. Manual test markers written with
`"pid":1` are treated as always-alive and never auto-prune.

### Extension specifics

- **Purely event-driven**: `Gio.FileMonitor` (inotify), debounced. No timers, no
  polling. It updates only on a marker change or when its menu opens.
- **Red bar** = the `claude-panel-alert` style class toggled on `Main.panel`,
  active only while an *unacknowledged* session is waiting.
- **Click to acknowledge**: opening the indicator menu marks current waiters as
  acknowledged (red resets, count badge stays) and triggers a re-scan
  (age refresh + dead-pid prune). A *new* waiting session re-triggers red.
- Icon/badge are styled red on the normal bar and white while the bar is red
  (a `#panel.claude-panel-alert ...` descendant rule in `stylesheet.css`).

### Install model

- **Single user (default)**: `./install.sh` installs both halves into one home;
  watch dir is private `0700`.
- **Cross-user**: `./install.sh --hooks-only` (Claude user), then
  `sudo ./secure-perms.sh CLAUDE_USER DESKTOP_USER` (creates a `claudewatch`
  group, sets the watch dir `2770` setgid with **no world bits**), then
  `./install.sh --extension-only --watch-dir <claude-user-dir>` (desktop user).
  The extension reads its watch dir from `claude-waiting-dir.txt` written into
  the installed extension directory; it falls back to `~/.local/share/...`.

The settings merge is idempotent and backs up `settings.json` before editing.

## GNOME / development constraints

- The extension is **ESM** (GNOME Shell 45–48). `metadata.json` `shell-version`
  must include the target versions.
- **Wayland has no hot reload.** After editing `extension.js` / `stylesheet.css`
  / `metadata.json`, copy them into
  `~/.local/share/gnome-shell/extensions/claude-waiting@linetra.com/` and **log
  out / back in**. `gnome-extensions disable && enable` does NOT pick up changed
  code or CSS on Wayland.
- Changing the extension **UUID** makes it a brand-new extension to GNOME (needs
  a relogin to be discovered). The UUID is the directory name under `extension/`.
- Cross-user group changes (`secure-perms.sh`) only take effect in a session
  after a full **logout/reboot**.

## Commands

There are no automated tests. These are the checks and dev loops:

```bash
# Syntax checks (what to run before committing):
bash -n hooks/claude-waiting-signal.sh install.sh secure-perms.sh
cp extension/claude-waiting@linetra.com/extension.js /tmp/x.mjs && node --check /tmp/x.mjs
jq . extension/claude-waiting@linetra.com/metadata.json settings-hooks-snippet.json

# Install (single user), then log out / back in once:
./install.sh

# Exercise the full pipeline with no Claude session (panel reacts instantly):
H=hooks/claude-waiting-signal.sh; D=~/.local/share/claude-waiting
echo '{"session_id":"demo","cwd":"'"$PWD"'","message":"test"}' | "$H" wait "$D"
echo '{"session_id":"demo"}' | "$H" clear "$D"
# For a marker that won't auto-prune while you watch it, write {"pid":1} by hand.

# Deploy an extension change to a running desktop, then log out / back in:
cp extension/claude-waiting@linetra.com/{extension.js,stylesheet.css} \
   ~/.local/share/gnome-shell/extensions/claude-waiting@linetra.com/

# Diagnose the extension:
gnome-extensions info claude-waiting@linetra.com | grep -E 'Enabled|State'  # want State: ACTIVE
journalctl --user -b -o cat | grep -i claude-waiting                        # JS errors
```

When changing which hooks fire or the marker schema, keep these in sync:
`hooks/claude-waiting-signal.sh`, the `jq` merge in `install.sh`,
`settings-hooks-snippet.json`, and the reader in `extension.js` (`_refresh`).
