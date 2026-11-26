#!/usr/bin/env bash
set -u

STEP=5
runtime="${XDG_RUNTIME_DIR:-/tmp}"
cache="$runtime/monitor-brightness.cache"
target_file="$runtime/monitor-brightness.targets"
lock_file="$runtime/monitor-brightness.lock"
applied_file="$runtime/monitor-brightness.applied"
fast_ddc=(--noverify --skip-ddc-checks --maxtries 1,1,1 --disable-dynamic-sleep --sleep-multiplier 0.1)

write_cache() {
    tmp="$cache.$$"
    {
        printf 'ts %s\n' "$(date +%s)"
        for i in "${!displays[@]}"; do
            printf 'display %s\nvalue %s\n' "${displays[$i]}" "${values[$i]}"
        done
    } > "$tmp"
    mv "$tmp" "$cache"
}

read_cache() {
    max_age="${1:-5}"
    [[ -f "$cache" ]] || return 1
    ts="$(awk '$1=="ts"{print $2; exit}' "$cache")"
    [[ "$ts" =~ ^[0-9]+$ ]] || return 1
    if ((max_age > 0)); then
        now="$(date +%s)"
        ((now - ts < max_age)) || return 1
    fi

    mapfile -t displays < <(awk '$1=="display"{print $2}' "$cache")
    mapfile -t values < <(awk '$1=="value"{print $2}' "$cache")
    ((${#displays[@]})) || return 1
    ((${#displays[@]} == ${#values[@]})) || return 1
}

detect_displays() {
    mapfile -t displays < <(
        ddcutil detect 2>/dev/null | awk '
            /^Display [0-9]+/ { found=1 }
            found && /I2C bus:/ {
                bus=$3
                sub("/dev/i2c-", "", bus)
                print bus
                found=0
            }
        '
    )
    ((${#displays[@]}))
}

read_values() {
    tmpdir="$(mktemp -d)"
    for d in "${displays[@]}"; do
        (
            v="$(ddcutil --bus "$d" getvcp 10 2>/dev/null | sed -nE 's/.*current value = *([0-9]+).*/\1/p' | head -n1)"
            printf '%s\n' "${v:-0}" > "$tmpdir/$d"
        ) &
    done
    wait

    values=()
    for d in "${displays[@]}"; do
        values+=("$(cat "$tmpdir/$d" 2>/dev/null || printf 0)")
    done
    rm -rf "$tmpdir"
    write_cache
}

calc_average() {
    sum=0
    for v in "${values[@]}"; do sum=$((sum + v)); done
    average=$(((sum + ${#values[@]} / 2) / ${#values[@]}))
}

emit_json() {
    if ((average < 34)); then icon='󰃞'
    elif ((average < 67)); then icon='󰃟'
    else icon='󰃠'
    fi

    tooltip=''
    for i in "${!displays[@]}"; do
        tooltip+="Display ${displays[$i]}: ${values[$i]}%"
        ((i + 1 < ${#displays[@]})) && tooltip+='\n'
    done
    printf '{"text":"%s %d%%","tooltip":"%s"}\n' "$icon" "$average" "$tooltip"
}

write_targets() {
    tmp="$target_file.$$"
    : > "$tmp"
    for i in "${!displays[@]}"; do
        printf '%s %s\n' "${displays[$i]}" "${targets[$i]}" >> "$tmp"
    done
    mv "$tmp" "$target_file"
}

read_targets() {
    [[ -f "$target_file" ]] || return 1
    targets=()
    for d in "${displays[@]}"; do
        t="$(awk -v d="$d" '$1==d{print $2; exit}' "$target_file")"
        [[ "$t" =~ ^[0-9]+$ ]] || return 1
        targets+=("$t")
    done
}

clamp_targets() {
    delta="$1"
    for i in "${!targets[@]}"; do
        t=$((targets[i] + delta))
        ((t < 0)) && t=0
        ((t > 100)) && t=100
        targets[i]="$t"
    done
}

raw_write_targets() {
    pairs=()
    for i in "${!displays[@]}"; do
        pairs+=("${displays[$i]}:${targets[$i]}")
    done

    if python3 - "${pairs[@]}" >/dev/null 2>&1 <<'PY'
import ctypes
import fcntl
import os
import sys

I2C_RDWR = 0x0707

class I2CMsg(ctypes.Structure):
    _fields_ = [
        ('addr', ctypes.c_uint16),
        ('flags', ctypes.c_uint16),
        ('len', ctypes.c_uint16),
        ('buf', ctypes.POINTER(ctypes.c_uint8)),
    ]

class I2CRdwrData(ctypes.Structure):
    _fields_ = [
        ('msgs', ctypes.POINTER(I2CMsg)),
        ('nmsgs', ctypes.c_uint32),
    ]

def write(bus, value):
    value = max(0, min(100, int(value)))
    payload = [0x51, 0x84, 0x03, 0x10, (value >> 8) & 0xff, value & 0xff]
    checksum = 0x6e
    for byte in payload:
        checksum ^= byte
    data = bytes(payload + [checksum])
    buf = (ctypes.c_uint8 * len(data)).from_buffer_copy(data)
    msg = I2CMsg(0x37, 0, len(data), buf)
    msgs = (I2CMsg * 1)(msg)
    rdwr = I2CRdwrData(msgs, 1)
    fd = os.open(f'/dev/i2c-{bus}', os.O_RDWR)
    try:
        fcntl.ioctl(fd, I2C_RDWR, rdwr)
    finally:
        os.close(fd)

ok = True
for arg in sys.argv[1:]:
    bus, value = arg.split(':', 1)
    try:
        write(bus, value)
    except OSError:
        ok = False

sys.exit(0 if ok else 1)
PY
    then
        return 0
    fi

    for i in "${!displays[@]}"; do
        ddcutil "${fast_ddc[@]}" --bus "${displays[$i]}" setvcp 10 "${targets[$i]}" >/dev/null 2>&1 &
    done
    wait
}

show_osd() {
    progress="$(awk -v a="$average" 'BEGIN { printf "%.2f", a / 100 }')"
    swayosd-client --custom-message "Brightness ${average}%" \
        --custom-icon display-brightness-symbolic \
        --custom-progress "$progress" >/dev/null 2>&1 &
}

spawn_worker() {
    nohup "$0" _worker >/dev/null 2>&1 &
}

worker() {
    exec 9>"$lock_file"
    flock 9

    [[ -f "$target_file" ]] || exit 0
    mapfile -t displays < <(awk '{print $1}' "$target_file")
    ((${#displays[@]})) || exit 0

    sleep 0.03
    while [[ -f "$target_file" ]]; do
        fingerprint="$(cat "$target_file" 2>/dev/null || true)"
        [[ -n "$fingerprint" ]] || break
        [[ "$fingerprint" == "$(cat "$applied_file" 2>/dev/null || true)" ]] && break
        read_targets || break

        raw_write_targets

        values=("${targets[@]}")
        calc_average
        write_cache
        show_osd
        pkill -RTMIN+8 waybar 2>/dev/null || true
        printf '%s' "$fingerprint" > "$applied_file.$$"
        mv "$applied_file.$$" "$applied_file"
        sleep 0.05
    done
}

ensure_values() {
    max_age="${1:-5}"
    if ! read_cache "$max_age"; then
        detect_displays || exit 0
        read_values
    fi
    calc_average
}

case "${1:-get}" in
    get)
        ensure_values
        emit_json
        ;;
    up|down)
        ensure_values 0
        if read_targets; then
            :
        else
            targets=("${values[@]}")
        fi
        if [[ "$1" == up ]]; then delta="$STEP"; else delta="-$STEP"; fi
        clamp_targets "$delta"
        write_targets
        values=("${targets[@]}")
        calc_average
        write_cache
        pkill -RTMIN+8 waybar 2>/dev/null || true
        spawn_worker
        ;;
    sync)
        ensure_values 0
        targets=()
        for _ in "${displays[@]}"; do targets+=("$average"); done
        write_targets
        values=("${targets[@]}")
        calc_average
        write_cache
        pkill -RTMIN+8 waybar 2>/dev/null || true
        spawn_worker
        ;;
    _worker)
        worker
        ;;
esac
