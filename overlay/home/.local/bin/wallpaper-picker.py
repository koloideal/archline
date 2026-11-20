#!/usr/bin/env python3
import hashlib
import json
import os
import subprocess
import gi

gi.require_version('Gtk', '4.0')
gi.require_version('Gdk', '4.0')
gi.require_version('GdkPixbuf', '2.0')
from concurrent.futures import ThreadPoolExecutor
from gi.repository import Gdk, GdkPixbuf, Gio, GLib, Gtk

MONITOR = 'eDP-1'
CONF = os.path.expanduser('~/.config/hypr/hyprpaper.conf')
ROOTS = (
    os.path.expanduser('~/Pictures/wallpapers'),
    os.path.expanduser('~/.config/hypr/wallpapers'),
)
EXTS = ('.png', '.jpg', '.jpeg', '.webp')
THUMB_W, THUMB_H = 190, 107
APP_ID = 'dev.wp.pick'
CACHE = os.path.expanduser('~/.cache/wallpaper-preview')


def monitor_size():
    try:
        out = subprocess.run(('hyprctl', 'monitors', '-j'),
                             capture_output=True, text=True, timeout=5).stdout
        for m in json.loads(out):
            if m.get('name') == MONITOR:
                return int(m['width']), int(m['height'])
    except Exception:
        pass
    return 1920, 1080


MON_W, MON_H = monitor_size()


