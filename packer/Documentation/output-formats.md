# Output formats: VMDK and ISO - swap the artifact, keep the pipeline

A guide for sysadmins who have **never used Packer**, showing how the
`packer-ubuntu-arm64` project's output can be turned into a **VMDK**
(for VMware) or packaged into an **ISO** (for distribution), and - the
real point - how little of the build actually changes when you do.

Written for the **x86_64 scenario** (a normal PC or server as the build
host, an amd64 Ubuntu Server ISO as the input), because that is where
the VMware and ISO destinations are most useful. Everything below is
the same pipeline as the parent project's README describes; only the
last mile differs.

If you have never seen a Packer template at all, read the parent
project's `README.md`, section **"Packer in five minutes"**, first. The
30-second version for this document:

- The **`source` block** in `ubuntu-26.04-arm64.pkr.hcl` describes the
  VM and its **artifact** (the disk image Packer writes out).
- The **`build` block's provisioners** (the Ansible playbook, the file
  uploads, the shutdown command) put the software *inside* the machine.
- Packer runs the whole thing and writes the artifact into
  `output/ubuntu-26.04-arm64-<version>/`.

## The modularity map - what changes and what never does

The project is layered exactly so that the *artifact format* is a thin
output layer at the bottom. Every path in this document changes **only
the bottom layer**:

| Layer | Where it lives | Changes for VMDK? | Changes for ISO? |
|---|---|---|---|
| OS unattended install (`seed/user-data.tftpl`) | seed CD | **no** | **no** |
| Software + validation (Ansible roles) | `ansible/site.yml` | **no** | **no** |
| Lockdown + cloud-init reset (`scripts/80-cleanup.sh`) | shutdown step | **no** | **no** |
| VM definition (CPU/RAM/disk/communicator) | `source` block | **no** | **no** |
| Artifact format | `format` knob / post-build convert | **yes** | **yes** (post-build only) |

That is the whole thesis: **swap the disk format and the entire
provisioning pipeline neither knows nor cares.** The expensive,
hard-won parts of the build - the autoinstall seed, the cross-platform
LAMP playbook, the validation gate, the credential lockdown - are
byte-for-byte identical whichever output you choose.

One honest boundary, verified against the installed plugin (v1.1.6):
the QEMU builder's `format` knob accepts **only `qcow2` and `raw`**.
Asking it for anything else fails validation with:

```
Error: 1 error(s) occurred:

* invalid format, only 'qcow2' or 'raw' are allowed
```

So the format story is:

- **`qcow2` -> `raw`**: a one-word change inside the HCL file.
- **`qcow2` -> VMDK**: one deterministic command after the build
  (`qemu-img convert`). Not HCL, but zero risk - it touches only the
  finished file, never the pipeline.
- **Distribution ISO**: one `xorriso` command after the build, again
  pipeline-untouched.
- **Born-in-VMware / born-as-template**: a `source` block swap (see the
  end of Part A) - the provisioners still do not change.

## Scenario 0: running this on an x86_64 host

The parent project builds on an aarch64 host. On an x86_64 PC, three
small adaptations, all at the input layer:

1. **The ISO**: point the pkrvars at an amd64 server ISO instead:

```hcl
ubuntu_iso_path     = "/home/you/ISO/ubuntu-26.04.1-live-server-amd64.iso"
ubuntu_iso_checksum = "sha256:<sha256sum of that ISO>"
```

The seed and the Ansible playbook are architecture-agnostic - no
change.

2. **The QEMU wrapper is optional on x86** (and only there). It exists
   because ARM `virt` machines have no IDE/SATA controller, making
   Packer's default CD attachment invisible to the firmware. An x86
   `pc` machine has SATA, so the plugin's default attachment just
   works. Two valid choices:
   - **Keep everything as-is**: the wrapper's rewrites are harmless on
     x86, and you keep the `autoconfirm.py` watchdog answering
     subiquity's confirmation prompt. Zero changes.
   - **Strip to a plain build**: drop `qemu_binary`, let Packer run
     plain QEMU, and restore a classic `boot_command` that edits the
     GRUB entry to add the `autoinstall` kernel token:

