#!/usr/bin/env bash
# qemu-wrapper.sh - wraps qemu-system-aarch64 for Packer on ARM virt.
# (Ubuntu build; adapted from ../packer-windows-arm64/scripts/qemu-wrapper.sh)
#
# Packer's qemu plugin treats `qemuargs` as a *replacement* for all auto-
# generated args, not an append. Instead of qemuargs, we use this wrapper
# as `qemu_binary`: Packer invokes us as if we were qemu, we forward every
# arg verbatim with surgical edits and append our additions.
#
# What we do:
# 1. Rewrite every Packer-generated `-drive ...,media=cdrom` to usb-storage
#    form. ARM `virt` has no IDE/SATA controller, so Packer's default CD
#    attachment is invisible to the firmware. CD 0 is the live-server ISO,
#    CD 1 is the cidata autoinstall seed (see note 3 for bus placement).
# 2. Add qemu-xhci USB controllers + usb-kbd + usb-tablet. Without these,
#    Packer's VNC keystroke injection goes nowhere (no input device in VM).
# 3. Second qemu-xhci controller (usb2): the first CD stays on usb.0 next
#    to the input devices; extra CDs go on usb2.0's root ports so they
#    never land behind QEMU's auto-inserted 12 Mb/s full-speed hub, which
#    delays firmware enumeration past Packer's boot window (observed
#    2026-09-29 on the Windows build).
# 4. Add ramfb. ARM `virt` ships no graphics card; without it the display
#    shows only the QEMU monitor console, not the VM screen.
# 5. Serial output to /tmp/packer-serial.log for install diagnosis, and a
#    QMP socket at /tmp/packer-qmp.sock for build supervision (screendumps,
#    system_reset lever) - Packer itself never uses it.
# 6. Run QEMU in the background under scripts/pdeathsig-exec.py
#    (PR_SET_PDEATHSIG): the kernel kills QEMU the instant this wrapper
#    dies, however it dies. Packer's teardown signal is untrappable, and
#    without this a build error orphaned the VM for hours (observed
#    2026-09-29 on the Windows build).
# 7. Rewrite the main build disk (Packer's -drive if=virtio) to an
#    explicit virtio-blk-pci device with bootindex=0, so EDK2 boots the
#    installed system (not the still-attached installer CD) on every
#    reboot after the install. The installer CD only boots while the disk
#    is empty (first boot), because the CDs keep no bootindex. Direct
#    -kernel boot was tried first (deterministic installer boot, no
#    keystrokes) but the fw_cfg kernel always wins over boot entries, so
#    the post-install reboot re-ran the installer in a loop (observed
#    2026-10-01: 5 boots, ~450s each).
# 8. Spawn scripts/autoconfirm.py. The installer boots via the ISO's own
#    GRUB default entry (30s menu timeout, no keystrokes - VNC keystroke
#    edits proved timing-fragile on this host across two runs). Without
#    the kernel-cmdline 'autoinstall' token, subiquity then shows one
#    safety prompt - 'Continue with autoinstall? (yes|no)' - when it finds
#    the cidata seed; the watchdog answers it via QMP send-key when the
#    prompt appears in the serial log (proven interactively on 2026-10-01
#    to un-stick a build). The prompt only appears for this build's
#    throwaway VM disk with a valid seed, so auto-answering is safe here.
#
# Unlike the Windows 11 build this was adapted from, plain Ubuntu server
# needs no vTPM and no Secure Boot firmware, so all swtpm/tpm/uefi-vars
# plumbing is dropped.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# Stale-state hygiene: a leftover QMP socket from a previous run makes
# QEMU's -qmp server fail to bind, and a stale serial log confuses
# scripts/autoconfirm.py's new-content tracking.
rm -f /tmp/packer-qmp.sock /tmp/packer-serial.log

