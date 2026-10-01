packer {
  required_version = ">= 1.10.0"

  required_plugins {
    qemu = {
      source  = "github.com/hashicorp/qemu"
      version = "~> 1.1"
    }
    ansible = {
      source  = "github.com/hashicorp/ansible"
      version = "~> 1.0"
    }
  }
}

source "qemu" "ubuntu_26_04_arm64" {
  iso_url      = var.ubuntu_iso_path
  iso_checksum = var.ubuntu_iso_checksum

  output_directory = "output/ubuntu-26.04-arm64-${var.image_version}"
  vm_name          = "ubuntu-26.04-arm64.qcow2"

  # Wrapper script (see scripts/qemu-wrapper.sh): rewrites Packer CD-ROMs
  # to usb-storage (ARM virt has no IDE/SATA, so the default CD attachment
  # is invisible to the firmware), adds qemu-xhci controllers + usb-kbd +
  # usb-tablet (VNC keystroke injection) + ramfb (display). No swtpm/TPM
  # and no Secure Boot firmware needed for Ubuntu server.
  qemu_binary = "scripts/qemu-wrapper.sh"

  machine_type = "virt"
  accelerator  = "kvm"
  cpu_model    = "host"

  cpus      = var.cpus
  memory    = var.memory
  disk_size = var.disk_size
  format    = "qcow2"

  headless = var.headless

  communicator         = "ssh"
  ssh_username         = var.build_user
  ssh_password         = "ubuntu" # demo fallback auth; key auth is primary
  ssh_private_key_file = "keys/build_ed25519"
  ssh_timeout          = "60m"

  disk_interface = "virtio"
  net_device     = "virtio-net"

  # Plain EDK2 aarch64 firmware (no Secure Boot needed). Packer copies
  # the vars image so the guest can persist EFI variables.
  efi_boot          = true
  efi_firmware_code = "/usr/share/edk2/aarch64/QEMU_EFI-pflash.raw"
  efi_firmware_vars = "/usr/share/edk2/aarch64/vars-template-pflash.raw"

  # Autoinstall seed as a second CD labeled 'cidata': cloud-init's NoCloud
  # datasource finds it by label (no HTTP server needed), and cd_content
  # lets the seed be templated with the build public key at build time.
  cd_content = {
    "user-data" = templatefile("seed/user-data.tftpl", {
      build_pubkey = trimspace(file("keys/build_ed25519.pub"))
    })
    "meta-data" = file("seed/meta-data")
  }
  cd_label = "cidata"

  # No boot_command: the ISO's own GRUB menu times out (30s) and boots
  # the default entry into the installer - no keystroke timing involved
  # (VNC keystroke edits proved timing-fragile on this host; QEMU -kernel
  # boot re-ran the installer in a loop - see scripts/qemu-wrapper.sh
  # notes 7-8). The wrapper gives the build disk bootindex=0 (EDK2 boots
  # the installed system on the post-install reboot), and its
  # scripts/autoconfirm.py watchdog answers subiquity's one safety prompt
  # ("Continue with autoinstall? (yes|no)") via QMP once the cidata seed
  # is found.

  # 80-cleanup.sh locks the build credentials, so the shutdown step runs
  # it itself - the VM powers off at the end of the script.
  shutdown_command = "sudo sh /tmp/80-cleanup.sh ${var.build_user}"
  shutdown_timeout = "30m"
}

build {
  name    = "ubuntu-26-04-arm64-lamp"
  sources = ["source.qemu.ubuntu_26_04_arm64"]

  # Cross-platform (Debian/RedHat) LAMP provisioning. Packer generates
  # the inventory and uses the communicator's key; -v for verbose task
  # output.
  provisioner "ansible" {
    playbook_file   = "ansible/site.yml"
    extra_arguments = ["-v"]
    ansible_env_vars = [
      "ANSIBLE_CONFIG=ansible/ansible.cfg",
      "ANSIBLE_HOST_KEY_CHECKING=False",
    ]
  }

  # Pull the in-image validation report out for the repo's reports/ dir.
  provisioner "file" {
    direction   = "download"
    source      = "/var/lib/image-build/validation-report.json"
    destination = "reports/validation-report.json"
  }

  # Upload the final lockdown/cleanup script; shutdown_command runs it as
  # the very last action (it removes the credentials Packer would need
  # for a separate shutdown step, so it must power off the VM itself).
  provisioner "file" {
    direction   = "upload"
    source      = "scripts/80-cleanup.sh"
    destination = "/tmp/80-cleanup.sh"
  }
}
