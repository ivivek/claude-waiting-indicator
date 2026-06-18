'use strict';

import GObject from 'gi://GObject';
import St from 'gi://St';
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import Clutter from 'gi://Clutter';

import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import * as PanelMenu from 'resource:///org/gnome/shell/ui/panelMenu.js';
import * as PopupMenu from 'resource:///org/gnome/shell/ui/popupMenu.js';

// Directory both halves agree on: hooks write here, the extension watches here.
const STATE_SUBDIR = ['.local', 'share', 'claude-waiting'];

// Periodic re-scan interval (only runs while >=1 marker exists). Refreshes the
// "Nm ago" ages in the menu and prunes markers whose Claude pid has died.
const TIMER_SECONDS = 15;

// Debounce window for bursts of FileMonitor events.
const DEBOUNCE_MS = 200;

// Don't prune a dead-pid marker until it's at least this old, to avoid a race
// where the marker is written before/around the pid check.
const PRUNE_GRACE_SECONDS = 5;

const ClaudeIndicator = GObject.registerClass(
class ClaudeIndicator extends PanelMenu.Button {
    _init(stateDir) {
        super._init(0.0, 'Claude Code Waiting');

        this._stateDir = stateDir;
        this._waiting = new Map();   // sessionId -> {cwd, message, ts, pid, _path}
        this._known = new Set();     // sessionIds already notified (to fire once)
        this._monitor = null;
        this._timerId = 0;
        this._debounceId = 0;

        // --- panel button: icon + count badge ---
        const box = new St.BoxLayout({style_class: 'panel-status-menu-box'});
        this._icon = new St.Icon({
            icon_name: 'mail-read-symbolic',
            style_class: 'system-status-icon claude-waiting-icon',
        });
        this._countLabel = new St.Label({
            text: '',
            y_align: Clutter.ActorAlign.CENTER,
            style_class: 'claude-waiting-count',
            visible: false,
        });
        box.add_child(this._icon);
        box.add_child(this._countLabel);
        this.add_child(box);

        // --- dropdown menu ---
        this._headerItem = new PopupMenu.PopupMenuItem('', {reactive: false});
        this.menu.addMenuItem(this._headerItem);
        this.menu.addMenuItem(new PopupMenu.PopupSeparatorMenuItem());

        this._sessionSection = new PopupMenu.PopupMenuSection();
        this.menu.addMenuItem(this._sessionSection);

        this._dismissAllSep = new PopupMenu.PopupSeparatorMenuItem();
        this.menu.addMenuItem(this._dismissAllSep);
        this._dismissAllItem = new PopupMenu.PopupMenuItem('Dismiss all');
        this._dismissAllItem.connect('activate', () => this._dismissAll());
        this.menu.addMenuItem(this._dismissAllItem);
    }

    start() {
        const dir = Gio.File.new_for_path(this._stateDir);
        try {
            dir.make_directory_with_parents(null);
        } catch (_e) {
            // already exists -> fine
        }

        // Event-driven watch (kernel inotify). Costs nothing while idle.
        this._monitor = dir.monitor_directory(Gio.FileMonitorFlags.NONE, null);
        this._monitor.connect('changed', () => this._scheduleRefresh());

        this._refresh();
    }

    _scheduleRefresh() {
        if (this._debounceId)
            GLib.source_remove(this._debounceId);
        this._debounceId = GLib.timeout_add(GLib.PRIORITY_DEFAULT, DEBOUNCE_MS, () => {
            this._debounceId = 0;
            this._refresh();
            return GLib.SOURCE_REMOVE;
        });
    }

    _now() {
        // Seconds since the epoch (matches `date +%s` in the hook).
        return Math.floor(GLib.get_real_time() / 1000000);
    }

    _pidAlive(pid) {
        if (!pid || pid <= 1)
            return true; // unknown -> don't prune
        return GLib.file_test(`/proc/${pid}`, GLib.FileTest.EXISTS);
    }

    _refresh() {
        const dir = Gio.File.new_for_path(this._stateDir);
        const found = new Map();
        const now = this._now();

        let en = null;
        try {
            en = dir.enumerate_children('standard::name,standard::type',
                Gio.FileQueryInfoFlags.NONE, null);
        } catch (_e) {
            en = null;
        }

        if (en) {
            let info;
            while ((info = en.next_file(null)) !== null) {
                const name = info.get_name();
                if (!name.endsWith('.json'))
                    continue;

                const child = dir.get_child(name);
                let data;
                try {
                    const [ok, contents] = child.load_contents(null);
                    if (!ok)
                        continue;
                    data = JSON.parse(new TextDecoder().decode(contents));
                } catch (_e) {
                    continue; // partially written / garbage -> skip this round
                }

                // Prune markers whose owning Claude process is gone.
                const age = data.ts ? now - data.ts : 0;
                if (age >= PRUNE_GRACE_SECONDS && !this._pidAlive(data.pid)) {
                    try { child.delete(null); } catch (_e) {}
                    continue;
                }

                data._path = child.get_path();
                found.set(data.session || name, data);
            }
            try { en.close(null); } catch (_e) {}
        }

        this._waiting = found;
        this._updateUI();
        this._updateTimer();
    }

    // The 15s timer only lives while there is something to age/prune.
    _updateTimer() {
        const want = this._waiting.size > 0;
        if (want && !this._timerId) {
            this._timerId = GLib.timeout_add_seconds(GLib.PRIORITY_DEFAULT,
                TIMER_SECONDS, () => {
                    this._refresh();
                    return GLib.SOURCE_CONTINUE;
                });
        } else if (!want && this._timerId) {
            GLib.source_remove(this._timerId);
            this._timerId = 0;
        }
    }

    _projectName(d) {
        if (!d.cwd)
            return 'session';
        const parts = d.cwd.split('/').filter(s => s.length > 0);
        return parts.length ? parts[parts.length - 1] : d.cwd;
    }

    _ageStr(ts) {
        if (!ts)
            return 'just now';
        const s = Math.max(0, this._now() - ts);
        if (s < 60)
            return `${s}s ago`;
        if (s < 3600)
            return `${Math.floor(s / 60)}m ago`;
        return `${Math.floor(s / 3600)}h ago`;
    }

    _updateUI() {
        const n = this._waiting.size;

        // Panel icon + badge, and turn the whole top bar red while waiting.
        if (n > 0) {
            this._icon.add_style_class_name('claude-waiting-active');
            Main.panel.add_style_class_name('claude-panel-alert');
            this._countLabel.text = String(n);
            this._countLabel.visible = true;
        } else {
            this._icon.remove_style_class_name('claude-waiting-active');
            Main.panel.remove_style_class_name('claude-panel-alert');
            this._countLabel.visible = false;
        }

        // Header.
        this._headerItem.label.text = n > 0
            ? `${n} Claude session${n > 1 ? 's' : ''} waiting for you`
            : 'No Claude sessions waiting';

        // Session list.
        this._sessionSection.removeAll();
        for (const [sid, d] of this._waiting) {
            const text = `${this._projectName(d)}  —  ${this._ageStr(d.ts)}`;
            const item = new PopupMenu.PopupMenuItem(text);
            item.connect('activate', () => this._dismiss(sid));
            this._sessionSection.addMenuItem(item);
        }
        const hasItems = n > 0;
        this._dismissAllSep.visible = hasItems;
        this._dismissAllItem.visible = hasItems;

        // Fire a desktop notification once per newly-waiting session.
        for (const [sid, d] of this._waiting) {
            if (!this._known.has(sid)) {
                this._known.add(sid);
                Main.notify('Claude Code is waiting',
                    `${this._projectName(d)}: ${d.message || 'waiting for your input'}`);
            }
        }
        // Forget sessions that are no longer waiting, so they re-notify later.
        for (const sid of [...this._known]) {
            if (!this._waiting.has(sid))
                this._known.delete(sid);
        }
    }

    _dismiss(sid) {
        const d = this._waiting.get(sid);
        if (d && d._path) {
            try { Gio.File.new_for_path(d._path).delete(null); } catch (_e) {}
        }
        this._refresh();
    }

    _dismissAll() {
        for (const sid of [...this._waiting.keys()])
            this._dismiss(sid);
    }

    destroy() {
        if (this._debounceId) {
            GLib.source_remove(this._debounceId);
            this._debounceId = 0;
        }
        if (this._timerId) {
            GLib.source_remove(this._timerId);
            this._timerId = 0;
        }
        if (this._monitor) {
            this._monitor.cancel();
            this._monitor = null;
        }
        // Never leave the bar red if we're being disabled/removed.
        Main.panel.remove_style_class_name('claude-panel-alert');
        super.destroy();
    }
});

