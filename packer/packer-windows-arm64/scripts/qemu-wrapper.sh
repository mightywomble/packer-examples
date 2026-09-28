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
#
# No TPM: the Packer QEMU plugin hardcodes x86 `tpm-tis` (invalid on ARM).
# Windows 11 TPM/SecureBoot checks are bypassed via LabConfig in Autounattend.
#
# Adapted from bbirkinbine/mac-vms scripts/qemu-with-tpm.sh for Linux/KVM.

set -euo pipefail

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
      cd_id="cd-pkr-${cd_counter}"
      cd_counter=$((cd_counter + 1))
      rewritten_args+=("-drive" "${stripped},if=none,id=${cd_id}")
      device_appends+=("-device" "usb-storage,drive=${cd_id},bus=usb.0")
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
  -device "usb-kbd,bus=usb.0"
  -device "usb-tablet,bus=usb.0"
  -device "ramfb"
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

exec qemu-system-aarch64 "${final_argv[@]}"
