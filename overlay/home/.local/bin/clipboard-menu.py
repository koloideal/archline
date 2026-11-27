#!/usr/bin/env python3
"""Clipboard history picker: cliphist backend, custom GTK4 UI, paste into the previous window."""
import json
import os
import re
import shutil
import subprocess
import sys
import threading
from pathlib import Path
from queue import Queue

HOME = Path.home()
os.environ['PATH'] = str(HOME / '.local/bin') + os.pathsep + os.environ.get('PATH', '')
CACHE_ROOT = Path(os.environ.get('XDG_CACHE_HOME', HOME / '.cache'))
CACHE = CACHE_ROOT / 'clipboard-menu'
MAX_ITEMS = 120
APP_ID = 'dev.clipboard.menu'
TERMINAL_CLASSES = (
    'kitty', 'alacritty', 'foot', 'wezterm', 'ghostty', 'konsole',
    'gnome-terminal', 'xterm', 'st', 'footclient',
)


def notify(summary, body=''):
    subprocess.run(['notify-send', summary, body], stdout=subprocess.DEVNULL,
                   stderr=subprocess.DEVNULL, check=False)


def have_cliphist():
    return shutil.which('cliphist') is not None


def daemon_running():
    res = subprocess.run(['pgrep', '-x', 'wl-paste'], stdout=subprocess.PIPE,
                         stderr=subprocess.DEVNULL, check=False, text=True)
    if res.returncode != 0:
        return False
    for pid in res.stdout.split():
        try:
            args = Path(f'/proc/{pid}/cmdline').read_bytes().split(b'\0')
        except OSError:
            continue
        if b'--watch' in args and b'cliphist' in args and b'store' in args:
            return True
    return False


def ensure_daemon():
    if not have_cliphist():
        notify('Буфер обмена', 'cliphist не найден')
        return False
    if not daemon_running():
        subprocess.Popen(['wl-paste', '--watch', 'cliphist', 'store'],
                         stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                         stderr=subprocess.DEVNULL, start_new_session=True)
    return True


def cliphist_lines():
    res = subprocess.run(['cliphist', 'list'], stdout=subprocess.PIPE,
                         stderr=subprocess.DEVNULL, check=False)
    if res.returncode != 0:
        return []
    return res.stdout.decode('utf-8', 'replace').splitlines()[:MAX_ITEMS]


def binary_info(preview):
    text = preview.strip()
    match = re.fullmatch(r'\[\[\s*binary data\s+(.+?)\s*\]\]', text)
    if not match:
        return None
    parts = match.group(1).split()
    dim = ''
    if parts and re.fullmatch(r'\d+x\d+', parts[-1]):
        dim = parts.pop()
    ext = parts.pop().lower() if parts else 'bin'
    if not re.fullmatch(r'[a-z0-9][a-z0-9+.-]{0,15}', ext):
        ext = 'bin'
    size = ' '.join(parts)
    return {'ext': ext, 'size': size, 'dim': dim}


def decode_item(item_id):
    res = subprocess.run(['cliphist', 'decode', item_id], stdout=subprocess.PIPE,
                         stderr=subprocess.DEVNULL, check=False)
    if res.returncode != 0:
        return None
    return res.stdout


def image_path(item_id, ext):
    if not item_id.isdigit():
        return None
    CACHE.mkdir(parents=True, exist_ok=True)
    path = CACHE / f'{item_id}.{ext}'
    if path.exists() and path.stat().st_size:
        return path
    data = decode_item(item_id)
    if not data:
        return None
    tmp = CACHE / f'.{item_id}.{os.getpid()}.tmp'
    tmp.write_bytes(data)
    os.replace(tmp, path)
    return path


class ClipboardItem:
    def __init__(self, raw):
        self.raw = raw
        self.item_id, _, preview = raw.partition('\t')
        self.preview = preview or ' '
        self.is_binary = self.preview.startswith('[[ binary data')
        self.image = None
        self.image_ext = None
        self.title = self.preview
        self.subtitle = 'текст'
        self.search = self.preview.lower()

        info = binary_info(self.preview) if self.is_binary else None
        if info:
            ext, dim, size = info['ext'], info['dim'], info['size']
            self.title = f'Изображение · {ext}'
            bits = [bit for bit in (dim, size) if bit]
            self.subtitle = ' · '.join(bits) or 'бинарные данные'
            self.search = f'изображение image {ext} {dim}'.lower()
            if ext in {'png', 'jpg', 'jpeg', 'webp', 'gif', 'bmp'}:
                self.image_ext = ext
        elif len(self.preview) > 90:
            self.subtitle = 'текст'


