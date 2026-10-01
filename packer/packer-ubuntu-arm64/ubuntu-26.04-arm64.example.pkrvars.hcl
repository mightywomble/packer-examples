# Copy to ubuntu-26.04-arm64.auto.pkrvars.hcl and fill in real values.
# The auto file is gitignored (*.auto.pkrvars.hcl).

ubuntu_iso_path = "/home/david/ISO/ubuntu-26.04.1-live-server-arm64.iso"

# Compute with: sha256sum <path-to-iso>
ubuntu_iso_checksum = "sha256:REPLACE_WITH_REAL_SHA256"

image_version = "1.0.0"
