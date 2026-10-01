#!/usr/bin/env python3
"""Exec argv with PR_SET_PDEATHSIG=SIGKILL.

Used by scripts/qemu-wrapper.sh to launch qemu-system-aarch64 and swtpm:
if the wrapper (the parent) dies for ANY reason - including an untrappable
SIGKILL from Packer's build teardown - the kernel immediately kills this
process too. This is the bulletproof version of teardown: an EXIT/TERM
trap in the wrapper did not prevent leaks (observed 2026-09-29/30: a
leaked QEMU + swtpm outlived their errored build for minutes after the
build had already deleted its output directory), because a kill that
bypasses the trap orphans the foreground/background children. PDEATHSIG
is set before execve and survives execve; it is cleared on fork, so
swtpm must NOT be started with --daemon (the daemonizing fork would drop
the protection) - the wrapper runs it in the background instead.
"""
import ctypes
import os
import signal
import sys

PR_SET_PDEATHSIG = 1

libc = ctypes.CDLL(None, use_errno=True)
if libc.prctl(PR_SET_PDEATHSIG, ctypes.c_ulong(signal.SIGKILL)) != 0:
    print('pdeathsig-exec: prctl(PR_SET_PDEATHSIG) failed', file=sys.stderr)
    sys.exit(1)

if len(sys.argv) < 2:
    print('usage: pdeathsig-exec.py COMMAND [ARGS...]', file=sys.stderr)
    sys.exit(1)

os.execvp(sys.argv[1], sys.argv[1:])
