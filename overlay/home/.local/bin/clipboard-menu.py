#!/usr/bin/env python3
"""Clipboard history picker: cliphist backend, wofi UI, paste through Shift+Insert."""
import html
import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

HOME = Path.home()
os.environ['PATH'] = str(HOME / '.local/bin') + os.pathsep + os.environ.get('PATH', '')
CACHE_ROOT = Path(os.environ.get('XDG_CACHE_HOME', HOME / '.cache'))
CACHE = CACHE_ROOT / 'clipboard-menu'
WOFI_CONF = HOME / '.config/hypr/wofi/config.conf'
WOFI_STYLE = HOME / '.config/hypr/wofi/clipboard.css'
MAX_ITEMS = 200


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


def binary_ext(preview):
    parts = preview.strip().split()
    if len(parts) < 5 or parts[-1] != ']]':
        return 'bin'
    ext = parts[-3] if re.fullmatch(r'\d+x\d+', parts[-2]) else parts[-2]
    ext = ext.lower()
    return ext if re.fullmatch(r'[a-z0-9][a-z0-9+.-]{0,15}', ext) else 'bin'


def image_path(item_id, ext):
    if not item_id.isdigit():
        return None
    CACHE.mkdir(parents=True, exist_ok=True)
    path = CACHE / f'{item_id}.{ext}'
    if path.exists() and path.stat().st_size:
        return path
    res = subprocess.run(['cliphist', 'decode', item_id], stdout=subprocess.PIPE,
                         stderr=subprocess.DEVNULL, check=False)
    if res.returncode != 0 or not res.stdout:
        return None
    tmp = CACHE / f'.{item_id}.{os.getpid()}.tmp'
    tmp.write_bytes(res.stdout)
    os.replace(tmp, path)
    return path


def display_line(raw):
    item_id, sep, preview = raw.partition('\t')
    if not sep:
        return None
    preview = preview or ' '
    if preview.startswith('[[ binary data'):
        ext = binary_ext(preview)
        parts = preview.strip().split()
        size = ' '.join(parts[3:-3]) if len(parts) > 6 and re.fullmatch(r'\d+x\d+', parts[-2]) else ' '.join(parts[3:-2])
        dim = parts[-2] if len(parts) > 5 and re.fullmatch(r'\d+x\d+', parts[-2]) else ''
        label = f'Изображение · {ext}'
        if dim:
            label += f' · {dim}'
        if size:
            label += f' · {size}'
        label = html.escape(label)
        if ext in {'png', 'jpg', 'jpeg', 'webp', 'gif', 'bmp'}:
            img = image_path(item_id, ext)
            if img is not None:
                return f'img:{img}:text:󰋩  {label}'
        return f'󰋩  {label}'
    return '󰈙  ' + html.escape(preview)


def build_menu():
    actions = [('noop', None)]
    lines = ['<span foreground="#fb4934" weight="bold">󰆴  Очистить историю</span>']
    actions[0] = ('clear', None)
    for raw in cliphist_lines():
        line = display_line(raw)
        if line is not None:
            lines.append(line)
            actions.append(('clip', raw))
    return lines, actions


def wofi_pick(lines, prompt):
    cmd = [
        'wofi', '--dmenu',
        '--conf', str(WOFI_CONF),
        '--style', str(WOFI_STYLE),
        '--prompt', prompt,
        '--width', '680',
        '--height', '520',
        '--allow-images',
        '--allow-markup',
        '--insensitive',
        '--define', 'print_line_num=true',
        '--define', 'parse_action=true',
    ]
    res = subprocess.run(cmd, input=('\n'.join(lines) + '\n').encode(),
                         stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, check=False)
    out = res.stdout.decode('utf-8', 'replace').strip()
    if res.returncode != 0 or not out.isdigit():
        return None
    return int(out)


def clear_history():
    lines = [
        '<span weight="bold">Отмена</span>',
        '<span foreground="#fb4934" weight="bold">󰆴  Очистить всю историю</span>',
    ]
    if wofi_pick(lines, 'Очистить историю буфера?') != 1:
        return
    subprocess.run(['cliphist', 'wipe'], stdout=subprocess.DEVNULL,
                   stderr=subprocess.DEVNULL, check=False)
    shutil.rmtree(CACHE, ignore_errors=True)
    notify('Буфер обмена', 'История очищена')


def copy_and_paste(raw):
    res = subprocess.run(['cliphist', 'decode'], input=(raw + '\n').encode(),
                         stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, check=False)
    if res.returncode != 0:
        notify('Буфер обмена', 'Не удалось прочитать элемент истории')
        return

    copy = subprocess.run(['wl-copy'], input=res.stdout, stdout=subprocess.DEVNULL,
                          stderr=subprocess.DEVNULL, check=False)
    if copy.returncode != 0:
        notify('Буфер обмена', 'Не удалось скопировать элемент')
        return

    time.sleep(0.15)
    subprocess.run(['hyprctl', 'dispatch', 'hl.dsp.send_shortcut({ mods = "SHIFT", key = "Insert" })'],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)


def main():
    if len(sys.argv) > 1 and sys.argv[1] in ('--daemon', 'daemon'):
        return 0 if ensure_daemon() else 1
    if not ensure_daemon():
        return 1

    lines, actions = build_menu()
    if len(actions) == 1:
        lines.append('История пока пуста')
        actions.append(('noop', None))

    picked = wofi_pick(lines, 'Буфер обмена')
    if picked is None or picked >= len(actions):
        return 0
    action, raw = actions[picked]
    if action == 'clear':
        clear_history()
    elif action == 'clip' and raw is not None:
        copy_and_paste(raw)
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