```hcl
  # (the kernel-cmdline route - reliable on x86, where firmware POST
  # is fast and deterministic; it was the ARM POST/USB-CD race that
  # made keystrokes unusable on the aarch64 host)
  boot_wait = "3s"
  boot_command = [
    "e<wait>",
    "<down><down><end>",
    " autoinstall ds=nocloud",
    "<leftCtrlOn>x"
  ]
```

   With `autoinstall` on the kernel command line, subiquity never shows
   its confirmation prompt, so no watchdog is needed.

3. **`machine_type`**: leave it unset on x86 (Packer's QEMU plugin
   defaults to the `pc` machine there); `machine_type = "virt"` is
   ARM-specific.

Everything else - seed, Ansible, validation, lockdown - runs exactly as
documented in the parent README.

## Part A - Outputting VMDK, and using it

### A1. What a VMDK is, and which flavor you need

VMDK is VMware's disk format. One file (or a set) that Workstation,
Fusion, ESXi and every VMware tooling understand. The two subformats
you will actually meet here:

- **`monolithicSparse`** - a single growable file. This is what
  `qemu-img convert -O vmdk` produces by default. Best for
  **Workstation and Fusion**: "use an existing virtual disk" and go.
- **`streamOptimized`** - a single **compressed**, stream-friendly
  file, the flavor ESXi's import paths (OVF/OVA, datastore upload)
  expect. Produced with `-o subformat=streamOptimized`. This is what
  the sibling project `../packer-windows-arm64` uses for its
  post-build VMware conversion.

Real output from this host (a 128 MiB test disk, converted both ways):

```
$ qemu-img info demo-default.vmdk
image: /tmp/fmttest/demo-default.vmdk
file format: vmdk
virtual size: 128 MiB (134217728 bytes)
disk size: 32 KiB
Format specific information:
    cid: 18934454
    create type: monolithicSparse
    ...

$ qemu-img info demo-stream.vmdk
image: /tmp/fmttest/demo-stream.vmdk
file format: vmdk
virtual size: 128 MiB (134217728 bytes)
Format specific information:
    cid: 3900515180
    create type: streamOptimized
    extents:
        [0]:
            compressed: true
            ...
```

### A2. The conversion (one command, after the build)

Keep building in qcow2 - it is the format the pipeline is proven on,
it is sparse, and it stays useful for KVM deployments. Then convert
the finished artifact once, exactly like the Windows sibling project
does:

```bash
cd packer/packer-ubuntu-arm64

# For ESXi (compressed, import-ready):
qemu-img convert -p -f qcow2 -O vmdk -o subformat=streamOptimized \
  output/ubuntu-26.04-arm64-1.0.0/ubuntu-26.04-arm64.qcow2 \
  output/ubuntu-26.04-arm64-1.0.0/ubuntu-26.04-arm64.vmdk

# Or for Workstation/Fusion (plain single growable file):
qemu-img convert -p -f qcow2 -O vmdk \
  output/ubuntu-26.04-arm64-1.0.0/ubuntu-26.04-arm64.qcow2 \
  output/ubuntu-26.04-arm64-1.0.0/ubuntu-26.04-arm64.vmdk

# Verify before you trust it:
qemu-img check output/ubuntu-26.04-arm64-1.0.0/ubuntu-26.04-arm64.vmdk
(cd output/ubuntu-26.04-arm64-1.0.0 && sha256sum ubuntu-26.04-arm64.qcow2 ubuntu-26.04-arm64.vmdk > SHA256SUMS)
```

`-p` prints a progress bar; an 8 GB image converts in a few minutes.
The conversion only **reads** the qcow2 - the golden image is never
modified, and the output directory is gitignored along with the qcow2.

One VMware-readiness tweak worth making in the pipeline (not the
format): add `open-vm-tools` to the guest so VMware can see heartbeats
and guest info - one line in the Ansible role's Debian vars or the
seed's `packages:` list. The `qemu-guest-agent` the build installs is
redundant on VMware but harmless.

### A3. Using the VMDK - Workstation / Fusion, step by step

The image boots **UEFI** (its disk carries an EFI System Partition and
GRUB - a fact of the build), and ships with **no working credentials**
(you inject your own access on first boot via cloud-init). Both facts
shape the walkthrough:

