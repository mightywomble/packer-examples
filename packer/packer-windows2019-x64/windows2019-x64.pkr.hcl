packer {
  required_version = ">= 1.10.0"

  required_plugins {
    virtualbox = {
      source  = "github.com/hashicorp/virtualbox"
      version = "~> 1.0"
    }
  }
}

source "virtualbox-iso" "windows2019_x64" {
  iso_url      = var.windows_iso_path
  iso_checksum = var.windows_iso_checksum

  # Verified against this host via `VBoxManage list ostypes`.
  guest_os_type = "Windows2019_64"

  output_directory = "output/windows-2019-x64-${var.image_version}"
  # vm_name is the exported appliance's base name: <vm_name>.ova / <vm_name>.ovf
  vm_name = "windows2019-x64-template"

  # BIOS firmware (the builder default) with the classic MBR layout in
  # Autounattend.xml (100 MB active System Reserved + extended C:). No EFI
  # variable handling needed on Server 2019.

  # SATA for the build disk (Windows 2019 has the inbox storahci driver;
  # IDE works but AHCI is faster). The ISOs stay on the default IDE bus:
  # install ISO + supplemental unattend CD fit its 4 slots.
  hard_drive_interface = "sata"
  sata_port_count      = 4
  disk_size            = var.disk_size

  # Host VirtualBox's Guest Additions ISO. Arch/CachyOS packages it under
  # /usr/lib/virtualbox/additions/ which is NOT in the plugin's default
  # search path, so reference it explicitly as a file:// URL. Attached as a
  # second CD during the build (removed again before export) and installed
  # by scripts/10-install-guest-additions.ps1.
  guest_additions_mode = "attach"
  guest_additions_url  = "file:///usr/lib/virtualbox/additions/VBoxGuestAdditions.iso"
  # sha256:4c6ba898e37b307cf9088be8ff480d9aec13bb0e395aaf31c78d564bb35916e7
  # (VirtualBox 7.2.20) - update this alongside the checksum in the
  # auto.pkrvars when VirtualBox is upgraded on the host.

  # CPU/RAM are not first-class builder options for VirtualBox - they are
  # applied with VBoxManage immediately after the VM is created.
  vboxmanage = [
    ["modifyvm", "{{.Name}}", "--cpus", "${var.cpus}"],
    ["modifyvm", "{{.Name}}", "--memory", "${var.memory}"],
  ]

  headless = var.headless

  communicator   = "winrm"
  winrm_username = var.winrm_username
  winrm_password = var.winrm_password
  winrm_port     = 5985
  # Generous on purpose: three Windows Update rounds against a 2018-era
  # eval ISO move a lot of LCU bytes, and every round is a fresh WinRM
  # reconnect after a reboot.
  winrm_timeout = "6h"

  # Supplemental ISO: templated Autounattend.xml + WinRM bootstrap script.
  # Windows Setup finds Autounattend.xml on the root of any attached CD, so
  # no HTTP server or floppy is needed. Drive letters for this CD vary
  # (D:..I:), which is why the bootstrap FirstLogonCommand scans for it.
  cd_content = {
    "Autounattend.xml" = templatefile("answer-files/Autounattend.xml", {
      winrm_password = var.winrm_password
      edition_index  = var.edition_index
    })
    "00-bootstrap-winrm.ps1" = file("scripts/00-bootstrap-winrm.ps1")
    "image-version.txt"      = var.image_version
  }
  cd_label = "UNATTEND"

  # Boot keystrokes (BIOS cdboot) - ONE job only: answer the
  # "Press any key to boot from CD or DVD" prompt, then STOP.
  #
  # The 2026-10-07 failures were ultimately caused by a product key that
  # matched no image on the EVAL media (see answer-files/Autounattend.xml
  # - fixed by installing keyless); the early runs were misdiagnosed as
  # keystroke issues. Keep the typing minimal anyway: the cdboot prompt
  # reliably appears within seconds of VM start (observed <=8s in every
  # manual boot today), so a short spacebar-only train ending at ~45s
  # answers it while stopping well before setup's UI appears (~60-90s) -
  # stray keys that reach the UI can interact with it. EFI was tested and
  # rejected: VirtualBox EFI shows cdboot.efi's own "Press any key"
  # prompt, so BIOS + one prompt answer is the simplest reliable path.
  # (Note packer sets boot1=disk boot2=dvd, so post-install reboots boot
  # the hard disk first - no prompt, no install loop.)
  boot_wait = "4s"
  boot_command = [
    "<spacebar><wait5s>",
    "<spacebar><wait5s>",
    "<spacebar><wait5s>",
    "<spacebar><wait5s>",
    "<spacebar><wait5s>",
    "<spacebar><wait5s>",
    "<spacebar><wait5s>",
    "<spacebar><wait5s>"
  ]
  # 60m: sysprep /generalize plus the final Windows Update reboot cycle can
  # legitimately take tens of minutes on slower disks; fail loud rather than
  # hang (mirrors the ARM64 project's timeout lesson).
  shutdown_timeout = "60m"

  shutdown_command = <<-EOF
    powershell.exe -ExecutionPolicy Bypass -File C:\\Windows\\Temp\\90-sysprep.ps1
  EOF

  # Export the finished VM as a single-file Open Virtualization Appliance.
  # This OVA is the distributable template - import on any VirtualBox host:
  #   VBoxManage import windows2019-x64-template.ova
  # Switch var.vm_template_format to "ovf" for an unpacked directory form.
  format = var.vm_template_format
}

