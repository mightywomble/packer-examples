# packer_demo

Reproducible Windows 11 ARM64 "golden image" built with Packer on QEMU/KVM
(Asahi / Apple Silicon aarch64 host).

## What this produces

A Sysprep-generalized QCOW2 disk image plus a VMware-format VMDK candidate,
with validation evidence and checksums — all generated from version-controlled
code. The pipeline demonstrates repeatability, policy-as-code, controlled-failure
validation, identity generalisation (Sysprep), and release evidence.

## Repository layout

```
packer_demo/
├── files/                         # Source media (gitignored — large)
│   ├── Win11_25H2_English_Arm64_v2.iso
│   └── virtio-win-0.1.302.iso
├── packer/
│   ├── scope.txt                  # Original build scope / steps
│   └── packer-windows-arm64/
│       ├── windows11-arm64.pkr.hcl          # Packer build config
│       ├── variables.pkr.hcl                # Variable declarations
│       ├── windows11-arm64.auto.pkrvars.hcl # Values (gitignored — holds password)
│       ├── answer-files/Autounattend.xml    # ARM64 Win11 Pro unattend
│       ├── scripts/
│       │   ├── qemu-wrapper.sh              # QEMU wrapper (CD-ROM→usb-storage, ramfb, usb-kbd)
│       │   ├── 00-bootstrap-winrm.ps1       # WinRM bootstrap for Packer
│       │   ├── 10-install-software.ps1      # Chocolatey + Google Chrome + Notepad++ install
│       │   ├── 20-apply-policies.ps1        # PS logging, audit, banner, disable SMB1/Guest
│       │   ├── 30-enable-features.ps1       # OpenSSH, RDP, Defender, event-log sizing
│       │   ├── 40-validate-image.ps1        # Validation gate (throws on failure)
│       │   ├── 80-cleanup.ps1               # Temp/DISM cleanup, zero free space
│       │   └── 90-sysprep.ps1              # Sysprep generalize + shutdown
│       ├── drivers/viostor/                 # ARM64 viostor driver (extracted from virtio-win)
│       ├── drivers/NetKVM/                  # ARM64 NetKVM driver (extracted from virtio-win)
│       ├── reports/                          # Build validation reports
│       └── output/                           # Build artifacts (gitignored)
└── .gitignore
```

## Architecture

### QEMU wrapper script

Packer's QEMU plugin has several ARM64 `virt` incompatibilities that require a
wrapper script (`scripts/qemu-wrapper.sh`) set as `qemu_binary`:

1. **CD-ROM bus**: ARM `virt` has no IDE/SATA controller. Packer's default
   `media=cdrom` attachment is invisible to the firmware. The wrapper rewrites
   every `-drive ...,media=cdrom` to `usb-storage` form, which WinPE's in-box
   xHCI stack can read immediately.

2. **No graphics device**: ARM `virt` ships no GPU. Without `ramfb` the display
   shows only the QEMU monitor console, not the VM screen. The wrapper adds
   `-device ramfb`.

3. **No input devices**: Without `usb-kbd`, Packer's VNC keystroke injection
   goes nowhere. The wrapper adds `qemu-xhci` + `usb-kbd` + `usb-tablet`.

4. **`qemuargs` replaces, not appends**: Packer's `qemuargs` config replaces all
   auto-generated args entirely. The wrapper approach forwards Packer's args and
   surgically appends instead.

### EFI firmware

Uses edk2-aarch64 UEFI firmware (non-Secure-Boot variant) from
`/usr/share/edk2/aarch64/QEMU_EFI-silent-pflash.raw`.

### No vTPM

The Packer QEMU plugin v1.1.6 hardcodes the x86 `tpm-tis` device, which is
invalid on ARM `virt`. Windows 11 TPM/SecureBoot checks are bypassed via
`LabConfig` registry keys in `Autounattend.xml` (windowsPE pass).

### VirtIO drivers

ARM64 viostor + NetKVM drivers are extracted from the virtio-win ISO and bundled
into the unattend CD via `cd_files`. WinPE loads them via
`PnpCustomizationsWinPE` before the disk probe. Driver paths reference multiple
drive letters (D:–G:) because ARM64+EFI drive enumeration is non-deterministic.

### Boot

The Windows installer's "Press any key to boot from CD or DVD" prompt is hit
by spamming `<spacebar>` via Packer's VNC keystroke channel. USB enumeration
order (enforced by the wrapper) puts the install ISO first so EDK2 finds
`bootaa64.efi` immediately.

## Prerequisites

- Arch Linux ARM (aarch64) with Asahi kernel
- `qemu-desktop`, `libvirt`, `swtpm`, `cdrtools`, `qemu-img`, `jq`, `openssl`,
  `wimlib`, `7zip`, `packer`
- edk2-aarch64 UEFI firmware at `/usr/share/edk2/aarch64/`
- KVM available (`/dev/kvm`)
- Windows 11 ARM64 ISO + virtio-win ISO in `files/`

## Build

```bash
cd packer/packer-windows-arm64
packer init .
packer fmt -recursive .
packer validate .

# Iterate (GUI, pauses on error):
PACKER_LOG=1 packer build -on-error=ask .

# Automated (headless):
packer build -var headless=true .
```

## Post-build

```bash
qemu-img info output/windows11-arm64-1.0.0/windows11-arm64-golden.qcow2

qemu-img convert -p -f qcow2 -O vmdk -o subformat=streamOptimized \
  output/windows11-arm64-1.0.0/windows11-arm64-golden.qcow2 \
  output/windows11-arm64-1.0.0/windows11-arm64-golden.vmdk

cd output/windows11-arm64-1.0.0
sha256sum windows11-arm64-golden.qcow2 windows11-arm64-golden.vmdk > SHA256SUMS
```

The VMDK is a **VMware-format candidate**, not a production template
(ESXi-Arm doesn't support W11 ARM guest customisation).

## Status

Build config is validated and QEMU launches successfully with the wrapper
script. Windows boots from ISO via usb-storage CD + ramfb display. The
unattended install (Autounattend.xml with locale settings, LabConfig bypass,
VirtIO driver injection, WinRM bootstrap) is being iterated on.

See `packer/scope.txt` for the original build scope (Steps 5–12).