def load_items():
    items = []
    for raw in cliphist_lines():
        item_id, sep, _preview = raw.partition('\t')
        if sep and item_id:
            items.append(ClipboardItem(raw))
    return items


def active_window():
    try:
        res = subprocess.run(['hyprctl', 'activewindow', '-j'], stdout=subprocess.PIPE,
                             stderr=subprocess.DEVNULL, check=False, text=True, timeout=0.4)
        if res.returncode == 0 and res.stdout.strip():
            return json.loads(res.stdout)
    except (OSError, ValueError, subprocess.SubprocessError):
        pass
    return {}


def lua_string(value):
    return value.replace('\\', '\\\\').replace('"', '\\"')


def send_shortcut(mods, key, address=''):
    fields = f'mods = "{lua_string(mods)}", key = "{lua_string(key)}"'
    if re.fullmatch(r'0x[0-9a-fA-F]+', address or ''):
        fields += f', window = "address:{address}"'
    res = subprocess.run(['hyprctl', 'dispatch', f'hl.dsp.send_shortcut({{ {fields} }})'],
                         stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                         check=False, text=True)
    return res.returncode == 0 and res.stdout.strip() == 'ok'


def paste_into(target):
    cls = str(target.get('class', '')).lower()
    address = str(target.get('address', ''))
    terminal = any(part in cls for part in TERMINAL_CLASSES)
    if terminal and (send_shortcut('CONTROL SHIFT', 'v', address) or
                     send_shortcut('CONTROL SHIFT', 'v')):
        return True
    if send_shortcut('CONTROL', 'v', address) or send_shortcut('CONTROL', 'v'):
        return True
    return (send_shortcut('SHIFT', 'Insert', address) or
            send_shortcut('SHIFT', 'Insert'))


def plural_items(count):
    if count % 10 == 1 and count % 100 != 11:
        return 'элемент'
    if count % 10 in (2, 3, 4) and count % 100 not in (12, 13, 14):
        return 'элемента'
    return 'элементов'


def copy_item(item):
    data = decode_item(item.item_id)
    if data is None:
        notify('Буфер обмена', 'Не удалось прочитать элемент истории')
        return False
    res = subprocess.run(['wl-copy'], input=data, stdout=subprocess.DEVNULL,
                         stderr=subprocess.DEVNULL, check=False)
    if res.returncode != 0:
        notify('Буфер обмена', 'Не удалось скопировать элемент')
        return False
    return True