// Resolve which directory to watch:
//   1. the path in <extension dir>/claude-waiting-dir.txt (written by install.sh
//      --watch-dir, e.g. another user's home in a cross-user setup), else
//   2. this user's own ~/.local/share/claude-waiting.
function resolveWatchDir(extPath) {
    let dir = null;
    try {
        const cfg = GLib.build_filenamev([extPath, 'claude-waiting-dir.txt']);
        if (GLib.file_test(cfg, GLib.FileTest.EXISTS)) {
            const [ok, bytes] = GLib.file_get_contents(cfg);
            if (ok)
                dir = new TextDecoder().decode(bytes).trim();
        }
    } catch (_e) {
        dir = null;
    }
    if (!dir || dir.length === 0)
        return GLib.build_filenamev([GLib.get_home_dir(), ...STATE_SUBDIR]);
    if (dir.startsWith('~/'))
        dir = GLib.build_filenamev([GLib.get_home_dir(), dir.slice(2)]);
    return dir;
}

export default class ClaudeWaitingExtension extends Extension {
    enable() {
        const stateDir = resolveWatchDir(this.path);
        this._indicator = new ClaudeIndicator(stateDir);
        Main.panel.addToStatusArea('claude-waiting', this._indicator);
        this._indicator.start();
    }

    disable() {
        this._indicator?.destroy();
        this._indicator = null;
    }
}
