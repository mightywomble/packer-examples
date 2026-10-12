# packer_demo

A collection of Packer build projects producing reproducible "golden image"
virtual-machine disks, each generated entirely from version-controlled code.

The builds run on QEMU/KVM on an Asahi Linux (Apple Silicon aarch64) host.
Each project lives under `packer/` with its own README covering its
architecture, build instructions, and troubleshooting journey.

## Projects

- [packer-windows-arm64](packer/packer-windows-arm64/) - A Sysprep-generalized
  Windows 11 ARM64 QCOW2 golden image built with Packer on QEMU/KVM, with
  validation evidence and checksums. Full details in the
  [project README](packer/packer-windows-arm64/README.md).
- [packer-ubuntu-arm64](packer/packer-ubuntu-arm64/) - An Ubuntu 26.04 ARM64
  LAMP golden image built with Packer + Ansible on QEMU/KVM. Full details in
  the [project README](packer/packer-ubuntu-arm64/README.md).
- [packer-windows2019-x64](packer/packer-windows2019-x64/) - A patched,
  Sysprep-generalized Windows Server 2019 x64 template built with Packer on
  the host's VirtualBox and exported as an OVA appliance. Full details in the
  [project README](packer/packer-windows2019-x64/README.md).

## Repository layout

```
packer_demo/
├── files/                       # Source media (gitignored - large ISOs)
├── packer/                      # One directory per Packer build project
│   ├── scope.txt                # Original build scope / steps
│   ├── packer-ubuntu-arm64/
│   ├── packer-windows-arm64/
│   └── packer-windows2019-x64/  # x64 VirtualBox builds (host VirtualBox)
└── README.md
```

Note: the ARM64 projects build on QEMU/KVM; `packer-windows2019-x64` builds
on the VirtualBox installed on the local host.

## Source media

Projects reference Windows and virtio-win ISOs stored in `files/` (gitignored
due to size). See the individual project READMEs for the exact files required.
