# Variable declarations for the Windows Server 2019 x64 VirtualBox build.
# Values are supplied via windows2019-x64.auto.pkrvars.hcl (gitignored,
# contains the build password).

variable "windows_iso_path" {
  type        = string
  description = "Path to the Windows Server 2019 EVAL x64 installation ISO."
}

variable "windows_iso_checksum" {
  type        = string
  description = "SHA256 checksum of the Windows ISO, prefixed with 'sha256:'."
}

variable "image_version" {
  type        = string
  default     = "1.0.0"
  description = "Semver stamped into the output directory and image-version.txt."
}

variable "edition_index" {
  type        = number
  default     = 2
  description = "install.wim image index on the EVAL ISO (verified with wimlib-imagex info): 1=Standard Core, 2=Standard Desktop Experience, 3=Datacenter Core, 4=Datacenter Desktop Experience."
}

variable "winrm_username" {
  type        = string
  default     = "Administrator"
  description = "Account Packer uses for WinRM. Windows Server unattend uses the built-in Administrator account (set via AdministratorPassword in oobeSystem)."
}

variable "winrm_password" {
  type        = string
  sensitive   = true
  description = "Password for the local Administrator account. Must meet Windows complexity: uppercase, lowercase, digit, special."
}

variable "vm_template_format" {
  type        = string
  default     = "ova"
  description = "Export format for the pushed-out template: 'ova' (single-file appliance) or 'ovf' (unpacked directory)."

  validation {
    condition     = contains(["ova", "ovf"], var.vm_template_format)
    error_message = "The vm_template_format must be 'ova' or 'ovf'."
  }
}

variable "headless" {
  type        = bool
  default     = false
  description = "When true, VirtualBox runs without a GUI window (fully-automated build)."
}

variable "cpus" {
  type    = number
  default = 4
}

variable "memory" {
  type    = number
  default = 8192
}

variable "disk_size" {
  type    = number
  default = 81920
}
