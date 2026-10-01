# packer_demo

Reproducible Windows 11 ARM64 "golden image" built with Packer on QEMU/KVM
(Asahi / Apple Silicon aarch64 host).

## What this produces

A Sysprep-generalized QCOW2 disk image, with validation evidence and
checksums - all generated from version-controlled code. The pipeline
demonstrates repeatability, policy-as-code, controlled-failure validation,
identity generalisation (Sysprep), and release evidence.

## Repository layout

```
packer_demo/
├── files/                         # Source media (gitignored - large)
│   ├── Win11_25H2_English_Arm64_v2.iso
│   └── virtio-win-0.1.302.iso
├── packer/
│   ├── scope.txt                  # Original build scope / steps
│   └── packer-windows-arm64/
│       ├── windows11-arm64.pkr.hcl          # Packer build config
│       ├── variables.pkr.hcl                # Variable declarations
│       ├── windows11-arm64.auto.pkrvars.hcl # Values (gitignored - holds password)
│       ├── answer-files/Autounattend.xml    # ARM64 Win11 Pro unattend
│       ├── scripts/
│       │   ├── qemu-wrapper.sh              # QEMU wrapper (USB topology, PDEATHSIG, QMP)
│       │   ├── pdeathsig-exec.py            # Kernel-kills child if wrapper dies (any signal)
│       │   ├── qmp-supervisor.py            # Auto-heal: detect boot wedge, QMP reset
│       │   ├── 00-bootstrap-winrm.ps1        # WinRM bootstrap (first logon, ASCII-only)
│       │   ├── 10-install-software.ps1       # winget: Git + 7-Zip (native ARM64 manifests)
│       │   ├── 20-apply-policies.ps1        # PS logging, audit, banner, disable SMB1/Guest
│       │   ├── 30-enable-features.ps1       # OpenSSH, RDP, Defender, event-log sizing
│       │   ├── 40-validate-image.ps1        # Validation gate (throws on failure)
│       │   ├── 80-cleanup.ps1               # Temp wipes + free-space gate (minimal)
│       │   └── 90-sysprep.ps1               # Sysprep via WMI (detached from task tree)
│       ├── drivers/viostor/                 # ARM64 viostor driver (extracted from virtio-win)
│       ├── drivers/NetKVM/                  # ARM64 NetKVM driver (extracted from virtio-win)
│       ├── reports/                          # Build validation reports
│       └── output/                           # Build artifacts (gitignored)
└── .gitignore
```

## Architecture

The build runs on QEMU/KVM with a custom wrapper script, a QMP auto-healing
supervisor, and a pipeline of PowerShell provisioning scripts. Every layer
exists because of a specific failure mode encountered on this hardware -
see the Troubleshooting Journey below for the full record.

### QEMU wrapper (`scripts/qemu-wrapper.sh`)

Packer's QEMU plugin has several ARM64 `virt` incompatibilities that require
a wrapper script set as `qemu_binary`:

1. **USB topology**: ARM `virt` has no IDE/SATA. Packer's `media=cdrom`
   attachment is invisible to firmware. The wrapper rewrites all CDs to
   `usb-storage`. A second `qemu-xhci` controller (`usb2`) prevents QEMU
   from silently auto-inserting a 12 Mb/s hub that slows enumeration past
   Packer's boot window.

2. **PDEATHSIG teardown** (`scripts/pdeathsig-exec.py`): Packer kills the
   wrapper without a trappable signal on build error. Without PDEATHSIG,
   QEMU and swtpm were orphaned and leaked. `PR_SET_PDEATHSIG` on the child
   makes the kernel kill it the instant the parent dies - however it dies.

3. **vTPM via swtpm**: Windows 11 requires TPM 2.0. The wrapper starts
   `swtpm` and attaches `tpm-tis-device` (the ARM variant).

4. **ramfb + usb-kbd**: Without these, no display or keyboard for Packer's
   VNC keystroke injection.

### QMP auto-healing supervisor (`scripts/qmp-supervisor.py`)

A KVM/ARM64 host-level race wedges the Windows boot chain roughly once per
four guest reboots: the firmware starts `bootmgfw.efi`, then two vCPUs
busy-poll forever, the display freezes on the firmware console, and the
disk goes silent. A QMP `system_reset` re-enters the boot and usually lands
a healthy boot. The supervisor automates this: screendumps the guest display
every 15s, and when it detects the wedge signature (static firmware-text
screen + no build-disk writes for 90s), it auto-resets (bounded to 3/hour).
The detector arms only after the first build-disk write (early-boot phases
are legitimately static with an untouched disk, and the cdboot prompt looks
pixel-identical to the wedge).

