# packer-windows2019-x64

A fully automated Packer build that produces a **patched, Sysprep-generalized
Windows Server 2019 Standard (Desktop Experience) x64 template** as a
single-file VirtualBox appliance (`.ova`), built with the VirtualBox
installed on this host — unlike the sibling projects, which build ARM64
images on QEMU/KVM.

The build installs the OS unattended from the Microsoft evaluation ISO,
applies Windows Updates until nothing is pending, installs VirtualBox Guest
Additions, validates itself with a hard evidence gate, then Sysprep-
generalizes the machine and exports it as a reusable template.

## Pipeline overview

```
Packer (winrm communicator)
└── source.virtualbox-iso.windows2019_x64
    ├── BIOS boot, install ISO + supplemental "UNATTEND" CD
    │   └── Autounattend.xml (MBR disk, edition index, Administrator
    │       password, autologon, FirstLogonCommands)
    │       └── 00-bootstrap-winrm.ps1   ← WinRM up at FIRST logon
    ├── 10-install-guest-additions.ps1   ← GA ISO attached by the builder
    ├── 20-windows-updates.ps1  ×3 rounds, each followed by a reboot
    │   (Windows Update Agent COM API: search → download → install,
    │   reboot-aware, no PowerShell module dependencies)
    ├── 40-validate-image.ps1            ← hard gate: edition / GA / 0 pending
    ├── 80-cleanup.ps1                   ← temp files, firewall re-arm, gates
    ├── 90-sysprep.ps1 (via shutdown_command)
    │   └── sysprep /oobe /generalize /shutdown (WMI-detached launch)
    └── export → output/windows-2019-x64-<version>/windows2019-x64-template.ova
    └── post-processors: SHA256SUMS + manifest.json (release evidence)
```

Everything after `packer build` starts is hands-off; the VM window is
visible during the build (`headless = false`) so progress is observable.

## Repository layout

```
packer-windows2019-x64/
├── windows2019-x64.pkr.hcl          # builder + provisioner pipeline
├── variables.pkr.hcl                # variable declarations
├── windows2019-x64.auto.pkrvars.hcl # values (gitignored - contains password)
├── answer-files/
│   └── Autounattend.xml             # templated unattend answer file
├── scripts/
│   ├── 00-bootstrap-winrm.ps1       # WinRM bootstrap (first logon)
│   ├── 10-install-guest-additions.ps1
│   ├── 20-windows-updates.ps1       # one update round (run 3×)
│   ├── 40-validate-image.ps1        # validation gate + evidence
│   ├── 80-cleanup.ps1               # cleanup + firewall re-arm
│   └── 90-sysprep.ps1               # sysprep generalize/shutdown
├── output/                          # build output (gitignored)
└── reports/
    └── validation-report.json       # pulled out of the image each build
```

## Prerequisites (this host)

- Packer ≥ 1.10 (host has 1.16.1) — the VirtualBox plugin is fetched by
  `packer init`.
- `xorriso` (installed on this host) — Packer uses it to build the
  supplemental unattend CD. Without one of xorriso/mkisofs/hdiutil/oscdimg
  the build dies at StepCreateCD with "could not find a supported CD ISO
  creation command" (observed on the first run, 2026-10-07).
- VirtualBox 7.2.20 with the Guest Additions ISO at
  `/usr/lib/virtualbox/additions/VBoxGuestAdditions.iso`
  (sha256 `4c6ba898e37b307cf9088be8ff480d9aec13bb0e395aaf31c78d564bb35916e7`).
  Arch-family distros package the GA ISO outside the plugin's default
  search path, which is why the build references it as an explicit
  `file://` URL. **Re-check this checksum after any VirtualBox upgrade.**
- The evaluation ISO: `/home/david/ISO/Windows_Server_2019_EVAL_x64_en-us.iso`
  (sha256 `6dae072e7f78f4ccab74a45341de0d6e2d45c39be25f1f5920a2ab4f51d7bcbb`).
  It lives outside `files/` to avoid duplicating 5.7 GB; move it and update
  the auto.pkrvars if you prefer.