1. **Create the VM shell**: File -> New Virtual Machine -> *Custom
   (advanced)* -> *I will install the operating system later* ->
   Guest OS: **Linux**, Version: **Ubuntu 64-bit** -> one CPU / 2-4 GB
   is plenty -> **do not create a disk** ("I will configure the disk
   later" / remove the suggested one).
2. **Attach the golden disk**: VM Settings -> Add -> Hard Disk ->
   *Use an existing virtual disk* -> pick `ubuntu-26.04-arm64.vmdk`
   (the `monolithicSparse` one; if you only made the streamOptimized
   one, Workstation accepts it too).
3. **Set firmware to EFI**: VM Settings -> Options tab -> Advanced ->
   Firmware type: **UEFI** (leave Secure Boot off - the build uses
   plain EDK2-style UEFI, no Secure Boot). Skipping this step is the
   #1 cause of "it boots to firmware and finds nothing".
4. **Prepare your access seed** (identical recipe to the parent
   README's clone workflow - the image is cloud-init-ready by design):

```bash
mkdir -p seedtest
cat > seedtest/user-data <<'EOF'
#cloud-config
users:
  - name: myuser
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    ssh_authorized_keys:
      - ssh-ed25519 AAAA... myuser
EOF
printf 'instance-id: lamp-clone-001\nlocal-hostname: lamp-server\n' > seedtest/meta-data
xorriso -as mkisofs -o seed.iso -V cidata -r seedtest/user-data seedtest/meta-data
```

5. **Attach the seed as a CD** (VM Settings -> CD/DVD -> *Use ISO
   image* -> your `seed.iso`), **power on**, and wait about a minute.
   First boot: cloud-init reads the `cidata` CD, creates your user and
   key.
6. **Use it**: SSH to the VM with your key (`ssh myuser@<vm-ip>`) or
   log in at the console, and verify the LAMP stack:

```bash
systemctl is-active apache2 mariadb      # -> active / active
curl -s http://localhost/                # -> "LAMP-OK PHP 8.5.4 ..." + phpinfo()
```

Habit worth keeping: **boot a clone, not the golden disk** - in
Workstation that means "Manage -> Clone" (or copy the files) before
first boot. First boot stamps per-machine state (machine-id, SSH host
keys) into the disk; you want the golden image to stay pristine for
the next clone.

### A4. Using the VMDK - ESXi

1. **Upload**: Storage/Datastore browser -> Upload the
   `streamOptimized` VMDK (or with govc:

```bash
govc datastore.upload -ds datastore1 \
  output/ubuntu-26.04-arm64-1.0.0/ubuntu-26.04-arm64.vmdk \
  golden/ubuntu-26.04-arm64.vmdk
```

2. **Create the VM**: New Virtual Machine -> *Linux* -> **Ubuntu Linux
   (64-bit)** -> 1-2 vCPU / 2-4 GB -> **delete the default disk** and
   instead *Add existing hard disk* -> the uploaded VMDK.
3. **VM Options -> Boot Options -> Firmware: EFI** (same reason as
   above).
4. Attach your `seed.iso` (from A3 step 4) as a CD/DVD, power on,
   wait ~a minute, SSH in with your seed-provided key.
5. **Make it a real template**: right-click the running-or-stopped VM
   -> *Clone -> Clone to Template*. That registers disk + hardware
   config + guest type as a vCenter master image - which is the thing
   a "VMware template" actually is: an inventory object, not a file.
   (The conversion gave you the disk; this step gives you the
   template.)

Note: the image's cloud-init-first-boot design *replaces* the usual
vCenter "guest customization" step for identity - every clone brings
its own `cidata` seed and configures itself. If you prefer vCenter
customization instead, plan on open-vm-tools + the Perl customization
stack and expect the usual DNS/domain workflow.

### A5. If you want Packer to *born* the VMware artifact (source swap)

This is the strongest form of the modularity claim - changing the
**hypervisor itself** still does not touch the provisioning. The same
`build` block - the Ansible provisioner, the report download, the
cleanup upload, the shutdown command - attaches unchanged to a VMware
builder:

```hcl
# Illustrative - requires Workstation/ESXi present at build time.
# The provisioner block below is IDENTICAL to the QEMU build's.
source "vmware-iso" "ubuntu_amd64" {
  iso_url      = var.ubuntu_iso_path
  iso_checksum = var.ubuntu_iso_checksum
  guest_os_type = "ubuntu-64"
  ssh_username  = var.build_user
  ssh_password  = "ubuntu"

  # The same cidata seed recipe works on any builder that can attach
  # a CD; on VMware the GRUB keystroke edit is reliable (fast,  
  # deterministic x86 firmware), so the autoinstall token goes on
  # the kernel command line and subiquity never prompts:
  cd_files   = ["seed/"]        # or keep cd_content + templatefile
  cd_label   = "cidata"
  boot_wait  = "3s"
  boot_command = [
    "e<wait>",
    "<down><down><end>",
    " autoinstall ds=nocloud",
    "<leftCtrlOn>x"
  ]
}

build {
  sources = ["source.vmware-iso.ubuntu_amd64"]

  # ... this entire provisioner section is copy-paste identical:
  provisioner "ansible" {
    playbook_file    = "ansible/site.yml"
    extra_arguments  = ["-v"]
    ansible_env_vars = ["ANSIBLE_CONFIG=ansible/ansible.cfg"]
  }
  # file provisioners and shutdown_command: identical
}
```

And building directly **on ESXi via vCenter**, Packer can register a
true template for you (`vsphere-iso` builder from
`github.com/hashicorp/vsphere`):

```hcl
source "vsphere-iso" "ubuntu_amd64" {
  iso_url     = var.ubuntu_iso_path
  iso_checksum = var.ubuntu_iso_checksum
  vcenter_server  = "vcenter.example.com"
  username        = "packer@vsphere.local"
  password        = var.vcenter_password
  cluster         = "my-cluster"
  datastore       = "datastore1"
  convert_to_template = true          # <- the artifact IS a template
  ssh_username    = var.build_user
  ssh_password    = "ubuntu"
  cd_files        = ["seed/"]
  cd_label        = "cidata"
  boot_command    = [ /* GRUB edit as above */ ]
}
```

What is QEMU-specific and gets dropped in these swaps: the
`scripts/qemu-wrapper.sh` arg surgery (USB CDs, disk `bootindex`,
ramfb/usb-kbd) and the `autoconfirm.py` watchdog - those solve QEMU/
ARM-virt problems that do not exist on VMware's virtual hardware. What
survives untouched: the seed content, the whole Ansible playbook, the
validation gate, the lockdown. **That is the swap-cost claim in one
sentence: the machine changes, the software does not.**

## Part B - Outputting an ISO, and using it

### B1. What "an ISO output" can mean - read this first

Honesty first, because this is where expectations go wrong:

1. **A distribution ISO** - an ISO *containing* the golden image, its
   checksums, and the validation evidence. Mountable on any OS and
   hypervisor, air-gap friendly, one `xorriso` command. **This is what
   "output an ISO" costs you here: almost nothing.** Covered below.
2. **A bootable "live" ISO of the built system** (boot the ISO itself,
   get the golden machine, no disk attach). This is **not** a format
   swap - it is a different build pipeline (squashfs root + casper
   live-boot assembly; think `live-build` or a re-mastering tool like
   `cubic`). Packer's QEMU builder outputs disks; turning an installed
   disk into a self-booting live ISO is out of scope for this project.
   If a from-scratch-installing ISO is the goal, the cheaper route is
   the third option:
3. **A netboot/PXE installer** - boot the plain Ubuntu installer over
   the network and serve the *same seed* over HTTP: the parent
   project's `seed/user-data.tftpl` content is directly reusable as a
   plain `user-data` file on any web server, with
   `autoinstall ds=nocloud-net;s=http://<server>/` on the kernel
   command line. Same unattended install, no image artifact at all.

### B2. Making the distribution ISO

Same `xorriso` recipe the project already uses for its `cidata` seed
CDs - the tool is proven in this repo:

```bash
cd packer/packer-ubuntu-arm64/output/ubuntu-26.04-arm64-1.0.0

# Fresh checksums of everything you are shipping
sha256sum ubuntu-26.04-arm64.qcow2 ubuntu-26.04-arm64.vmdk > SHA256SUMS

cat > README.txt <<'EOF'
packer-ubuntu-arm64 golden image, version 1.0.0
- ubuntu-26.04-arm64.qcow2 : KVM/QEMU disk image (20G virtual)
- ubuntu-26.04-arm64.vmdk  : VMware disk image (streamOptimized)
- SHA256SUMS               : verify before use: sha256sum -c SHA256SUMS
- validation-report.json   : in-image build validation evidence
Deploy: see packer/packer-ubuntu-arm64/README.md "Using the image".
Access: the image ships with no credentials; boot a clone with a
cloud-init cidata seed (README "Using the image") to inject yours.
EOF

xorriso -as mkisofs -o ../ubuntu-26.04-arm64-1.0.0-golden.iso \
  -V GOLDEN_1_0_0 -r \
  ubuntu-26.04-arm64.qcow2 ubuntu-26.04-arm64.vmdk SHA256SUMS \
  ../../reports/validation-report.json README.txt

# Expected output (shape - sizes will match your artifacts):
#   Added to ISO image: file '/ubuntu-26.04-arm64.qcow2'=...
#   Added to ISO image: file '/SHA256SUMS'=...
#   ISO image produced: NNNN sectors
#   Writing to 'stdio:.../ubuntu-26.04-arm64-golden.iso' completed successfully.
```

Volume label note: `-V` takes a short label - the seed CDs use
`cidata` because cloud-init *requires* that exact label; a
distribution ISO needs no magic label, just something readable.

Size note: the golden image is ~8 GB, so this ISO is not DVD-shaped -
it is a file-transfer container for shares, USB sticks, or VM
attach-as-CD. If you only ever deploy to one hypervisor, ship the one
disk format you need and skip the second.

### B3. Using the distribution ISO

```bash
# Any Linux box:
sudo mount -o loop ubuntu-26.04-arm64-1.0.0-golden.iso /mnt
cd /mnt
sha256sum -c SHA256SUMS          # verify BEFORE trusting anything
cp ubuntu-26.04-arm64.vmdk /somewhere/ && cd /somewhere

# ESXi/vSphere: upload the VMDK to a datastore, then Part A.4.
# Workstation/Fusion: existing-disk attach, then Part A.3.
# KVM: qemu-img convert back if you shipped only the VMDK, or use the
#      qcow2 directly; deploy per the project README's clone workflow.
```

The VM-attach trick: hypervisors can attach the ISO as a CD/DVD to a
running VM - handy on ESXi, where you can also just
`govc datastore.upload` the ISO and mount it from the datastore
browser.

The non-negotiable habit, whatever the destination: **verify the
checksum before deploying, and never boot the golden disk itself** -
boot a clone/copy with a fresh `cidata` seed for access. Both rules
are the same ones the parent project's end-to-end test enforces.

## The swap matrix (summary)

| Goal | What you change | Effort | Provisioning changes? |
|---|---|---|---|
| qcow2 -> raw | `format = "raw"` in the source block | one word | no |
| qcow2 -> VMDK | one `qemu-img convert` after the build | one command | no |
| VMDK -> VMware VM | attach + EFI firmware + seed CD | minutes, UI | no |
| VMware VM -> template | "Clone to Template" (vCenter) | one click | no |
| Born-in-VMware build | swap `source "qemu"` -> `vmware-iso` | one block | no (provisioners identical) |
| Born-as-template build | `source "vsphere-iso"` + `convert_to_template` | one block + ESXi creds | no |
| Distribution ISO | one `xorriso` command after the build | one command | no |
| Bootable live ISO | different pipeline (squashfs/casper, `live-build`/`cubic`) | out of scope | n/a |
| PXE net-installer | serve the same seed over HTTP | small, no Packer | seed reused as-is |

## Pitfalls checklist

- **Firmware must be EFI** for these images (they boot via GRUB on an
  ESP). BIOS boot = "no bootable device". Set it in every destination.
- **VMDK subformat**: `monolithicSparse` (default) for
  Workstation/Fusion; `streamOptimized` for ESXi upload/OVF import.
- **`format` only accepts `qcow2`/`raw`** in this QEMU plugin (v1.1.x)
  - check with `packer validate` before promising anyone a one-word
  format swap; VMDK is a post-build convert.
- **Verify checksums** after every copy (SHA256SUMS travels with the
  artifact; `sha256sum -c` is one command).
- **Never first-boot the golden disk** - clone/copy, then attach the
  `cidata` seed for access (the image deliberately ships with none).
- **Architecture**: an amd64 image (this document's scenario) runs on
  any x86_64 VMware/KVM host. The parent project's arm64 build runs
  only on ARM hypervisors (ESXi-Arm, Fusion on Apple Silicon, ARM KVM)
  - mainstream x86 vSphere cannot run it at all, no matter the disk
  format.
- **qcow2 stays canonical**: keep the build artifact in the proven
  format and convert outward; that way one build serves every
  destination (KVM gets the qcow2, VMware gets the VMDK, the archive
  gets the ISO).
