#!/usr/bin/env python3
"""QMP build supervisor: watches the guest display via QMP screendumps,
detects the firmware boot-chain wedge, and auto-resets the VM to unwedge
the build.

The wedge: on KVM/ARM64 hosts, after a guest reboot the Windows boot
chain occasionally spins forever right after the firmware starts
bootmgfw.efi - the display freezes on the firmware debug console
(black background, white text), two vCPUs busy-poll, and the build disk
goes silent (observed 2026-09-29 across multiple runs, roughly 1-in-4
guest reboots, at random reboot boundaries - it is a host-level
virtualization race, not an image or script problem). A QMP
system_reset re-enters the boot and usually lands a healthy boot, so
this supervisor automates that lever.

Wedge detection - ALL must hold (the arming + signature checks are
what prevent false resets during healthy phases):
  - the detector is ARMED: the build disk has been written at least
    once. Early-boot phases (firmware POST, the cdboot "press any key"
    prompt) are legitimately static with an untouched disk, and the
    wedge only ever occurs at a setup REBOOT - by which point the
    install has written GBs. Without arming, the prompt screen looks
    exactly like the wedge and the reset budget gets burned on it.
  - the display is static for STATIC_THRESHOLD consecutive dumps
  - the screen matches the firmware-text signature: black-dominant,
    low distinct color count (the firmware console / boot prompt class;
    animated Windows boot and setup screens are excluded)
  - the build disk has not been written for DISK_IDLE_THRESHOLD seconds

Auto-resets are bounded to MAX_RESETS per RESET_WINDOW so a genuinely
broken boot cannot reset-loop forever.

Usage (run from the packer build directory, alongside a build):
  python3 scripts/qmp-supervisor.py                 # watch + auto-heal
  python3 scripts/qmp-supervisor.py --reset          # one-shot reset
  python3 scripts/qmp-supervisor.py --disk PATH --interval 15
"""
import argparse
import collections
import glob
import hashlib
import json
import os
import socket
import struct
import sys
import time
import zlib

SOCK = '/tmp/packer-qmp.sock'
OUT = '/tmp/vm-screen'
LOG = '/tmp/qmp-watch.log'
DEFAULT_DISK = 'output/windows11-arm64-1.0.0/windows11-arm64-golden.qcow2'

STATIC_THRESHOLD = 6       # consecutive identical dumps (~90s at 15s)
DISK_IDLE_THRESHOLD = 90   # seconds without a disk write
MAX_RESETS = 3             # auto-resets allowed per window
RESET_WINDOW = 3600        # seconds


def log(msg):
    stamp = time.strftime('%H:%M:%S')
    with open(LOG, 'a') as f:
        f.write(f'{stamp} {msg}\n')
    print(f'[{stamp}] {msg}', flush=True)


def connect():
    for _ in range(300):
        if os.path.exists(SOCK):
            try:
                s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                s.connect(SOCK)
                s.settimeout(5)
                s.recv(65536)  # QMP greeting
                s.sendall(json.dumps({'execute': 'qmp_capabilities'}).encode() + b'\n')
                time.sleep(0.3)
                try:
                    s.recv(65536)
                except socket.timeout:
                    pass
                return s
            except OSError:
                pass
        time.sleep(1)
    return None


def qmp(s, cmd, args=None):
    payload = {'execute': cmd}
    if args:
        payload['arguments'] = args
    s.sendall(json.dumps(payload).encode() + b'\n')
    time.sleep(0.4)
    out = b''
    try:
        while True:
            d = s.recv(65536)
            if not d:
                break
            out += d
    except socket.timeout:
        pass
    return out.decode(errors='replace')