- `wimlib` (installed on this host) — only needed to re-verify the ISO's
  edition indexes (see below).

## Source media details (verified on this host)

The ISO is Microsoft's ISO9660+UDF evaluation media (build 17763,
en-US, 4 images in `sources/install.wim`, verified with
`wimlib-imagex info`):

| Index | Edition |
| --- | --- |
| 1 | Windows Server 2019 Standard (Core) |
| 2 | Windows Server 2019 Standard (Desktop Experience) ← default |
| 3 | Windows Server 2019 Datacenter (Core) |
| 4 | Windows Server 2019 Datacenter (Desktop Experience) |

Re-verify on any new ISO (UDF session — plain bsdtar only sees a README):

```fish
sudo mkdir -p /mnt/w2k19eval
sudo mount -o loop,ro -t udf /home/david/ISO/Windows_Server_2019_EVAL_x64_en-us.iso /mnt/w2k19eval
wimlib-imagex info /mnt/w2k19eval/sources/install.wim
sudo umount /mnt/w2k19eval; and sudo rmdir /mnt/w2k19eval
```

The unattend file installs **index 2** **keyless** - deliberately. The
EVAL ISO's images are `ServerStandardEval`/`ServerDatacenterEval` editions,
and a product key pins Windows Setup to the key's edition: the 2019
Standard GVLK (`N69G4-...`, EditionID `ServerStandard`) matched nothing,
and setup dead-ended at "Select the operating system" with an empty,
key-filtered image list (proven 2026-10-07 from setup's own setupact.log
lines extracted from a guest memory dump: `CallBack_SelectImageOrShowUi:
There are no matching OS images`). Evaluation media installs without a key
and runs as a 180-day evaluation; `/IMAGE/INDEX` selects the edition. For
Datacenter just set `edition_index = 4`.

## Building

```fish
cd packer/packer-windows2019-x64
packer init .
packer fmt -recursive .
packer validate .
# Syntax gate: parse every provisioning script BEFORE the multi-hour build
# (run 8 taught this the hard way - a parse error makes powershell.exe exit
# 0, so Packer reports success while the script did nothing). pwsh can be a
# distro package or a tarball extracted anywhere, e.g.
#   ~/.cache/pwsh-check/pwsh
pwsh -NoProfile -File scripts/check-syntax.ps1
packer build -on-error=ask .
```

`-on-error=ask` pauses instead of tearing the VM down on failure so it can
be inspected. Rebuilding over an existing output directory needs `-force`.
Expect the full build to take **2–4 hours** — the ISO is a 2018-era image
and the update rounds move a lot of cumulative-update bytes.

Useful variations:

```fish
# Fully unattended, no VM window:
packer build -on-error=ask -var headless=true .

# Unpacked OVF directory instead of a single .ova:
packer build -var vm_template_format=ovf .
```

## Output: the template

```
output/windows-2019-x64-1.0.0/
└── windows2019-x64-template.ova   ← the pushed-out template
```

plus, in the project root: `SHA256SUMS` (artifact checksums), `manifest.json`
/ `manifest.txt` (build metadata incl. image version and source ISO
checksum) and `reports/validation-report.json` (in-image validation
evidence). These three are release evidence — the manifest and checksums
regenerate each build and are gitignored; the validation report is kept.

### Importing / deploying the template

```fish
VBoxManage import output/windows-2019-x64-1.0.0/windows2019-x64-template.ova
VBoxManage startvm windows2019-x64-template --type gui
```

Because the image is Sysprep-generalized, the first boot of the imported
VM runs mini-setup + OOBE rather than reusing the build machine's identity.
Two things to know on first logon:

- The **Administrator password must be changed at first interactive
  logon** — the build flags this deliberately so the build credential does
  not silently persist into every deployment.
- Inbound WinRM (5985) is allowed only from `10.0.2.2` (the VirtualBox NAT
  gateway). That covers the default NAT networking on any VirtualBox host;
  bridged/other networks need their own firewall rule if you want WinRM.

## Design notes & hard-won lessons carried over

These come from the ARM64 project (2026-09-29/30) and apply equally here:

