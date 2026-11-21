#!/usr/bin/env python3
"""Wallpaper picker: GTK4 grid of cached thumbnails, live preview through awww.

  wallpaper-picker.py            open the picker
  wallpaper-picker.py --warm     build missing thumbnails (all CPU cores)
  wallpaper-picker.py --restore  show the saved wallpaper (session start)
"""
import hashlib
import json
import os
import subprocess
import sys
import time

HOME = os.path.expanduser('~')
ROOTS = (f'{HOME}/Pictures/wallpapers', f'{HOME}/.config/hypr/wallpapers')
STATE = f'{HOME}/.config/hypr/wallpaper'
COUNTS = f'{HOME}/.cache/wallpaper-picks.json'
DEFAULT = f'{HOME}/.config/hypr/wallpapers/girl-2.png'
THUMBS = f'{HOME}/.cache/wallpaper-thumbs'
EXTS = ('.png', '.jpg', '.jpeg', '.webp')
THUMB_W, THUMB_H = 180, 102
APP_ID = 'dev.wp.pick'
FADE = ('--transition-type', 'fade', '--transition-duration', '0.35', '--transition-fps', '144')


def load_counts():
    try:
        with open(COUNTS, encoding='utf-8') as f:
            return json.load(f)
    except Exception:
        return {}


def bump_count(path):
    counts = load_counts()
    counts[path] = counts.get(path, 0) + 1
    os.makedirs(os.path.dirname(COUNTS), exist_ok=True)
    tmp = f'{COUNTS}.{os.getpid()}'
    with open(tmp, 'w', encoding='utf-8') as f:
        json.dump(counts, f)
    os.replace(tmp, COUNTS)


def collect():
    counts = load_counts()
    items = []
    for root in ROOTS:
        for d, _, names in os.walk(root):
            for n in names:
                if n.lower().endswith(EXTS):
                    p = os.path.join(d, n)
                    items.append((os.path.relpath(p, root).lower(), p))
    items.sort(key=lambda it: (-counts.get(it[1], 0), it[0]))
    return [p for _, p in items]


def thumb_path(path):
    st = os.stat(path)
    key = f'{path}:{st.st_mtime_ns}:{st.st_size}:{THUMB_W}x{THUMB_H}'.encode()
    return os.path.join(THUMBS, hashlib.md5(key).hexdigest() + '.png')


def make_thumb(path):
    try:
        out = thumb_path(path)
        if os.path.exists(out):
            return
        import gi
        gi.require_version('GdkPixbuf', '2.0')
        from gi.repository import GdkPixbuf
        pb = GdkPixbuf.Pixbuf.new_from_file_at_scale(path, THUMB_W, THUMB_H, True)
        tmp = f'{out}.{os.getpid()}.tmp'
        pb.savev(tmp, 'png', [], [])
        os.replace(tmp, out)
    except Exception:
        pass


def warm():
    from concurrent.futures import ProcessPoolExecutor
    os.makedirs(THUMBS, exist_ok=True)
    try:
        os.nice(10)
    except OSError:
        pass
    missing = [p for p in collect() if not os.path.exists(thumb_path(p))]
    if missing:
        with ProcessPoolExecutor() as ex:
            list(ex.map(make_thumb, missing, chunksize=4))


def saved():
    try:
        with open(STATE, encoding='utf-8') as f:
            p = f.read().strip()
        if os.path.isfile(p):
            return p
    except OSError:
        pass
    return DEFAULT


def show(path, fade=True, wait=False):
    cmd = ('awww', 'img', *(FADE if fade else ('--transition-type', 'none')), path)
    run = subprocess.run if wait else subprocess.Popen
    try:
        return run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except OSError:
        return None


def restore():
    for _ in range(50):
        try:
            if subprocess.run(('awww', 'query'), capture_output=True).returncode == 0:
                break
        except OSError:
            return
        time.sleep(0.1)
    show(saved(), fade=False, wait=True)
    subprocess.Popen((os.path.expanduser('~/.local/bin/bar-theme.sh'),))


