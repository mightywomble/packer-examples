# Variable declarations for the Windows 11 ARM64 Packer build.
# Values are supplied via windows11-arm64.auto.pkrvars.hcl (gitignored).

variable "windows_iso_path" {
  type        = string
  description = "Path to the Windows 11 ARM64 installation ISO."
}

variable "windows_iso_checksum" {
  type        = string
  description = "SHA256 checksum of the Windows ISO, prefixed with 'sha256:'."
}

variable "virtio_iso_path" {
  type        = string
  description = "Path to the virtio-win driver ISO."
}

variable "virtio_iso_checksum" {
  type        = string
  description = "SHA256 checksum of the virtio-win ISO, prefixed with 'sha256:'."
}

variable "image_version" {
  type        = string
  default     = "1.0.0"
  description = "Semver stamped into the output directory and image-version.txt."
}

variable "edition_index" {
  type        = number
  default     = 3
  description = "install.wim image index. 1=Home, 2=Home SL, 3=Pro."
}

variable "winrm_username" {
  type        = string
  default     = "packer"
  description = "Local admin account Packer uses for WinRM."
}

variable "winrm_password" {
  type        = string
  sensitive   = true
  description = "Password for the local admin account. Must meet Windows complexity."
}

variable "headless" {
  type        = bool
  default     = false
  description = "When true, QEMU runs without GUI (fully-automated build)."
}

variable "cpus" {
  type    = number
  default = 6
}

variable "memory" {
  type    = number
  default = 8192
}

variable "disk_size" {
  type    = string
  default = "80G"
}