- **WinRM is configured at first logon, never in the specialize pass.**
  Enabling it mid-specialize crashed Windows setup with the
  "computer restarted unexpectedly" reboot loop while devices were still
  installing.
- **Drive letters lag.** Both the unattend CD bootstrap and the Guest
  Additions installer use retrying scans (C:..I: / volume label) instead of
  assuming a fixed drive letter.
- **Sysprep launches detached via WMI `Win32_Process.Create`.** Launches
  tied to the WinRM session's process tree either killed sysprep mid-flight
  or took WinRM down with them.
- **Free-space gates before sysprep** (in both 80-cleanup and 90-sysprep):
  sysprep hangs forever on a nearly-full disk; fail loudly in seconds
  instead of after the shutdown timeout.
- **Update rounds, not one pass.** Servicing Stack updates unlock further
  cumulative updates and some packages only appear after a reboot; three
  rounds converge on the 17763 eval media, and the validation gate fails
  the build if anything is still pending afterwards.
- **Patching is reboot-aware and module-free.** Run 5 (2026-10-07): round 1
  downloaded a large LCU and set the pending-reboot flags, then round 2
  hung ~55 min in TLS/PSGallery setup on a machine that only needed a
  reboot. 20-windows-updates.ps1 now checks reboot-pending state FIRST
  (RebootRequired keys, PendingFileRenameOperations, hotfixes newer than
  boot time) and exits immediately so the windows-restart provisioner
  reboots promptly; the scan and install use the inbox Windows Update
  Agent COM API directly, removing the PSWindowsUpdate/PSGallery/NuGet/
  TLS1.2 dependency stack entirely. 40-validate-image.ps1 uses the same
  COM API for its pending-update gate.
- **The build owns every reboot - the WU agent must not steal them.**
  Run 6 (2026-10-07): round 3 was killed mid-download with scheduled-task
  exit code 267014 (0x41306, SCHED_S_TASK_TERMINATED) - the WU agent
  force-rebooted the machine for updates staged by an earlier round, which
  terminates the elevated task running the script. Fixes: the script sets
  AUOptions=3 + NoAutoRebootWithLoggedOnUsers=1 (agent never auto-
  installs/reboots; AUOptions is reverted by 80-cleanup before shipping,
  NoAutoRebootWithLoggedOnUsers stays as a sensible template default),
  re-checks reboot-pending right before the long download, and the
  provisioners accept exit code 267014 so a round that ends in a stolen
  reboot still hands off cleanly to the windows-restart provisioner.
- **The "Do you want this PC to be discoverable?" prompt must be
  suppressed, not answered.** Run 4 (2026-10-07) installed successfully but
  the VM sat on that blocking NLA dialog at first logon - nothing past it
  runs (no FirstLogonCommands, no WinRM) and Packer waits forever. The
  specialize pass now sets the `NewNetworkWindowOff` registry value, which
  removes the dialog machine-wide. The template's chosen answer is the
  permanent "No": the network profile stays Public (not discoverable) -
  the bootstrap no longer forces Private - and Enable-PSRemoting uses
  -SkipNetworkProfileCheck to listen on the Public-profile NAT adapter.
  Deployed clones inherit all of this.
