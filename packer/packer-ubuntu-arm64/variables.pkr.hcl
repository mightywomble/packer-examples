# Variable declarations for the Ubuntu 26.04 arm64 Packer build.
# Values are supplied via ubuntu-26.04-arm64.auto.pkrvars.hcl (gitignored).

variable "ubuntu_iso_path" {
  type        = string
  description = "Path to the Ubuntu 26.04 live-server arm64 ISO."
}

variable "ubuntu_iso_checksum" {
  type        = string
  description = "SHA256 checksum of the Ubuntu ISO, prefixed with 'sha256:'."
}

variable "image_version" {
  type        = string
  default     = "1.0.0"
  description = "Semver stamped into the output directory name."
}

variable "build_user" {
  type        = string
  default     = "ubuntu"
  description = "Build account created by autoinstall (NOPASSWD sudo via late-commands)."
}

variable "headless" {
  type        = bool
  default     = false
  description = "When true, QEMU runs without a GUI window (fully-automated build)."
}

variable "cpus" {
  type    = number
  default = 4
}

variable "memory" {
  type    = number
  default = 4096
}

variable "disk_size" {
  type    = string
  default = "20G"
}