def parse_ppm(path):
    """Return (width, height, raw_rgb_bytes) from a P6 PPM screendump."""
    with open(path, 'rb') as f:
        data = f.read()
    parts = data.split(b'\n', 3)
    if parts[0].strip() != b'P6':
        return None, None, None
    w, h = map(int, parts[1].split())
    maxv = int(parts[2])
    raw = parts[3][:w * h * 3]
    if maxv != 255:
        raw = bytes((b * 255) // maxv for b in raw)
    return w, h, raw


def firmware_text_signature(path):
    """True when the screen looks like the firmware text console/boot
    prompt: black-dominant with a low distinct color count. Windows boot
    and setup screens are animated and/or blue, so they never match."""
    w, h, raw = parse_ppm(path)
    if not w:
        return False
    px = [tuple(raw[i:i + 3]) for i in range(0, len(raw), 3)]
    counts = collections.Counter(px)
    top, n = counts.most_common(1)[0]
    black_pct = 100.0 * n / len(px)
    return top == (0, 0, 0) and black_pct >= 90.0 and len(counts) <= 200


def ppm2png(src, dst):
    w, h, raw = parse_ppm(src)
    if not w:
        return False
    def chunk(typ, d):
        c = struct.pack('>I', len(d)) + typ + d
        return c + struct.pack('>I', zlib.crc32(typ + d) & 0xffffffff)
    scan = b''.join(b'\x00' + raw[y * w * 3:(y + 1) * w * 3] for y in range(h))
    png = (b'\x89PNG\r\n\x1a\n'
           + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0))
           + chunk(b'IDAT', zlib.compress(scan, 9))
           + chunk(b'IEND', b''))
    with open(dst, 'wb') as f:
        f.write(png)
    return True


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--reset', action='store_true', help='one-shot system_reset and exit')
    ap.add_argument('--disk', default=DEFAULT_DISK, help='build qcow2 to watch for writes')
    ap.add_argument('--interval', type=int, default=15, help='screendump interval in seconds')
    opts = ap.parse_args()

    s = connect()
    if s is None:
        print('no QMP socket at ' + SOCK)
        sys.exit(1)

    if opts.reset:
        r = qmp(s, 'system_reset')
        log('MANUAL system_reset -> ' + r.strip()[:200])
        sys.exit(0)

    os.makedirs(OUT, exist_ok=True)
    log(f'connected to QMP; supervising (interval {opts.interval}s, disk {opts.disk}, '
        f'wedge = ARMED-on-first-disk-write + static>={STATIC_THRESHOLD} dumps + firmware-text + '
        f'disk idle>={DISK_IDLE_THRESHOLD}s, max {MAX_RESETS} resets/{RESET_WINDOW}s)')

    prev_hash = None
    static_run = 0
    n = 0
    resets = []
    disk_baseline = None
    disk_armed = False

    while True:
        n += 1
        ts = time.strftime('%H%M%S')
        ppm = f'{OUT}/screen-{ts}-{n:04d}.ppm'

        try:
            qmp(s, 'screendump', {'filename': ppm})
        except Exception as e:
            log(f'QMP error on screendump: {e}; exiting')
            sys.exit(0)

        state = 'no-file'
        screen_is_fw_text = False
        if os.path.exists(ppm):
            digest = hashlib.sha256(open(ppm, 'rb').read()).hexdigest()
            if digest == prev_hash:
                static_run += 1
                state = 'static'
            else:
                static_run = 0
                state = 'CHANGED'
            prev_hash = digest

            # The signature must be evaluated on the PPM screendump BEFORE
            # it is deleted below: firmware_text_signature parses P6 PPM
            # data, and feeding it the converted PNG always returned False,
            # so the wedge detector silently never fired (observed
            # 2026-09-30: a wedged boot sat for 6+ minutes with zero
            # auto-resets and had to be reset by hand).
            if static_run >= STATIC_THRESHOLD:
                screen_is_fw_text = firmware_text_signature(ppm)

            png = ppm[:-4] + '.png'
            try:
                ppm2png(ppm, png)
            except Exception as e:
                log(f'ppm2png fail: {e}')
            os.remove(ppm)
        else:
            prev_hash = None
            static_run = 0

        # Arm the wedge detector only after the build disk has been
        # written at least once: early-boot phases (firmware POST, the
        # cdboot prompt) are legitimately static with an untouched disk,
        # and the wedge can only occur at a setup REBOOT - by which point
        # the install has written GBs.
        if not disk_armed and os.path.exists(opts.disk):
            try:
                mtime = os.path.getmtime(opts.disk)
                if disk_baseline is None:
                    disk_baseline = mtime
                elif mtime > disk_baseline:
                    disk_armed = True
                    log('first build-disk write observed - wedge detector armed')
            except OSError:
                pass

        disk_note = ''
        wedge = False
        if disk_armed and static_run >= STATIC_THRESHOLD:
            try:
                idle = time.time() - os.path.getmtime(opts.disk)
            except OSError:
                idle = None
            if idle is not None and idle >= DISK_IDLE_THRESHOLD:
                if screen_is_fw_text:
                    wedge = True
                    disk_note = f' disk_idle={int(idle)}s'

        log(f'dump {n:04d}: {state} static_run={static_run}{disk_note}')

        if wedge:
            resets = [t for t in resets if time.time() - t < RESET_WINDOW]
            if len(resets) < MAX_RESETS:
                try:
                    qmp(s, 'system_reset')
                    resets.append(time.time())
                    log(f'AUTO system_reset (boot-chain wedge: static={static_run} dumps, '
                        f'disk idle>={DISK_IDLE_THRESHOLD}s, firmware-text screen; '
                        f'reset {len(resets)}/{MAX_RESETS} in window)')
                    prev_hash = None
                    static_run = 0
                except Exception as e:
                    log(f'AUTO reset failed: {e}')
            else:
                log('wedge persists and reset budget exhausted; NOT resetting')

        for old in sorted(glob.glob(f'{OUT}/screen-*.png'))[:-80]:
            os.remove(old)

        time.sleep(opts.interval)


if __name__ == '__main__':
    main()