def picker():
    import gi
    gi.require_version('Gtk', '4.0')
    gi.require_version('Gdk', '4.0')
    from gi.repository import Gdk, Gio, GLib, Gtk, Pango
    GLib.set_prgname(APP_ID)

    css = b'''
    window.background, .clipboard-window {
        background: #1d2021;
        color: #ebdbb2;
        opacity: 1;
    }
    .clipboard-root {
        background: #1d2021;
        opacity: 1;
        padding: 14px;
    }
    .clipboard-search {
        min-height: 42px;
        margin-bottom: 10px;
        padding: 0 14px;
        border: 1px solid rgba(254, 128, 25, 0.55);
        border-radius: 14px;
        background-color: #282828;
        color: #ebdbb2;
        caret-color: #fe8019;
        font-family: "Onest", "JetBrainsMono Nerd Font", sans-serif;
        font-size: 15px;
    }
    .clipboard-search:focus {
        border-color: #fe8019;
        box-shadow: 0 0 0 1px rgba(254, 128, 25, 0.28);
    }
    .clipboard-list {
        background-color: transparent;
    }
    .clipboard-row {
        margin: 2px 0;
        padding: 0;
        border: 1px solid transparent;
        border-radius: 13px;
        background-color: rgba(40, 40, 40, 0.72);
    }
    .clipboard-row:hover {
        background-color: rgba(60, 56, 54, 0.88);
    }
    .clipboard-row:selected {
        border-color: #fe8019;
        background-color: rgba(254, 128, 25, 0.17);
    }
    .clip-item {
        padding: 9px 11px;
    }
    .clip-icon {
        min-width: 34px;
        color: #fe8019;
        font-family: "JetBrainsMono Nerd Font", sans-serif;
        font-size: 19px;
    }
    .clip-image {
        min-width: 84px;
        min-height: 52px;
        margin-right: 8px;
        border-radius: 8px;
        background-color: #32302f;
    }
    .clip-title {
        color: #ebdbb2;
        font-family: "Onest", "JetBrainsMono Nerd Font", sans-serif;
        font-size: 13px;
    }
    .clip-subtitle {
        color: #a89984;
        font-family: "Onest", sans-serif;
        font-size: 10px;
    }
    .clip-footer {
        margin-top: 10px;
    }
    .clip-count {
        color: #a89984;
        font-family: "Onest", sans-serif;
        font-size: 11px;
    }
    .clip-clear {
        padding: 7px 12px;
        border: 1px solid rgba(251, 73, 52, 0.38);
        border-radius: 11px;
        background-color: rgba(251, 73, 52, 0.10);
        color: #fb4934;
        font-family: "Onest", sans-serif;
        font-size: 11px;
    }
    .clip-clear:hover {
        background-color: rgba(251, 73, 52, 0.22);
    }
    .clip-clear.confirm {
        border-color: #fb4934;
        background-color: #fb4934;
        color: #1d2021;
        font-weight: 700;
    }
    scrollbar slider {
        min-width: 6px;
        border-radius: 4px;
        background-color: rgba(254, 128, 25, 0.45);
    }
    '''

    class Picker(Gtk.Application):
        def __init__(self, target):
            super().__init__(application_id=APP_ID)
            self.target = target
            self.win = None
            self.rows = []
            self.items = []
            self.done = False
            self.clear_timer = 0
            self.image_queue = Queue()
            self.image_thread = None

        def do_activate(self):
            if self.win is not None:
                self.cancel()
                return

            display = Gdk.Display.get_default()
            if display is None:
                notify('Буфер обмена', 'Не найден Wayland/GTK display')
                self.quit()
                return
            prov = Gtk.CssProvider()
            prov.load_from_data(css)
            Gtk.StyleContext.add_provider_for_display(
                display, prov, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)

            self.search = Gtk.SearchEntry(placeholder_text='Поиск в истории…')
            self.search.add_css_class('clipboard-search')
            self.search.connect('search-changed', self.on_search)

            self.listbox = Gtk.ListBox()
            self.listbox.add_css_class('clipboard-list')
            self.listbox.set_selection_mode(Gtk.SelectionMode.SINGLE)
            self.listbox.set_filter_func(self.row_matches)
            self.listbox.connect('row-activated', lambda _box, row: self.choose(row))

            self.scroll = Gtk.ScrolledWindow(vexpand=True, child=self.listbox)
            self.scroll.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)

            self.count = Gtk.Label(xalign=0)
            self.count.add_css_class('clip-count')
            self.count.set_hexpand(True)
            self.clear_button = Gtk.Button(label='Очистить историю')
            self.clear_button.add_css_class('clip-clear')
            self.clear_button.connect('clicked', self.on_clear)
            footer = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL)
            footer.add_css_class('clip-footer')
            footer.append(self.count)
            footer.append(self.clear_button)

            root = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
            root.add_css_class('clipboard-root')
            root.append(self.search)
            root.append(self.scroll)
            root.append(footer)

            self.win = Gtk.ApplicationWindow(application=self, title='Буфер обмена', child=root)
            self.win.add_css_class('clipboard-window')
            self.win.set_default_size(680, 540)
            self.win.set_resizable(False)
            self.win.set_decorated(False)
            self.win.connect('close-request', self.on_close)

            keys = Gtk.EventControllerKey()
            keys.set_propagation_phase(Gtk.PropagationPhase.CAPTURE)
            keys.connect('key-pressed', self.on_key)
            self.win.add_controller(keys)

            self.win.present()
            GLib.idle_add(self.reload_items)
            GLib.idle_add(self.focus_search)

        def focus_search(self):
            if self.win is not None and not self.done:
                self.search.grab_focus()
            return False

        def row_matches(self, row):
            item = getattr(row, 'item', None)
            if item is None:
                return True
            query = self.search.get_text().strip().lower()
            return not query or query in item.search

        def make_row(self, item):
            row = Gtk.ListBoxRow()
            row.item = item
            row.add_css_class('clipboard-row')

            box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=4)
            box.add_css_class('clip-item')
            if item.image_ext:
                pic = Gtk.Picture()
                pic.add_css_class('clip-image')
                pic.set_content_fit(Gtk.ContentFit.CONTAIN)
                pic.set_can_shrink(True)
                pic.set_size_request(84, 52)
                box.append(pic)
                self.queue_image(row, item, pic)
            else:
                icon = Gtk.Label(label='󰋩' if item.is_binary else '󰈙')
                icon.add_css_class('clip-icon')
                box.append(icon)

            text_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=2)
            text_box.set_hexpand(True)
            text_box.set_valign(Gtk.Align.CENTER)
            title = Gtk.Label(label=item.title, xalign=0)
            title.add_css_class('clip-title')
            title.set_ellipsize(Pango.EllipsizeMode.END)
            title.set_single_line_mode(True)
            title.set_max_width_chars(72)
            text_box.append(title)
            if item.is_binary:
                subtitle = Gtk.Label(label=item.subtitle, xalign=0)
                subtitle.add_css_class('clip-subtitle')
                subtitle.set_ellipsize(Pango.EllipsizeMode.END)
                subtitle.set_single_line_mode(True)
                text_box.append(subtitle)
            box.append(text_box)
            row.set_child(box)

            click = Gtk.GestureClick()
            click.set_button(0)
            click.connect('released', self.on_row_click, row)
            row.add_controller(click)
            return row

        def queue_image(self, row, item, pic):
            self.image_queue.put((row, item, pic))
            if self.image_thread is None:
                self.image_thread = threading.Thread(target=self.load_images, daemon=True)
                self.image_thread.start()

        def load_images(self):
            import gi as image_gi
            image_gi.require_version('GdkPixbuf', '2.0')
            from gi.repository import GdkPixbuf
            while True:
                row, item, pic = self.image_queue.get()
                full = image_path(item.item_id, item.image_ext)
                thumb = None
                if full is not None:
                    thumb = CACHE / f'{item.item_id}.{item.image_ext}.thumb.png'
                    if not thumb.exists():
                        try:
                            pixbuf = GdkPixbuf.Pixbuf.new_from_file_at_scale(
                                str(full), 168, 104, True)
                            tmp = CACHE / f'.{item.item_id}.{os.getpid()}.thumb.tmp'
                            pixbuf.savev(str(tmp), 'png', [], [])
                            os.replace(tmp, thumb)
                        except Exception:
                            thumb = None
                if thumb is not None and not self.done:
                    GLib.idle_add(self.set_image, row, pic, thumb)

        def set_image(self, row, pic, thumb):
            if not self.done and row.get_parent() is not None:
                try:
                    pic.set_paintable(Gdk.Texture.new_from_filename(str(thumb)))
                except GLib.Error:
                    pass
            return False

        def reload_items(self):
            for row in list(self.rows):
                self.listbox.remove(row)
            self.rows.clear()
            self.items = load_items()

            if not self.items:
                row = Gtk.ListBoxRow()
                row.item = None
                row.set_selectable(False)
                row.set_activatable(False)
                row.add_css_class('clipboard-row')
                empty = Gtk.Label(label='История пока пуста', xalign=0.5)
                empty.add_css_class('clip-title')
                empty.set_margin_top(22)
                empty.set_margin_bottom(22)
                row.set_child(empty)
                self.listbox.append(row)
                self.rows.append(row)
            else:
                for item in self.items:
                    row = self.make_row(item)
                    self.listbox.append(row)
                    self.rows.append(row)

            self.count.set_label(
                f'{len(self.items)} {plural_items(len(self.items))} · Enter/клик — вставить · Ctrl+Del — удалить')
            self.listbox.invalidate_filter()
            GLib.idle_add(self.select_first)

        def visible_rows(self):
            return [row for row in self.rows
                    if row.get_visible() and getattr(row, 'item', None) is not None]

        def select_first(self):
            rows = self.visible_rows()
            if rows and self.win is not None and not self.done:
                self.listbox.select_row(rows[0])
                self.scroll_to_row(rows[0])
            return False

        def selected_row(self):
            row = self.listbox.get_selected_row()
            if row is not None and row.get_visible() and getattr(row, 'item', None) is not None:
                return row
            rows = self.visible_rows()
            return rows[0] if rows else None

        def scroll_to_row(self, row):
            found, bounds = row.compute_bounds(self.listbox)
            if not found:
                return
            adj = self.scroll.get_vadjustment()
            top = bounds.get_y()
            bottom = top + bounds.get_height()
            if top < adj.get_value():
                adj.set_value(top)
            elif bottom > adj.get_value() + adj.get_page_size():
                adj.set_value(bottom - adj.get_page_size())

        def move_selection(self, direction):
            rows = self.visible_rows()
            if not rows:
                return
            current = self.listbox.get_selected_row()
            try:
                index = rows.index(current)
            except ValueError:
                index = 0 if direction > 0 else len(rows) - 1
            else:
                index = max(0, min(len(rows) - 1, index + direction))
            self.listbox.select_row(rows[index])
            self.scroll_to_row(rows[index])
            rows[index].grab_focus()
            self.search.grab_focus()

        def on_search(self, *_):
            self.listbox.invalidate_filter()
            GLib.idle_add(self.select_first)
            query = self.search.get_text().strip()
            visible = len(self.visible_rows())
            self.count.set_label(
                f'{visible} из {len(self.items)} · Enter/клик — вставить' if query
                else f'{len(self.items)} {plural_items(len(self.items))} · Enter/клик — вставить · Ctrl+Del — удалить')

        def on_row_click(self, gesture, _n_press, _x, _y, row):
            if gesture.get_current_button() == 1:
                self.choose(row)

        def on_key(self, _controller, key, _code, state):
            if key == Gdk.KEY_Escape:
                self.cancel()
                return True
            if key in (Gdk.KEY_Return, Gdk.KEY_KP_Enter):
                self.choose(self.selected_row())
                return True
            if key == Gdk.KEY_BackSpace and not self.search.get_text():
                return True
            if key == Gdk.KEY_Down:
                self.move_selection(1)
                return True
            if key == Gdk.KEY_Up:
                self.move_selection(-1)
                return True
            if key in (Gdk.KEY_Delete, Gdk.KEY_KP_Delete) and state & Gdk.ModifierType.CONTROL_MASK:
                self.delete_selected()
                return True
            return False

        def delete_selected(self):
            row = self.selected_row()
            if row is None:
                return
            item = row.item
            subprocess.run(['cliphist', 'delete'], input=(item.raw + '\n').encode(),
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
            if row in self.rows:
                self.rows.remove(row)
            self.listbox.remove(row)
            if item in self.items:
                self.items.remove(item)
            try:
                os.remove(item.image)
            except (OSError, TypeError):
                pass
            self.on_search()

        def on_clear(self, *_):
            if not self.clear_button.has_css_class('confirm'):
                self.clear_button.add_css_class('confirm')
                self.clear_button.set_label('Нажми ещё раз')
                if self.clear_timer:
                    GLib.source_remove(self.clear_timer)
                self.clear_timer = GLib.timeout_add(2200, self.disarm_clear)
                return
            subprocess.run(['cliphist', 'wipe'], stdout=subprocess.DEVNULL,
                           stderr=subprocess.DEVNULL, check=False)
            shutil.rmtree(CACHE, ignore_errors=True)
            self.disarm_clear()
            self.reload_items()

        def disarm_clear(self):
            self.clear_timer = 0
            self.clear_button.remove_css_class('confirm')
            self.clear_button.set_label('Очистить историю')
            return False

        def choose(self, row):
            if self.done or row is None or getattr(row, 'item', None) is None:
                return
            item = row.item
            if not copy_item(item):
                self.cancel()
                return
            self.done = True
            self.win.set_visible(False)
            if os.environ.get('CLIPBOARD_MENU_NO_PASTE'):
                GLib.idle_add(self.quit)
            else:
                GLib.timeout_add(140, self.paste_and_quit)

        def paste_and_quit(self):
            paste_into(self.target)
            self.quit()
            return False

        def cancel(self):
            if self.done:
                return
            self.done = True
            if self.win is not None:
                self.win.set_visible(False)
            self.quit()

        def on_close(self, *_):
            if not self.done:
                self.done = True
                GLib.idle_add(self.quit)
            return False

    Picker(target=active_window()).run()


def main():
    if len(sys.argv) > 1 and sys.argv[1] in ('--daemon', 'daemon'):
        return 0 if ensure_daemon() else 1
    if not ensure_daemon():
        return 1
    picker()
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
