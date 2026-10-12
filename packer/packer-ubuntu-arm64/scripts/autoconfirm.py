#!/usr/bin/env python3
"""autoconfirm.py - answers subiquity's autoinstall confirmation prompt.

Why this exists (observed 2026-10-01, three runs on this host):
- QEMU direct -kernel boot is deterministic for the installer, but the
  fw_cfg kernel wins over boot entries on EVERY reset, so the
  post-install reboot re-ran the installer in an endless reinstall loop.
- Booting the ISO's GRUB menu and VNC-typing the kernel-line edit is
  timing-fragile here: firmware POST + USB CD enumeration is
  nondeterministic. A ~320s window of inert keystrokes proved the menu
  receives input, but the edit still failed to stick and the default
  entry booted unedited both times.

The robust path is to let the default entry boot (the ISO's GRUB menu
has its own 30s timeout, no keystrokes needed) and answer the one
interactive gate that remains: subiquity shows 'Continue with
autoinstall? (yes|no)' when it found the cidata seed but the kernel
command line lacks the 'autoinstall' token. This script watches the
guest serial log (/tmp/packer-serial.log) for that prompt and answers
it through QMP send-key on the wrapper's QMP socket
(/tmp/packer-qmp.sock) - the same lever used interactively to salvage
the third run.

The prompt only appears when subiquity has a valid seed and is about to
write to this build's throwaway VM disk, so answering it automatically
is safe in this pipeline. Exits when QEMU goes away (socket vanishes or
send fails). Spawned by qemu-wrapper.sh under pdeathsig-exec.py, so it
dies whenever the wrapper dies, however it dies.
ASCII only (repo rule).
"""
import json
import os
import socket
import sys
import time

SERIAL_LOG = "/tmp/packer-serial.log"
QMP_SOCKET = "/tmp/packer-qmp.sock"
PROMPT = "Continue with autoinstall? (yes|no)"
POLL_SECONDS = 2
ANSWER_DELAY = 5.0  # let the prompt finish rendering before typing
KEY_GAP = 0.4
MAX_ANSWERS = 3
MAX_LIFETIME_MINUTES = 90
SOCKET_WAIT_SECONDS = 120


def qmp_connect():
    s = socket.socket(socket.AF_UNIX)
    s.settimeout(10)
    s.connect(QMP_SOCKET)
    f = s.makefile("rw")
    f.readline()  # greeting

    def cmd(c):
        f.write(json.dumps(c) + "\n")
        f.flush()
        while True:
            line = f.readline()
            if not line:
                raise ConnectionError("QMP connection closed")
            r = json.loads(line)
            if "return" in r or "error" in r:
                return r

    cmd({"execute": "qmp_capabilities"})
    return cmd


def answer(cmd):
    print("answer: typing yes + Enter via QMP send-key", flush=True)
    for key in ("y", "e", "s"):
        cmd({"execute": "send-key",
             "arguments": {"keys": [{"type": "qcode", "data": key}]}})
        time.sleep(KEY_GAP)
    return cmd({"execute": "send-key",
                "arguments": {"keys": [{"type": "qcode", "data": "ret"}]}})


def main():
    deadline = time.time() + SOCKET_WAIT_SECONDS
    while not os.path.exists(QMP_SOCKET):
        if time.time() > deadline:
            print("no QMP socket appeared; exiting", flush=True)
            return 0
        time.sleep(1)
    try:
        cmd = qmp_connect()
    except OSError as e:
        print("QMP connect failed: %s" % e, flush=True)
        return 0
    print("watching %s for the confirmation prompt" % SERIAL_LOG,
          flush=True)

    pos = 0
    answers = 0
    overlap = len(PROMPT) - 1  # handle a prompt split across polls
    end_at = time.time() + MAX_LIFETIME_MINUTES * 60
    while time.time() < end_at:
        time.sleep(POLL_SECONDS)
        try:
            size = os.path.getsize(SERIAL_LOG)
        except OSError:
            continue
        if size < pos:  # log truncated (fresh run): restart from 0
            pos = 0
        if size == pos:
            if not os.path.exists(QMP_SOCKET):
                print("QMP socket gone; QEMU exited. exiting", flush=True)
                return 0
            continue
        try:
            with open(SERIAL_LOG, "r", errors="replace") as fh:
                fh.seek(max(0, pos - overlap))
                new = fh.read()
                pos = fh.tell()
        except OSError:
            continue
        if PROMPT not in new:
            continue
        if answers >= MAX_ANSWERS:
            print("prompt appeared again after %d answers; giving up"
                  % MAX_ANSWERS, flush=True)
            return 1
        time.sleep(ANSWER_DELAY)
        try:
            answer(cmd)
        except (OSError, ConnectionError) as e:
            print("send-key failed (%s); QEMU likely gone" % e,
                  flush=True)
            return 0
        answers += 1
        # Consume everything written so far: the prompt we just answered
        # stays behind pos, so it cannot re-trigger a later answer.
        try:
            pos = os.path.getsize(SERIAL_LOG)
        except OSError:
            pass
        print("answered confirmation prompt (answer %d of max %d)"
              % (answers, MAX_ANSWERS), flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
