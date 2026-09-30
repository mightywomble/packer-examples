packer {
  required_version = ">= 1.10.0"

  required_plugins {
    qemu = {
      source  = "github.com/hashicorp/qemu"
      version = "~> 1.1"
    }
  }
}

source "qemu" "windows11_arm64" {
  iso_url      = var.windows_iso_path
  iso_checksum = var.windows_iso_checksum

  output_directory = "output/windows11-arm64-${var.image_version}"
  vm_name          = "windows11-arm64-golden.qcow2"

  # Wrapper script: rewrites Packer's CD-ROMs to usb-storage (ARM virt has
  # no IDE/SATA), adds qemu-xhci + usb-kbd + usb-tablet + ramfb. Without
  # ramfb the display shows only the QEMU monitor; without usb-kbd Packer's
  # VNC keystrokes go nowhere. See scripts/qemu-wrapper.sh.
  qemu_binary = "scripts/qemu-wrapper.sh"

  machine_type = "virt"
  accelerator  = "kvm"
  cpu_model    = "host"

  cpus      = var.cpus
  memory    = var.memory
  disk_size = var.disk_size
  format    = "qcow2"

  headless = var.headless

  communicator   = "winrm"
  winrm_username = var.winrm_username
  winrm_password = var.winrm_password
  winrm_timeout  = "3h"
  winrm_port     = 5985

  disk_interface = "virtio"
  net_device     = "virtio-net"

  # EFI firmware with Secure Boot support. The qemuvars variant includes
  # SB code and requires -device uefi-vars-sysbus (added by the wrapper).
  # Combined with real vTPM (swtpm + tpm-tis-device in the wrapper),
  # Windows 11's hardware check passes natively.
  efi_boot          = true
  efi_firmware_code = "/usr/share/edk2/aarch64/QEMU_EFI-qemuvars-pflash.raw"
  efi_firmware_vars = "/usr/share/edk2/aarch64/vars-template-pflash.raw"
  vtpm              = false

  # Supplemental ISO: templated Autounattend.xml + WinRM bootstrap script
  # via cd_content, and the ARM64 VirtIO driver tree via cd_files. WinPE
  # loads the bundled viostor/NetKVM drivers via PnpCustomizationsWinPE
  # from the same CD, so it can see the virtio disk before the disk probe.
  cd_content = {
    "Autounattend.xml" = templatefile("answer-files/Autounattend.xml", {
      winrm_username = var.winrm_username
      winrm_password = var.winrm_password
      edition_index  = var.edition_index
    })
    "00-bootstrap-winrm.ps1" = file("scripts/00-bootstrap-winrm.ps1")
    "image-version.txt"      = var.image_version
  }

  # ARM64 VirtIO drivers bundled into the unattend CD. The ./ prefix
  # preserves directory structure so DriverPaths can target drivers/ dir.
  cd_files = [
    "./drivers",
  ]
  cd_label = "UNATTEND"

  shutdown_timeout = "30m"

  shutdown_command = <<-EOF
    powershell.exe -ExecutionPolicy Bypass -File C:\\Windows\\Temp\\90-sysprep.ps1
  EOF

  # The cdboot "Press any key to boot from CD or DVD" prompt arrives
  # nondeterministically: observed anywhere from ~5s to past 200s across
  # runs on 2026-09-29. The driver is the fresh swtpm instance's first-boot
  # TPM2 provisioning (software RSA keygen on emulated ARM - host-load
  # dependent) stretching firmware POST. Two runs missed the window
  # (a 63s window missed at 13:11; a 200s window missed at 22:26), cdboot
  # reset the VM, and the retry fell through to PXE. Spam spacebar every 2s
  # from 3s to ~600s so the prompt is always answered - including across
  # several cdboot timeout-reset cycles if the prompt keeps arriving late.
  # Stray presses during setup phases are harmless (no focused controls;
  # any dialog they summon is dismissed by the next press).
  boot_wait = "3s"
  boot_command = [
    "<spacebar><wait2s><spacebar><wait2s><spacebar><wait2s>",
    "<spacebar><wait2s><spacebar><wait2s><spacebar><wait2s>",
    "<spacebar><wait2s><spacebar><wait2s><spacebar><wait2s>",
    "<spacebar><wait2s><spacebar><wait2s><spacebar><wait2s>",
    "<spacebar><wait2s><spacebar><wait2s><spacebar><wait2s>",
    "<spacebar><wait2s><spacebar><wait2s><spacebar><wait2s>",
    "<spacebar><wait2s><spacebar><wait2s><spacebar><wait2s>",
    "<spacebar><wait2s><spacebar><wait2s><spacebar><wait2s>",
    "<spacebar><wait2s><spacebar><wait2s><spacebar><wait2s>",
    "<spacebar><wait2s><spacebar><wait2s><spacebar><wait2s>",
    "<spacebar><wait2s><spacebar><wait2s><spacebar><wait2s>",
    "<spacebar><wait2s><spacebar><wait2s><spacebar><wait2s>",
    "<spacebar><wait2s><spacebar><wait2s><spacebar><wait2s>",
    "<spacebar><wait2s><spacebar><wait2s><spacebar><wait2s>",
    "<spacebar><wait2s><spacebar><wait2s><spacebar><wait2s>",
    "<spacebar><wait2s><spacebar><wait2s><spacebar><wait2s>",
    "<spacebar><wait2s><spacebar><wait2s><spacebar><wait2s>",
    "<spacebar><wait2s><spacebar><wait2s><spacebar><wait2s>",
    "<spacebar><wait2s><spacebar><wait2s><spacebar><wait2s>",
    "<spacebar><wait2s><spacebar><wait2s><spacebar><wait2s>",
    "<spacebar><wait2s><spacebar><wait2s><spacebar><wait2s>",
    "<spacebar><wait2s><spacebar><wait2s><spacebar><wait2s>",
    "<spacebar><wait2s><spacebar><wait2s><spacebar><wait2s>",
    "<spacebar><wait2s><spacebar><wait2s><spacebar><wait2s>",
    "<spacebar><wait2s><spacebar><wait2s><spacebar><wait2s>",
    "<spacebar><wait2s><spacebar><wait2s><spacebar><wait2s>",
    "<spacebar><wait2s><spacebar><wait2s><spacebar><wait2s>",
    "<spacebar><wait2s><spacebar><wait2s><spacebar><wait2s>",
    "<spacebar><wait2s><spacebar><wait2s><spacebar><wait2s>",
    "<spacebar><wait2s><spacebar><wait2s><spacebar><wait2s>",
    "<spacebar><wait2s><spacebar><wait2s><spacebar><wait2s>",
    "<spacebar><wait2s><spacebar><wait2s><spacebar><wait2s>",
    "<spacebar><wait2s><spacebar><wait2s><spacebar><wait2s>",
    "<spacebar><wait2s><spacebar><wait2s><spacebar><wait2s>",
    "<spacebar><wait2s><spacebar><wait2s><spacebar><wait2s>",
    "<spacebar><wait2s><spacebar><wait2s><spacebar><wait2s>",
    "<spacebar><wait2s><spacebar><wait2s><spacebar><wait2s>",
    "<spacebar><wait2s><spacebar><wait2s><spacebar><wait2s>",
    "<spacebar><wait2s><spacebar><wait2s><spacebar><wait2s>",
    "<spacebar><wait2s><spacebar><wait2s><spacebar><wait2s>",
    "<spacebar><wait2s><spacebar><wait2s><spacebar><wait2s>",
    "<spacebar><wait2s><spacebar><wait2s><spacebar><wait2s>",
    "<spacebar><wait2s><spacebar><wait2s><spacebar><wait2s>",
    "<spacebar><wait2s><spacebar><wait2s><spacebar><wait2s>",
    "<spacebar><wait2s><spacebar><wait2s><spacebar><wait2s>",
    "<spacebar><wait2s><spacebar><wait2s><spacebar><wait2s>",
    "<spacebar><wait2s><spacebar><wait2s><spacebar><wait2s>",
    "<spacebar><wait2s><spacebar><wait2s><spacebar><wait2s>",
    "<spacebar><wait2s><spacebar><wait2s><spacebar><wait2s>",
    "<spacebar><wait2s><spacebar><wait2s><spacebar><wait2s>",
    "<spacebar><wait2s><spacebar><wait2s><spacebar><wait2s>",
    "<spacebar><wait2s><spacebar><wait2s><spacebar><wait2s>",
    "<spacebar><wait2s><spacebar><wait2s><spacebar><wait2s>",
    "<spacebar><wait2s><spacebar><wait2s><spacebar><wait2s>",
    "<spacebar><wait2s><spacebar><wait2s><spacebar><wait2s>",
    "<spacebar><wait2s><spacebar><wait2s><spacebar><wait2s>",
    "<spacebar><wait2s><spacebar><wait2s><spacebar><wait2s>",
    "<spacebar><wait2s><spacebar><wait2s><spacebar><wait2s>",
    "<spacebar><wait2s><spacebar><wait2s><spacebar><wait2s>",
    "<spacebar><wait2s><spacebar><wait2s><spacebar><wait2s>",
    "<spacebar><wait2s><spacebar><wait2s><spacebar><wait2s>",
    "<spacebar><wait2s><spacebar><wait2s><spacebar><wait2s>",
    "<spacebar><wait2s><spacebar><wait2s><spacebar><wait2s>",
    "<spacebar><wait2s><spacebar><wait2s><spacebar><wait2s>",
    "<spacebar><wait2s><spacebar><wait2s><spacebar><wait2s>"
  ]
}