### Boot automation

The cdboot "Press any key to boot from CD or DVD" prompt arrives
nondeterministically (5s to 200s+; driven by fresh-swtpm TPM2 RSA keygen).
The boot_command spams `<spacebar>` every 2s for ~600 seconds.

### WinRM bootstrap (first logon)

`Autounattend.xml`'s FirstLogonCommands retry-waits up to 90s for the
unattend CD to get a drive letter (USB CD-ROM letters lag first logon by
seconds), then runs `00-bootstrap-winrm.ps1` which enables WinRM,
sets auth to Basic+unencrypted, and disables the firewall.

### Software installation (winget, native ARM64)

`10-install-software.ps1` waits up to 10 min for App Installer (the image
provisions it asynchronously after first logon), then installs native
ARM64 packages from `microsoft/winget-pkgs` via winget with
`--exact --silent --accept-package-agreements --accept-source-agreements`.
Current packages: `Git.Git` and `7zip.7zip`. Chocolatey was tried first but
its released CLI lacks reliable ARM64 architecture selection.

### Provisioning (elevated)

All PowerShell provisioners run with `elevated_user`/`elevated_password` -
the DISM servicing stack (CBS) rejects the WinRM session's network-logon
token even though it is an admin token (machine-wide MSI installs succeed
in the same session, but `Add-WindowsCapability` errors with "Access is
denied"). The elevated provisioner runs scripts via a scheduled task with
a full elevation token.

### Sysprep (`90-sysprep.ps1`)

Sysprep.exe is launched via **WMI `Win32_Process.Create`** - the only method
that puts it in a process tree no scheduled-task cleanup can touch. Three
previous methods failed: `Start-Process -Wait` (WinRM drops mid-shutdown),
`Start-Process` without -Wait (killed immediately), `-PassThru` + 10s sleep
(killed mid-flight after 57 KB of provider logs).

## Build

```bash
cd packer/packer-windows-arm64
packer init .
packer fmt -recursive .
packer validate .

# Launch with the auto-healing supervisor:
python3 scripts/qmp-supervisor.py &
packer build .

# Or fully headless:
packer build -var headless=true .
```

## Post-build

```bash
qemu-img info output/windows11-arm64-1.0.0/windows11-arm64-golden.qcow2
qemu-img check output/windows11-arm64-1.0.0/windows11-arm64-golden.qcow2

qemu-img convert -p -f qcow2 -O vmdk -o subformat=streamOptimized \
  output/windows11-arm64-1.0.0/windows11-arm64-golden.qcow2 \
  output/windows11-arm64-1.0.0/windows11-arm64-golden.vmdk

cd output/windows11-arm64-1.0.0
sha256sum windows11-arm64-golden.qcow2 windows11-arm64-golden.vmdk > SHA256SUMS
```

The VMDK is a **VMware-format candidate**, not a production template
(ESXi-Arm doesn't support W11 ARM guest customisation).

## Troubleshooting Journey

Every architectural choice in this repository exists because a specific
failure was encountered on this hardware. This is the complete record,
in the order the issues were discovered and fixed.

### Phase 1: Boot and USB topology

**1. PXE boot regression (USB hub slowdown)**
- Symptom: VM booted to PXE instead of the Windows installer.
- Root cause: Attaching a 5th USB device (virtio-win ISO) on `bus=usb.0`
  made QEMU silently auto-insert a 12 Mb/s full-speed hub. The slow
  enumeration pushed the cdboot prompt past Packer's 60s key window.
- Fix: A second `qemu-xhci` controller (`usb2`). Setup ISO keeps usb.0;
  extra CDs go to usb2.0's fast root ports.
- Commit: `7a08166`

**2. Nondeterministic cdboot prompt arrival**
- Symptom: Some runs missed the "Press any key" prompt even with the
  topology fix.
- Root cause: Fresh swtpm instance does TPM2 RSA keygen on first boot.
  On emulated ARM64, this stretches firmware POST from 5s to 200s+.
- Fix: Extended boot_command spam from 63s to 600s (300 keypresses).
- Commit: `d75a7ad`

**3. Boot-chain wedge (host-level KVM/ARM64 race)**
- Symptom: After a guest reboot, the firmware starts `bootmgfw.efi` and
  then the VM freezes - display stuck on the firmware console, 2 vCPUs
  spinning, disk silent. Hits ~1-in-4 reboots at random boundaries.
- Root cause: A host-level virtualization race (not an image problem).
  A QMP `system_reset` re-enters the boot and usually succeeds.
- Fix: `scripts/qmp-supervisor.py` - screendumps every 15s, detects the
  wedge (static firmware-text screen + no disk writes for 90s, armed only
  after the first disk write), auto-resets (max 3/hour).
- Commits: `c4e32a1`, `d75a7ad`, `d5a2ade`

### Phase 2: WinRM and provisioning

**4. WinRM bootstrap never ran (drive-letter race)**
- Symptom: Windows booted to desktop, but WinRM stayed stopped and the
  firewall stayed on.
- Root cause: FirstLogonCommands fired before USB CD-ROM drive letters
  were assigned. The one-shot `if exist` scan found nothing and silently
  did nothing.
- Fix: The FirstLogonCommands now retry-wait up to 90s for the unattend
  CD, then run `00-bootstrap-winrm.ps1`.
- Commit: `7a08166`

**5. Bootstrap script parse failure (encoding)**
- Symptom: The bootstrap script was found but never did anything - WinRM
  stayed stopped, firewall on.
- Root cause: Em-dash characters (U+2014) in the script's comments and
  strings. Packer writes the script to the unattend CD as UTF-8 without
  BOM; Windows PowerShell 5.1 parses BOM-less scripts as CP1252, where
  the em-dash's third byte (0x94) is a closing smart-quote that breaks
  the parser.
- Fix: All guest-executed files (.ps1 scripts, unattend XML) are pure
  ASCII. A `pwsh` parser validation script checks every guest file.
- Commits: `69a52cd`, `f51bf86` (enforcement)

**6. DISM "Access is denied" (elevated context required)**
- Symptom: `Add-WindowsCapability -Online` for OpenSSH failed with
  "Access is denied" in the WinRM session, despite the session being an
  admin token (MSI installs succeeded).
- Root cause: The CBS/servicing stack rejects the WinRM network-logon
  session type for DISM operations specifically.
- Fix: `elevated_user`/`elevated_password` on the powershell provisioner -
  Packer runs the scripts via a scheduled task with a full elevation token.
- Commit: `07b001e`

### Phase 3: Software installation strategy

**7. WinRM file upload too slow (~30 KB/s)**
- Symptom: Uploading bundled installers (7-Zip + PowerShell 7, ~113 MB)
  over WinRM-SOAP took over an hour.
- Fix: Switched to winget (network downloads in minutes). Chocolatey
  was tried first (commit `580dcf2`) but its released CLI lacks reliable
  ARM64 architecture selection - replaced with winget which selects the
  native ARM64 installer per package manifest (commit `751566b`).
- Commits: `580dcf2`, `751566b`

**8. winget not available on clean image**
- Symptom: winget (App Installer) not found in the WinRM session right
  after first logon.
- Root cause: Windows provisions Store apps (including App Installer)
  asynchronously after first logon; the provisioning session checked
  too early.
- Fix: `10-install-software.ps1` waits up to 10 minutes, then falls
  back to bootstrapping from the pinned winget-cli release (msixbundle
  + ARM64 dependencies + offline license) if still missing.
- Commit: `73e7dee`

### Phase 4: Cleanup and shutdown

**9. DISM StartComponentCleanup 47+ minute stall**
- Symptom: The DISM `/StartComponentCleanup /ResetBase` step hung the
  build at "Cleaning up temporary files..." while the guest sat idle
  in Task Manager.
- Root cause: In the elevated scheduled-task context on emulated ARM64,
  DISM ran for 47+ minutes (vs ~10 min in prior non-elevated runs).
- Fix: Removed DISM cleanup from the script. It is an image-size
  optimization, not a sysprep requirement. Host-side qemu-img convert
  handles image size.
- Commit: `966a1de`

**10. Windows Update service stop hang**
- Symptom: `Stop-Service -Force` on wuauserv hung indefinitely in the
  elevated context.
- Fix: Removed the Windows Update cache clearing and prefetch clearing
  from the cleanup script. All are size optimizations, not requirements.
- Commit: `f51bf86`

**11. Disk-full sysprep starvation (the zeroing trap)**
- Symptom: Sysprep ran but never completed; the guest reported 0% free
  disk. The build timed out waiting for shutdown.
- Root cause: The cleanup script zeroed free space (for qcow2 compaction)
  by writing a file until the disk was 100% full, then deleted it. But
  sysprep and Windows shutdown need filesystem write access (registry
  flushes, event logs, pagefile). With 0 bytes free, they hang.
- Fix: Removed disk zeroing entirely. Free-space is reported and gated
  (minimum 2GB) before sysprep handoff. Compaction is handled host-side
  by the qemu-img convert to VMDK streamOptimized (a compressed format).
- Commits: `98ac313`, `e31df3d`

**12. Packer env-vars helper deleted by cleanup**
- Symptom: A non-fatal "not recognized" error for
  `packer-ps-env-vars-*.ps1` after the cleanup script's temp wipe.
- Root cause: The cleanup script wiped `C:\Windows\Temp\*` which included
  Packer's own env-vars helpers for the next session.
- Fix: The temp wipe excludes `packer-*`.
- Commit: `98ac313`

### Phase 5: Sysprep

**13. Sysprep blocked by per-user winget source package (0x80073cf2)**
- Symptom: Sysprep exited immediately after starting. Panther setuperr.log
  showed: "Package Microsoft.Winget.Source was installed for a user, but
  not provisioned for all users ... halting sysprep execution."
- Root cause: SysprepGeneralizeValidate (AppxSysprep.dll) requires ALL
  appx packages to be provisioned machine-wide. The winget source package
  is installed per-user when winget runs during provisioning.
- Diagnosis method: WinRM SOAP over the forwarded port (pywinrm) pulled
  the Panther logs from `C:\Windows\System32\Sysprep\Panther\` while
  sysprep was running.
- Fix: `90-sysprep.ps1` removes the per-user
  `Microsoft.Winget.Source*` package before calling Sysprep.exe.
- Commit: `58ece45`

**14. Sysprep launch: three failed methods before WMI**
This was the hardest problem - each fix revealed the next failure layer:

| Attempt | Method | What happened |
|---|---|---|
| 1 | `Start-Process -Wait` | Sysprep completed, called the Windows shutdown API, the WinRM service stopped mid-response. Packer saw the connection drop as "Failed to send shutdown command ... EOF" and errored. |
| 2 | `Start-Process` (no -Wait) | Script returned immediately, but Windows killed the scheduled task's process tree - Sysprep.exe died before writing any Panther logs. |
| 3 | `-PassThru` + 10s sleep | Sysprep started, wrote 57 KB of Panther logs, executed ~50 generalize providers, then was killed mid-flight during `GeneralizeForImaging` (usosvc.dll) - the scheduled task cleanup reached it asynchronously. |
| 4 | **WMI `Win32_Process.Create`** | Creates the process in the WMI service's own context (SYSTEM, independent process tree). No scheduled-task cleanup can touch it. **This is the fix.** |

- Commits: `f5bf01b` (attempt 2), `695c6c8` (attempt 3), `419d1c1` (WMI)

### Phase 6: Teardown

**15. QEMU/swtpm orphaned on build error**
- Symptom: After an errored build, the QEMU VM and swtpm daemon kept
  running for hours, holding ports and the serial log.
- Root cause: Packer kills the wrapper script without a trappable signal.
  Bash's EXIT trap doesn't run on SIGKILL. The wrapper's foreground
  qemu-system-aarch64 child and the swtpm daemon were orphaned.
- Fix: `scripts/pdeathsig-exec.py` - exec the command with
  `PR_SET_PDEATHSIG=SIGKILL`. The kernel kills the child the instant
  the parent dies, however it dies. swtpm runs without `--daemon` (the
  fork would clear PDEATHSIG).
- Commit: `dea3b10`

### The successful build

After all 15 issues were identified and fixed, the build completed:

```
Build 'windows11-arm64-golden' finished after 48 minutes 43 seconds.
Sysprep.exe launched via WMI (PID 2984) - fully detached from the
scheduled task. The machine will shut down when it completes.
```

Artifact: 80 GiB virtual, 15.3 GiB on disk (qcow2), 19.08% allocated,
no errors (qemu-img check), all processes cleanly torn down.

## Lessons learned

1. **Never make guest-executed files non-ASCII.** PowerShell 5.1 parses
   BOM-less files as CP1252; em-dashes break the parser silently.
2. **Never fill a Windows disk to 100%.** Sysprep and shutdown need
   filesystem write access.
3. **DISM/CBS rejects WinRM tokens.** Use the elevated provisioner.
4. **Scheduled tasks kill child processes.** Use WMI `Win32_Process.Create`
   for processes that must outlive the task.
5. **Packer's teardown signal is untrappable.** Use PDEATHSIG for
   guaranteed cleanup.
6. **KVM/ARM64 has a nondeterministic boot race.** Build supervision
   (QMP reset) into the workflow.
7. **Host-side observation is not guest visibility.** WinRM SOAP
   (pywinrm over the forwarded port) gives real-time guest introspection
   during a running build - this was essential for diagnosing sysprep.

## Status

Build is fully working end-to-end: boot, install, provisioning (winget
native ARM64), validation, cleanup, sysprep, shutdown, artifact. All
16 commits document the incremental journey from scaffold to golden image.