- **Answer cdboot once, then STOP typing.** The boot command's only job
  is the BIOS "Press any key to boot from CD or DVD" prompt (on screen
  within seconds of VM start). The 2026-10-07 failures were initially
  misdiagnosed as keystroke problems; the real cause was the product key
  (see above). Still, long keystroke spam is risky (keys arriving after
  setup's UI appears can interact with it), so the boot command is a short
  spacebar-only train ending at ~45 s, before any setup UI exists. EFI
  was tested and rejected: VirtualBox EFI shows cdboot.efi's own "Press
  any key" prompt too, so BIOS + one answered prompt is the simplest
  reliable path. Packer also sets boot1=disk boot2=dvd, so post-install
  reboots boot the hard disk first - no prompt, no install loop.
- **Diagnose stuck setup from OUTSIDE the VM.** `VBoxManage controlvm <vm>
  screenshotpng` + `tesseract` reads the screen (setup's left sidebar says
  "Collecting information" on EVERY screen - the main pane is what
  matters), VDI size growth tells you whether the image apply is actually
  running, and `VBoxManage debugvm <vm> dumpvmcore` + grepping the dump
  for `IBS` setupact.log lines reveals what setup itself is doing (this
  is how the product-key mismatch was proven).
- **`xorriso` is required** — Packer builds the supplemental unattend CD with
  it; the first run died at StepCreateCD without it (see Prerequisites).
- **Firewall off is build-time only.** 00-bootstrap disables it to keep
  WinRM reachable regardless of network profile; 80-cleanup re-arms it with
  a NAT-scoped WinRM rule so the template ships with the firewall ON.

## Troubleshooting

| Symptom | Cause / fix |
| --- | --- |
| `Unable to find VirtualBox guest additions ISO` | GA ISO moved (VirtualBox upgraded/reinstalled). Update the `guest_additions_url` in the HCL file. |
| Build fails on the edition key screen / wrong edition | ISO changed — re-verify indexes with `wimlib-imagex info` and update `edition_index`/`product_key`. |
| WinRM never connects (timeout at "Waiting for WinRM") | FirstLogonCommands didn't run or the CD wasn't found. Inspect with `-on-error=ask`; check `C:\Windows\Panther\unattend.xml` and setuperr.log in the paused VM. |
| Boot falls through to "No bootable medium" | The spacebar train missed the cdboot prompt (prompt reliably appears within seconds; rerun). |
| Build hangs at "Waiting for WinRM", VM sits on "Select the operating system" with an empty list | A product key in the answer file whose edition matches no image on the media (the 2026-10-07 root cause: Standard GVLK vs EVAL editions). Eval media: remove the key entirely. Diagnose any recurrence live: `VBoxManage controlvm <vm> screenshotpng /tmp/s.png` + `tesseract`, or `VBoxManage debugvm <vm> dumpvmcore --filename=...` and grep the dump for `IBS` log lines. |
| VM reaches first logon but sits on "Do you want this PC to be discoverable?" (Yes/No) | The NLA dialog blocking the unattended logon (run 4, 2026-10-07). Suppressed via `NewNetworkWindowOff` in the specialize pass; the template behaves as a permanent "No" (Public profile). |
| Update round hangs in TLS/PSGallery/module setup | Old design flaw, fixed run 5 (2026-10-07): the script now checks reboot-pending first and uses only the inbox WU COM API. |
| Update round fails with exit code 267014 (0x41306) | The WU agent force-rebooted the machine mid-round, terminating the script's elevated scheduled task (run 6, 2026-10-07). Now prevented via AU policy in the script and accepted via `valid_exit_codes` on the provisioners. |
| Validation gate fails with `FullyPatched: false` | An update is stuck (e.g. a hung download). Rerun the build; if persistent, check the paused VM (`-on-error=ask`) with the WU COM search (`New-Object -ComObject Microsoft.Update.Session`). |
| `shutdown timeout` after sysprep script ran | Sysprep is slow but working (big registry/generalize on slow disk). 60 m headroom is already allowed; look at `C:\Windows\System32\Sysprep\Panther\setupact.log` in the paused VM. |
| Checksum error at ISO download step | Host VirtualBox was upgraded → GA ISO changed. Update the checksum comment + URL in the HCL and the value if you track it in pkrvars. |
| `could not find a supported CD ISO creation command` | No ISO tool on the host. Install one: `sudo pacman -S --needed xorriso` (xorriso/mkisofs/hdiutil/oscdimg are supported). |

## Demo proof points

- **Repeatability** — delete `output/` and rebuild the identical template
  from the same ISO + code.
- **Patch evidence** — `reports/validation-report.json` records build
  number, installed hotfix count and zero pending updates, and the build
  fails if that is not true.
- **Identity generalization** — import the OVA and show the clone entering
  OOBE with a forced Administrator password change, not the build identity.
- **Release evidence** — the artifact directory shows the template, its
  SHA256SUMS, and a manifest recording the image version and source ISO
  checksum.
