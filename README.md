# Claude Code Waiting — Ubuntu panel widget

A GNOME Shell widget that turns the whole top bar red (plus a count-badge
indicator) whenever **any running Claude Code instance is waiting for your
input**.

It works for any number of concurrent Claude sessions, including ones running
in bare terminals / over SSH, because the two halves communicate only through
small files on disk.

```
┌─ Claude Code session(s) ───┐  writes  ┌─ GNOME session (your desktop) ─┐
│  hooks in settings.json    │ ───────► │  GNOME Shell extension          │
│  → claude-waiting-signal.sh│  marker  │  • whole top bar turns red      │
│  writes/removes one marker │  files   │  • icon + count badge           │
│  file per session_id       │ ◄─────── │  • dropdown of waiting sessions │
└────────────────────────────┘  reads   └─────────────────────────────────┘
        ~/.local/share/claude-waiting/<session_id>.json
```

**A marker file existing == that session is waiting for you.**

## How it works

### Claude side — five hooks calling one script

| Hook                              | Fires when…                                       | Action  |
| --------------------------------- | ------------------------------------------------- | ------- |
| `Stop`                            | Claude finished its turn → it's your turn         | `wait`  |
| `Notification` (`permission_prompt`/`elicitation_dialog`) | Claude is asking permission, or an MCP server is asking for input | `wait`  |
| `UserPromptSubmit`                | You submitted a reply                             | `clear` |
| `PostToolUse`                     | A tool ran (e.g. right after you approve)         | `clear` |
| `SessionEnd`                      | That Claude instance exited                       | `clear` |

`claude-waiting-signal.sh` reads the hook JSON from stdin, pulls `session_id`
and `cwd`, and writes/removes `~/.local/share/claude-waiting/<session_id>.json`
containing `{session, cwd, message, ts, pid}`. It never fails the hook.

So you're alerted both when Claude **finishes a turn** and when it **asks
permission** mid-turn. `PostToolUse` clears the permission alert as soon as the
approved tool runs, so the icon doesn't linger while Claude keeps working.

### Widget side — the GNOME Shell extension

- Watches the marker directory with a **`Gio.FileMonitor`** (kernel inotify):
  reacts instantly, costs nothing while idle — **purely event-driven, no
  polling and no timers**. It updates only when a hook writes/removes a marker.
- Relative ages in the menu and dead-marker pruning are refreshed **when you
  open the menu** (and on every file event), so nothing runs in the background.
- When ≥1 session is waiting, the **whole top bar turns dark red** (`#c01c28`)
  and our icon shows a white **count badge**; both revert when nothing's waiting.
- Dropdown lists each waiting session (project folder + age); click to dismiss,
  or "Dismiss all".

### Self-healing

Each marker stores Claude's `pid`. If a Claude is killed without `SessionEnd`
(e.g. `kill -9`, closed terminal, reboot), the extension prunes any marker
whose pid is no longer in `/proc` (after a short grace period).

## Install

### Default: single user (Claude and your desktop are the same login)

This is the common case. One command installs **both halves** into your home —
no group setup, no permissions to think about (the watch dir is private `0700`):

```bash
./install.sh
```

Then, on **Wayland** (Ubuntu's default), **log out and back in** once so GNOME
loads the new extension. Enable it if needed:

```bash
gnome-extensions enable claude-waiting@linetra.com
```

That's it for the normal setup. The section below is only for the less-common
case where Claude and the desktop run as **different** users.

### Advanced: cross-user (Claude runs as one user, the GNOME desktop as another)

The Claude user and the desktop user are different logins. The two halves
install into different homes and agree on one watch directory (in the Claude
user's home). Access is bridged with a **shared group** — no world-readable
files are ever created.

```bash
# 1. As the CLAUDE user — install the hook half (creates a private watch dir):
./install.sh --hooks-only

# 2. As root — lock the watch dir to a shared group both users belong to:
sudo ./secure-perms.sh CLAUDE_USER DESKTOP_USER

# 3. As the DESKTOP user — install the extension half, pointed at the Claude
#    user's watch directory:
./install.sh --extension-only \
    --watch-dir /home/CLAUDE_USER/.local/share/claude-waiting

# 4. Log out / back in as the DESKTOP user (loads the extension AND applies the
#    new group membership).
```

How the bridge works (all enforced with no world bits):
- The hook writes markers `0640` (owner + group only) into the watch dir.
- `secure-perms.sh` creates a `claudewatch` group, adds both users, and sets the
  watch dir to `2770` (setgid: new markers inherit the group; no world access;
  no sticky bit, so the desktop user can delete markers). Parent directories are
  made **group**-traversable (`x`) — never world — so the desktop user can reach
  the directory but cannot list or read anything else.
- `--extension-only --watch-dir …` writes that path into
  `claude-waiting-dir.txt` inside the installed extension, so the extension
  watches the Claude user's directory instead of its own home.

Only the two named users (via the `claudewatch` group) can see or touch the
markers; no other local user can.

### Requirements

GNOME Shell 45–48 (Ubuntu 23.10+ / 24.04+), `jq` (for the settings merge and
richer hook parsing; the hook script has a no-jq fallback).

### Installer options

| Flag                 | Effect                                                        |
| -------------------- | ------------------------------------------------------------ |
| `--watch-dir PATH`   | Marker directory both halves share. Default `~/.local/share/claude-waiting`. |
| `--hooks-only`       | Install only the hook half (run as the Claude user).         |
| `--extension-only`   | Install only the extension half (run as the desktop user).   |
| `--no-settings`      | Don't touch `~/.claude/settings.json` (add hooks by hand).   |
| `--open-perms`       | Print the cross-user (shared-group) setup command.           |

## Test it

With the extension running:

```bash
# Light it up:
echo '{"session":"demo","cwd":"'"$PWD"'","message":"test","ts":'"$(date +%s)"',"pid":'"$$"'}' \
    > ~/.local/share/claude-waiting/demo.json
# Clear it:
rm ~/.local/share/claude-waiting/demo.json
```

Or just start a Claude session, let it finish a turn, and watch the panel.

## Uninstall

```bash
gnome-extensions disable claude-waiting@linetra.com
rm -rf ~/.local/share/gnome-shell/extensions/claude-waiting@linetra.com
rm -f  ~/.claude/hooks/claude-waiting-signal.sh
rm -rf ~/.local/share/claude-waiting
# then remove the three hook blocks from ~/.claude/settings.json
# (a timestamped ~/.claude/settings.json.bak* was kept by install.sh)
```

## Tuning

- **Turn-end only** (no permission alerts): drop the `Notification` and
  `PostToolUse` blocks from `settings.json` — the widget then lights up only
  when Claude finishes a turn.
- Change the marker directory in three equivalent ways for the hook: pass it as
  the 2nd argument (`… wait /path`), set `CLAUDE_WAITING_DIR`, or rely on the
  default `~/.local/share/claude-waiting`. For the extension, set it via
  `--watch-dir` (writes `claude-waiting-dir.txt`).

## Doing the Claude settings by hand

You don't have to let the installer edit `~/.claude/settings.json`. Run with
`--no-settings` (or `--hooks-only --no-settings`) and add the `hooks` block from
`settings-hooks-snippet.json` yourself. If you use a non-default watch directory,
append it as the 2nd argument to each command, e.g.
`… claude-waiting-signal.sh wait /home/CLAUDE_USER/.local/share/claude-waiting`.
Run `jq . ~/.claude/settings.json` afterward to confirm it's still valid JSON.
