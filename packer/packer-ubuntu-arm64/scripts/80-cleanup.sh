#!/bin/sh
# 80-cleanup.sh - final lockdown + cleanup for the Ubuntu LAMP golden
# image. Invoked by Packer's shutdown_command (as root, via sudo) as the
# very LAST action, because it removes the credentials Packer would
# otherwise need to open a separate SSH session for the shutdown step.
# Always exits cleanly so the build never wedges on cleanup; the VM
# powers off at the end of this script.
#
# Usage: 80-cleanup.sh [build-user]   (default: ubuntu)
# ASCII only (repo rule: guest-executed files must be pure ASCII).
set -u

USER_NAME="${1:-ubuntu}"
FAIL=0

# Lock the demo build password and remove the build SSH key. The image
# ships with no working credentials; consumers inject access via a
# cloud-init NoCloud seed on the first boot of a clone (see README).
passwd -l "$USER_NAME" || FAIL=1
rm -f "/home/$USER_NAME/.ssh/authorized_keys" || FAIL=1

# Reset cloud-init so the image accepts a NoCloud seed on the next boot:
# subiquity otherwise pins datasource_list to [None] in
# /etc/cloud/cloud.cfg.d/99-installer.cfg and blocks re-configuration
# (subiquity >= 22.10.1 supports 'cloud-init clean' removing it).
cloud-init clean --logs || FAIL=1

# Light hygiene. No disk zeroing - repo lesson: never fill the disk
# (compaction is handled host-side by qemu-img if ever needed).
apt-get clean || true
journalctl --rotate >/dev/null 2>&1 || true
journalctl --vacuum-time=1s >/dev/null 2>&1 || true
for f in /var/log/syslog /var/log/auth.log /var/log/kern.log /var/log/apport.log; do
  if [ -f "$f" ]; then truncate -s 0 "$f" || true; fi
done

echo "80-cleanup: password locked, build key removed, cloud-init reset (issues: ${FAIL})"
sleep 2

# Power off. Packer waits for the VM to disappear.
systemctl poweroff || shutdown -P now || poweroff