def picker():
    import gi
    gi.require_version('Gtk', '4.0')
    gi.require_version('Gdk', '4.0')
    from gi.repository import Gdk, Gio, GLib, Gtk
    GLib.set_prgname(APP_ID)

    css = b'''
    window { background: #1d2021; }
    gridview { padding: 6px; background: transparent; }
    gridview > child { padding: 3px; border-radius: 6px; }
    gridview > child:selected { background: #fe8019; }
    searchentry { margin: 6px; }
    '''

    class Picker(Gtk.Application):
        def __init__(self):
            super().__init__(flags=Gio.ApplicationFlags.NON_UNIQUE)
            self.files = collect()
            self.original = saved()
            self.done = False
            self.proc = None
            self.timer = 0
            self.waiting = {}
            self.textures = {}
            self.arrow_nav = True
            from concurrent.futures import ThreadPoolExecutor
            self.loader = ThreadPoolExecutor(max_workers=4)

        def do_activate(self):
            prov = Gtk.CssProvider()
            prov.load_from_data(css)
            Gtk.StyleContext.add_provider_for_display(
                Gdk.Display.get_default(), prov, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)

            os.makedirs(THUMBS, exist_ok=True)
            if any(not os.path.exists(thumb_path(p)) for p in self.files):
                subprocess.Popen((sys.executable, os.path.abspath(__file__), '--warm'),
                                 stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                GLib.timeout_add(400, self.poll)

            self.entry = Gtk.SearchEntry(placeholder_text='Поиск обоев…')
            self.sbar = Gtk.SearchBar(child=self.entry)
            self.sbar.connect_entry(self.entry)
            self.store = Gtk.StringList.new(self.files)
            self.filt = Gtk.CustomFilter.new(self.match, None)
            self.entry.connect('search-changed',
                               lambda *_: self.filt.changed(Gtk.FilterChange.DIFFERENT))
            self.entry.connect('activate', lambda *_: self.finish(True))
            self.fmodel = Gtk.FilterListModel(model=self.store, filter=self.filt)
            self.sel = Gtk.SingleSelection(model=self.fmodel)
            if self.original in self.files:
                self.sel.set_selected(self.files.index(self.original))
            self.sel.connect('notify::selected', self.on_selected)

            fac = Gtk.SignalListItemFactory()
            fac.connect('setup', self.setup)
            fac.connect('bind', self.bind)
            fac.connect('unbind', self.unbind)

            self.grid = Gtk.GridView(model=self.sel, factory=fac, max_columns=8)
            self.grid.connect('activate', lambda *_: self.finish(True))

            scroll = Gtk.ScrolledWindow(vexpand=True, child=self.grid)
            box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
            box.append(self.sbar)
            box.append(scroll)
            self.win = Gtk.ApplicationWindow(application=self, title='Обои', child=box)
            self.win.set_default_size(820, 500)
            self.win.connect('close-request', lambda *_: self.finish(False) or True)

            keys = Gtk.EventControllerKey()
            keys.connect('key-pressed', self.on_key)
            self.win.add_controller(keys)
            self.win.present()
            GLib.idle_add(self.scroll_to_selected)

        def scroll_to_selected(self):
            pos = self.sel.get_selected()
            if pos != Gtk.INVALID_LIST_POSITION:
                self.grid.scroll_to(pos, Gtk.ListScrollFlags.FOCUS, None)
            return False

        @staticmethod
        def setup(_f, item):
            pic = Gtk.Picture(content_fit=Gtk.ContentFit.CONTAIN, can_shrink=True)
            pic.set_size_request(THUMB_W, THUMB_H)
            item.set_child(pic)

        def bind(self, _f, item):
            pic, path = item.get_child(), item.get_item().get_string()
            tp = thumb_path(path)
            pic.want = tp
            tex = self.textures.get(tp)
            pic.set_paintable(tex)
            if tex is None:
                if os.path.exists(tp):
                    self.loader.submit(self.load, pic, tp)
                else:
                    self.waiting[pic] = tp

        def unbind(self, _f, item):
            pic = item.get_child()
            pic.want = None
            self.waiting.pop(pic, None)

        def load(self, pic, tp):
            if pic.want != tp or self.done:
                return
            try:
                tex = Gdk.Texture.new_from_filename(tp)
            except GLib.Error:
                return
            GLib.idle_add(self.loaded, pic, tp, tex)

        def loaded(self, pic, tp, tex):
            self.textures[tp] = tex
            if pic.want == tp:
                pic.set_paintable(tex)
            return False

        def poll(self):
            for pic, tp in list(self.waiting.items()):
                if os.path.exists(tp):
                    del self.waiting[pic]
                    self.loader.submit(self.load, pic, tp)
            return not self.done

        def current(self):
            it = self.sel.get_selected_item()
            return it.get_string() if it else None

        def on_selected(self, *_):
            if self.timer:
                GLib.source_remove(self.timer)
            self.timer = GLib.timeout_add(120, self.preview)

        def preview(self):
            self.timer = 0
            if self.sbar.get_search_mode() and not self.arrow_nav:
                return False
            path = self.current()
            if path and not self.done:
                if self.proc and self.proc.poll() is None:
                    self.proc.kill()
                self.proc = show(path)
                subprocess.Popen((os.path.join(HOME, '.local/bin/bar-theme.sh'), path),
                                 stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            return False

        def match(self, item, _data):
            q = self.entry.get_text().strip().lower()
            return not q or q in os.path.basename(item.get_string()).lower()

        def on_key(self, _c, key, _code, state):
            if key == Gdk.KEY_Escape or \
                    (key == Gdk.KEY_w and state & Gdk.ModifierType.CONTROL_MASK):
                if self.sbar.get_search_mode() and self.entry.get_text():
                    self.entry.set_text('')
                    self.sbar.set_search_mode(False)
                    self.grid.grab_focus()
                else:
                    self.finish(False)
                return True
            if key in (Gdk.KEY_Return, Gdk.KEY_KP_Enter):
                self.finish(True)
                return True
            arrows = (Gdk.KEY_Up, Gdk.KEY_Down, Gdk.KEY_Left, Gdk.KEY_Right,
                      Gdk.KEY_Page_Up, Gdk.KEY_Page_Down, Gdk.KEY_Home, Gdk.KEY_End)
            if key in arrows:
                self.arrow_nav = True
                if self.sbar.get_search_mode() and self.entry.has_focus():
                    # фокус в строке: двигаем выделение сами, SearchBar
                    # иначе возвращает фокус entry и навигация не работает
                    n = self.fmodel.get_n_items()
                    if n:
                        sel = self.sel.get_selected()
                        if sel == Gtk.INVALID_LIST_POSITION:
                            sel = 0
                        cols = max(1, self.grid.get_width() // (THUMB_W + 6))
                        if key == Gdk.KEY_Down:
                            sel += cols
                        elif key == Gdk.KEY_Up:
                            sel -= cols
                        elif key == Gdk.KEY_Right:
                            sel += 1
                        elif key == Gdk.KEY_Left:
                            sel -= 1
                        elif key in (Gdk.KEY_Page_Down, Gdk.KEY_End):
                            sel = n - 1
                        else:  # Page_Up / Home
                            sel = 0
                        sel = max(0, min(n - 1, sel))
                        self.sel.set_selected(sel)
                        self.grid.scroll_to(sel, Gtk.ListScrollFlags.FOCUS, None)
                        self.grid.grab_focus()
                    return True
                return False
            if self.sbar.get_search_mode() and not self.entry.has_focus():
                # ввод вручную, пока фокус на сетке; Backspace уводит фокус в строку
                pos = self.entry.get_position()
                t = self.entry.get_text()
                if key == Gdk.KEY_BackSpace:
                    self.entry.set_text(t[:-1])
                    self.entry.grab_focus()
                    self.entry.set_position(-1)
                    self.arrow_nav = False
                    return True
                if not state & (Gdk.ModifierType.CONTROL_MASK | Gdk.ModifierType.ALT_MASK):
                    ch = chr(Gdk.keyval_to_unicode(key))
                    if ch and ch.isprintable():
                        self.entry.set_text(t[:pos] + ch + t[pos:])
                        self.entry.set_position(pos + 1)
                        self.arrow_nav = False
                        return True
                return False
            if not self.sbar.get_search_mode() and \
                    not state & (Gdk.ModifierType.CONTROL_MASK | Gdk.ModifierType.ALT_MASK):
                ch = chr(Gdk.keyval_to_unicode(key))
                if ch and ch.isprintable():
                    # поиск закрыт: открываем, кладём символ и отдаём фокус строке
                    self.sbar.set_search_mode(True)
                    self.entry.set_text(ch)
                    self.entry.grab_focus()
                    self.entry.set_position(-1)
                    self.arrow_nav = False
                    return True
            return False

        def finish(self, accept):
            if self.done:
                return
            self.done = True
            if self.timer:
                GLib.source_remove(self.timer)
            if self.proc and self.proc.poll() is None:
                self.proc.kill()
            self.loader.shutdown(wait=False, cancel_futures=True)
            path = self.current() if accept else None
            if path:
                with open(STATE, 'w', encoding='utf-8') as f:
                    f.write(path + '\n')
                bump_count(path)
                show(path, wait=True)
            else:
                show(self.original, wait=True)
            subprocess.Popen((os.path.expanduser('~/.local/bin/bar-theme.sh'),))
            self.quit()

    Picker().run()


if __name__ == '__main__':
    arg = sys.argv[1] if len(sys.argv) > 1 else ''
    if arg == '--warm':
        warm()
    elif arg == '--restore':
        restore()
    else:
        picker()
