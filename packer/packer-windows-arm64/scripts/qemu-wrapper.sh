#!/usr/bin/env bash
# qemu-wrapper.sh — wraps qemu-system-aarch64 for Packer on ARM virt.
#
# Packer's qemu plugin treats `qemuargs` as a *replacement* for all auto-
# generated args, not an append. Instead of qemuargs, we use this wrapper
# as `qemu_binary`: Packer invokes us as if we were qemu, we forward every
# arg verbatim with surgical edits and append our additions.
#
# What we do:
# 1. Rewrite every Packer-generated `-drive ...,media=cdrom` to usb-storage
#    form. ARM `virt` has no IDE/SATA controller, so Packer's default CD
#    attachment is invisible to the firmware. WinPE's in-box xHCI stack
#    can read usb-storage CDs immediately.
# 2. Add qemu-xhci USB controller + usb-kbd + usb-tablet. Without these,
#    Packer's VNC keystroke injection goes nowhere (no input device in VM).
# 3. Add ramfb. ARM `virt` ships no graphics card; without ramfb the display
#    shows only the QEMU monitor console, not the VM screen.
# 4. TPM 2.0 via swtpm + tpm-tis-device (ARM variant). Windows 11's hardware
#    check fires before LabConfig RunSynchronous runs, so a real vTPM is
#    needed for Windows to detect TPM 2.0 and pass the check natively.
# 5. Serial output to /tmp/packer-serial.log for firmware/WinPE diagnosis.
# 6. Attach virtio-win ISO as a third usb-storage CD for manual driver
#    installation (full driver set incl. co-installer .exe files).
# 7. Second qemu-xhci controller (usb2): qemu-xhci exposes a single usb.0
#    bus, and once its ports are used QEMU silently auto-inserts a 12 Mb/s
#    full-speed hub for extra devices. MSDs behind that hub enumerate so
#    slowly in firmware that the setup ISO's cdboot "Press any key" prompt
#    lands outside Packer's boot_command window; cdboot then resets the VM,
#    the retry times out, and the firmware falls through to PXE. Extra CDs
#    go on the second controller's fast root ports instead.
#
# Adapted from bbirkinbine/mac-vms scripts/qemu-with-tpm.sh for Linux/KVM.

set -euo pipefail

# ---- start swtpm for TPM 2.0 (Win11 requirement) ----
# Packer's plugin hardcodes x86 `tpm-tis` (invalid on ARM); we use the
# ARM variant `tpm-tis-device` instead. swtpm runs in the background;
# we clean it up when qemu exits.
SWTPM_DIR=$(mktemp -d /tmp/swtpm-XXXXXX)
SWTPM_SOCK="${SWTPM_DIR}/swtpm-sock"
swtpm socket --tpm2 --daemon \
  --tpmstate dir="${SWTPM_DIR}" \
  --ctrl type=unixio,path="${SWTPM_SOCK}"

# Wait for swtpm socket to be ready before launching QEMU
for i in $(seq 1 20); do
  [[ -S "${SWTPM_SOCK}" ]] && break
  sleep 0.1
done
[[ -S "${SWTPM_SOCK}" ]] || { echo "ERROR: swtpm socket never appeared" >&2; exit 1; }

cleanup() {
  pkill -f "${SWTPM_SOCK}" 2>/dev/null || true
  rm -rf "${SWTPM_DIR}"
}
trap cleanup EXIT

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
      # First Packer CD is the Windows setup ISO: keep it on usb.0 next to
      # the input devices (attaches at SuperSpeed on port 3). Any further CD
      # goes to the second controller (usb2.0) — on the same bus it would be
      # pushed behind QEMU's auto-inserted 12 Mb/s full-speed hub, which
      # delays firmware boot enumeration past Packer's boot_command window
      # and regresses the boot to PXE (observed 2026-09-29).
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
    fi
  fi
  rewritten_args+=("$arg")
  i=$((i + 1))
done

# Bus extras MUST come before device_appends so the USB bus exists first.
bus_extras=(
  -device "qemu-xhci,id=usb"
  -device "qemu-xhci,id=usb2"
  -device "usb-kbd,bus=usb.0"
  -device "usb-tablet,bus=usb.0"
  -device "ramfb"
  -device "uefi-vars-sysbus"
  -chardev "socket,id=chrtpm,path=${SWTPM_SOCK}"
  -tpmdev "emulator,id=tpm0,chardev=chrtpm"
  -device "tpm-tis-device,tpmdev=tpm0"
  -serial "file:/tmp/packer-serial.log"
  # QMP socket for build supervision: guest-display screendumps and a
  # remote system_reset lever for stalled boots (Packer itself never uses
  # it; it drives VNC as usual).
  -qmp "unix:/tmp/packer-qmp.sock,server,nowait"
)

final_argv=(
  "${rewritten_args[@]}"
  "${bus_extras[@]}"
  "${device_appends[@]}"
  # VirtIO-win ISO as third usb-storage CD, on the second controller so it
  # never lands behind the auto-inserted full-speed hub (see header note 7).
  -drive "file=/home/david/code/gitea/packer_demo/files/virtio-win-0.1.302.iso,media=cdrom,if=none,id=cd-virtio-win"
  -device "usb-storage,drive=cd-virtio-win,bus=usb2.0"
)

# Log final invocation for debugging
{
  echo "==> $(date -u +%FT%TZ) qemu-system-aarch64 invocation"
  printf ' %q\n' qemu-system-aarch64 "${final_argv[@]}"
} >/tmp/qemu-wrapper.cmd.log 2>/dev/null || true

# Run qemu (not exec) so our trap cleans up swtpm on exit
qemu-system-aarch64 "${final_argv[@]}"
QEMU_EXIT=$?
cleanup
exit $QEMU_EXIT