build {
  name    = "windows11-arm64-golden"
  sources = ["source.qemu.windows11_arm64"]

  # Run the provisioning pipeline. Software installs via winget in
  # 10-install-software.ps1 (network downloads in minutes with native
  # ARM64 manifests; the WinRM file upload of the old bundled installers
  # moved ~100MB at ~30KB/s).
  #
  # Elevated (scheduled-task) execution: DISM servicing operations
  # (Add-WindowsCapability in 30-enable-features.ps1) fail with "Access is
  # denied" from the WinRM session's network-logon token even though it
  # is an admin token (observed 2026-09-30: machine-wide MSI installs and
  # HKLM writes succeed in the same session, but the CBS/servicing stack
  # rejects the session type). elevated_user/elevated_password make
  # Packer run the scripts via a scheduled task with a full elevation
  # token, which the servicing stack accepts.
  provisioner "powershell" {
    elevated_user     = var.winrm_username
    elevated_password = var.winrm_password
    environment_vars = [
      "IMAGE_VERSION=${var.image_version}"
    ]
    scripts = [
      "scripts/10-install-software.ps1",
      "scripts/20-apply-policies.ps1",
      "scripts/30-enable-features.ps1",
      "scripts/40-validate-image.ps1",
      "scripts/80-cleanup.ps1"
    ]
  }

  # Copy the sysprep script for the shutdown_command to invoke.
  provisioner "file" {
    source      = "scripts/90-sysprep.ps1"
    destination = "C:/Windows/Temp/90-sysprep.ps1"
  }
}