def scaled_copy(path):
    """Cover-scaled 1080p jpeg in cache — hyprpaper swaps it with no decode flash."""
    os.makedirs(CACHE, exist_ok=True)
    out = os.path.join(CACHE, hashlib.md5(path.encode()).hexdigest() + '.jpg')
    if os.path.exists(out):
        return out
    pb = GdkPixbuf.Pixbuf.new_from_file(path)
    sw, sh = pb.get_width(), pb.get_height()
    scale = max(MON_W / sw, MON_H / sh)
    w, h = max(MON_W, round(sw * scale)), max(MON_H, round(sh * scale))
    pb = pb.scale_simple(w, h, GdkPixbuf.InterpType.BILINEAR)
    pb = GdkPixbuf.Pixbuf.new_subpixbuf(
        pb, (w - MON_W) // 2, (h - MON_H) // 2, MON_W, MON_H)
    pb.savev(out, 'jpeg', ['quality'], ['92'])
    return out

CSS = b'''
window { background: #1d2021; }
picture { border-radius: 8px; }
picture:selected { outline: 3px solid #fe8019; }
listitem { padding: 4px; }
gridview { padding: 8px; }
'''


def collect_wallpapers():
    items = []
    for root in ROOTS:
        if not os.path.isdir(root):
            continue
        for dirpath, _, names in os.walk(root):
            for name in names:
                if name.lower().endswith(EXTS):
                    items.append((os.path.relpath(os.path.join(dirpath, name), root),
                                  os.path.join(dirpath, name)))
    items.sort(key=lambda i: i[0].lower())
    return [p for _, p in items]


def read_current(conf=CONF):
    try:
        with open(conf, encoding='utf-8') as f:
            for line in f:
                line = line.strip()
                if line.startswith('path'):
                    return line.split('=', 1)[1].strip()
    except OSError:
        pass
    return None


def write_conf(path, conf=CONF):
    try:
        with open(conf, 'w', encoding='utf-8') as f:
            f.write(f'ipc = on\nwallpaper {{\n\tmonitor = \n\tpath = {path}\n\tfit_mode = cover\n}}\nsplash = false\n')
    except OSError:
        pass


class Picker(Gtk.Application):
    def __init__(self, files, original):
        super().__init__(application_id=APP_ID)
        self.files = files
        self.original = original
        self.confirmed = False
        self.pool = ThreadPoolExecutor(max_workers=6)
        self._pending = 0

    def preview(self, path):
        self._pending = path
        GLib.timeout_add(80, self._apply_pending)

    @staticmethod
    def _set_wallpaper(path):
        subprocess.Popen(
            ('hyprctl', 'hyprpaper', 'wallpaper', f'{MONITOR},{path}'),
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    def _apply_pending(self):
        path, self._pending = self._pending, None
        if not path or self.confirmed:
            return GLib.SOURCE_REMOVE

        def work():
            try:
                target = scaled_copy(path)
            except Exception:
                target = path
            GLib.idle_add(lambda: not self.confirmed and self._set_wallpaper(target))

        self.pool.submit(work)
        return GLib.SOURCE_REMOVE

    def do_activate(self):
        provider = Gtk.CssProvider()
        provider.load_from_data(CSS)
        Gtk.StyleContext.add_provider_for_display(
            Gdk.Display.get_default(), provider,
            Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)

        win = Gtk.ApplicationWindow(application=self, title='Обои')
        win.set_default_size(830, 520)

        vbox = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        hint = Gtk.Label(label='стрелки / клик — превью   ·   Enter / двойной клик — выбрать   ·   Esc — отмена')
        hint.add_css_class('dim-label')
        hint.set_margin_top(6)
        hint.set_margin_bottom(2)
        vbox.append(hint)

        scroll = Gtk.ScrolledWindow(vexpand=True)
        vbox.append(scroll)

        store = Gtk.StringList.new(self.files)
        self.sel = Gtk.SingleSelection(model=store, autoselect=True)
        self.sel.connect('notify::selected', self._on_selected)

        factory = Gtk.SignalListItemFactory()
        factory.connect('setup', self._setup)
        factory.connect('bind', self._bind)

        grid = Gtk.GridView(model=self.sel, factory=factory)
        grid.set_single_click_activate(False)
        grid.connect('activate', self._on_activate)
        scroll.set_child(grid)

        keys = Gtk.EventControllerKey()
        keys.connect('key-pressed', self._on_key)
        win.add_controller(keys)
        win.connect('close-request', self._on_close)

        win.set_child(vbox)
        win.present()

    @staticmethod
    def _setup(_factory, item):
        pic = Gtk.Picture(content_fit=Gtk.ContentFit.CONTAIN)
        pic.set_size_request(THUMB_W, THUMB_H)
        item.set_child(pic)

    def _bind(self, _factory, item):
        pic = item.get_child()
        path = item.get_item().get_string()
        pic._wp_path = path

        def load():
            try:
                pb = GdkPixbuf.Pixbuf.new_from_file_at_scale(path, THUMB_W, THUMB_H, True)
                tex = Gdk.Texture.new_for_pixbuf(pb)
                GLib.idle_add(lambda: pic._wp_path == path and pic.set_paintable(tex))
            except Exception:
                pass

        self.pool.submit(load)

    def _selected_path(self):
        item = self.sel.get_selected_item()
        return item.get_string() if item else None

    def _on_selected(self, *_):
        path = self._selected_path()
        if path:
            self.preview(path)

    def _on_activate(self, _grid, _pos):
        path = self._selected_path()
        if path:
            self.confirmed = True
            write_conf(path)
            self._finish()

    def _on_key(self, _ctrl, keyval, _code, _state):
        if keyval == Gdk.KEY_Escape:
            self._finish()
            return True
        if keyval in (Gdk.KEY_Return, Gdk.KEY_KP_Enter):
            path = self._selected_path()
            if path:
                self.confirmed = True
                write_conf(path)
                self._finish()
            return True
        return False

    def _on_close(self, *_):
        self._pending = None
        if not self.confirmed and self.original:
            original = self.original

            def restore():
                try:
                    target = scaled_copy(original)
                except Exception:
                    target = original
                GLib.idle_add(lambda: self._set_wallpaper(target))

            self.pool.submit(restore)
        self.pool.shutdown(wait=False)
        return False

    def _finish(self):
        self._on_close()
        self.quit()


def main():
    files = collect_wallpapers()
    if not files:
        return 1
    app = Picker(files, read_current())
    app.run()


if __name__ == '__main__':
    main()