build {
  name    = "windows-2019-x64-template"
  sources = ["source.virtualbox-iso.windows2019_x64"]

  # Install VirtualBox Guest Additions first so the image is actually
  # usable as a VirtualBox template (video, shared folders, time sync).
  provisioner "powershell" {
    elevated_user     = var.winrm_username
    elevated_password = var.winrm_password
    scripts           = ["scripts/10-install-guest-additions.ps1"]
  }

  # Patching: three rounds of "scan + install everything + reboot". Rounds
  # are needed because Servicing Stack updates unlock further cumulative
  # updates, and some packages only surface after a reboot (observed
  # behaviour of the 17763.107-era eval ISO). The final round normally
  # converges to "no updates available", and 40-validate-image.ps1 then
  # fails the build if anything is still pending.
  provisioner "powershell" {
    elevated_user     = var.winrm_username
    elevated_password = var.winrm_password
    scripts           = ["scripts/20-windows-updates.ps1"]
    # 267014 = 0x41306 SCHED_S_TASK_TERMINATED: the elevated task was killed
    # mid-round, which in practice means Windows rebooted under us (run 6,
    # 2026-10-07 - WU force-reboot race, now also prevented via AU policy in
    # the script). A round that ends this way is not a failure: the machine
    # reboots, this provisioner's exit is accepted, and the windows-restart
    # provisioner below waits for the machine to come back.
    valid_exit_codes = [0, 267014]
  }

  provisioner "windows-restart" {
    restart_command = "shutdown /r /t 10 /c \"Packer restart after Windows Update round 1\" /f"
    restart_timeout = "60m"
  }

  provisioner "powershell" {
    elevated_user     = var.winrm_username
    elevated_password = var.winrm_password
    scripts           = ["scripts/20-windows-updates.ps1"]
    valid_exit_codes  = [0, 267014]
  }

  provisioner "windows-restart" {
    restart_command = "shutdown /r /t 10 /c \"Packer restart after Windows Update round 2\" /f"
    restart_timeout = "60m"
  }

  provisioner "powershell" {
    elevated_user     = var.winrm_username
    elevated_password = var.winrm_password
    scripts           = ["scripts/20-windows-updates.ps1"]
    valid_exit_codes  = [0, 267014]
  }

  provisioner "windows-restart" {
    restart_command = "shutdown /r /t 10 /c \"Packer restart after Windows Update round 3\" /f"
    restart_timeout = "60m"
  }

  # Validation gate: OS edition, Guest Additions, patch level and pending
  # updates are checked; a broken or unpatched image fails the build. The
  # report is left in the image at C:\ImageBuild and pulled out below.
  provisioner "powershell" {
    elevated_user     = var.winrm_username
    elevated_password = var.winrm_password
    environment_vars = [
      "IMAGE_VERSION=${var.image_version}"
    ]
    scripts = ["scripts/40-validate-image.ps1"]
  }

  # Cleanup: clear temp files, re-arm the firewall (scoped WinRM rule) and
  # sanity-check free space before sysprep.
  provisioner "powershell" {
    elevated_user     = var.winrm_username
    elevated_password = var.winrm_password
    scripts           = ["scripts/80-cleanup.ps1"]
  }

  # Pull the validation report out for the repo's reports/ dir.
  provisioner "file" {
    direction   = "download"
    source      = "C:/ImageBuild/validation-report.json"
    destination = "reports/validation-report.json"
  }

  # Upload the sysprep script the shutdown_command invokes (runs AFTER the
  # report download so sysprep's shutdown can't race it).
  provisioner "file" {
    direction   = "upload"
    source      = "scripts/90-sysprep.ps1"
    destination = "C:/Windows/Temp/90-sysprep.ps1"
  }

  # Release evidence: SHA256SUMS over the exported template plus a manifest
  # recording build metadata (mirrors the ARM64 project's evidence story).
  post-processor "checksum" {
    checksum_types = ["sha256"]
    output         = "SHA256SUMS"
  }

  post-processor "manifest" {
    output     = "manifest.json"
    strip_path = true
    custom_data = {
      image_version = var.image_version
      edition_index = "${var.edition_index}"
      iso_checksum  = var.windows_iso_checksum
      virtualbox_ga = "7.2.20"
    }
  }
}