# qemu runs in the BACKGROUND with a TERM/INT/EXIT trap that kills it.
# Packer TERMs this wrapper when a build errors or is cancelled, and bash
# does not run the EXIT trap on SIGTERM - running qemu in the foreground
# would orphan it (see header note 6; pdeathsig-exec.py is the real guard).
QEMU_PID=""
WATCHDOG_PID=""
on_exit() {
  if [[ -n "${QEMU_PID}" ]]; then
    kill "${QEMU_PID}" 2>/dev/null || true
  fi
  if [[ -n "${WATCHDOG_PID}" ]]; then
    kill "${WATCHDOG_PID}" 2>/dev/null || true
  fi
}
trap on_exit EXIT TERM INT

rewritten_args=()
device_appends=()
cd_counter=0

args=("$@")
i=0
while (( i < ${#args[@]} )); do
  arg="${args[$i]}"
  if [[ "$arg" == "-drive" ]] && (( i + 1 < ${#args[@]} )); then
    val="${args[$((i + 1))]}"
    if [[ "$val" == *"media=cdrom"* ]]; then
      # Strip if= and index= keys, add if=none with our id
      stripped="$(printf '%s' "$val" \
        | sed -E 's/(^|,)if=[^,]*//g; s/(^|,)index=[^,]*//g; s/^,+//; s/,,+/,/g; s/,$//')"
      # First Packer CD is the Ubuntu live-server ISO: keep it on usb.0
      # next to the input devices (fast root port). Any further CD (the
      # cidata seed) goes to the second controller (usb2.0) so it never
      # lands behind the auto-inserted full-speed hub (header note 3).
      cd_id="cd-pkr-${cd_counter}"
      if (( cd_counter == 0 )); then
        cd_bus="usb.0"
      else
        cd_bus="usb2.0"
      fi
      cd_counter=$((cd_counter + 1))
      rewritten_args+=("-drive" "${stripped},if=none,id=${cd_id}")
      device_appends+=("-device" "usb-storage,drive=${cd_id},bus=${cd_bus}")
      i=$((i + 2))
      continue
    elif [[ "$val" == *"if=virtio"* ]]; then
      # The main build disk (header note 7): rewrite Packer's anonymous
      # if=virtio drive to an explicit virtio-blk device with bootindex=0.
      stripped="$(printf '%s' "$val" \
        | sed -E 's/(^|,)if=[^,]*//g; s/^,+//; s/,,+/,/g; s/,$//')"
      rewritten_args+=("-drive" "${stripped},if=none,id=hd0")
      device_appends+=("-device" "virtio-blk-pci,drive=hd0,bootindex=0")
      i=$((i + 2))
      continue
    fi
  fi
  rewritten_args+=("$arg")
  i=$((i + 1))
done

# Bus extras MUST come before device_appends so the USB buses exist first.
bus_extras=(
  -device "qemu-xhci,id=usb"
  -device "qemu-xhci,id=usb2"
  -device "usb-kbd,bus=usb.0"
  -device "usb-tablet,bus=usb.0"
  -device "ramfb"
  -serial "file:/tmp/packer-serial.log"
  -qmp "unix:/tmp/packer-qmp.sock,server,nowait"
)

final_argv=(
  "${rewritten_args[@]}"
  "${bus_extras[@]}"
  "${device_appends[@]}"
)

# Log final invocation for debugging
{
  echo "==> $(date -u +%FT%TZ) qemu-system-aarch64 invocation"
  printf ' %q\n' qemu-system-aarch64 "${final_argv[@]}"
} >/tmp/qemu-wrapper.cmd.log 2>/dev/null || true

# Auto-confirmation watchdog (header note 8), under pdeathsig like QEMU
# itself: dies whenever this wrapper dies, however it dies.
"${SCRIPT_DIR}/pdeathsig-exec.py" python3 "${SCRIPT_DIR}/autoconfirm.py" &
WATCHDOG_PID=$!

# Run qemu in the background under pdeathsig-exec.py (kernel-killed if
# this wrapper dies however it dies), and hand its exit code through
# (wait returns the child's status; set -e is not triggered because of
# the || capture).
"${SCRIPT_DIR}/pdeathsig-exec.py" qemu-system-aarch64 "${final_argv[@]}" &
QEMU_PID=$!
QEMU_EXIT=0
wait "${QEMU_PID}" || QEMU_EXIT=$?
QEMU_PID=""
exit "${QEMU_EXIT}"
