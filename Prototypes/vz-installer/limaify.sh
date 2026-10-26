#!/bin/sh
# HanaLima: prepares an OS installed from an ISO for Lima. Installs cloud-init and sshd and lets
# NoCloud run, so at the next boot Lima's cidata.iso sets up its user, key, guest agent, shares
# and provisioning, as for any Lima VM. Run once, as root, from the installed OS:
#   sudo mount -L HANALIMA /mnt && sudo sh /mnt/limaify.sh
set -eu
[ "$(id -u)" = 0 ] || { echo "run with sudo" >&2; exit 1; }
D=$(cd "$(dirname "$0")" && pwd)
if command -v apt-get >/dev/null 2>&1; then
  export DEBIAN_FRONTEND=noninteractive; apt-get update; apt-get install -y cloud-init openssh-server
elif command -v dnf >/dev/null 2>&1; then dnf install -y cloud-init openssh-server
elif command -v apk >/dev/null 2>&1; then apk add cloud-init openssh
elif command -v pacman >/dev/null 2>&1; then pacman -Sy --noconfirm cloud-init openssh
fi
if command -v cloud-init >/dev/null 2>&1; then
  # Installers (Ubuntu's subiquity) may pin the datasource or switch cloud-init off.
  rm -f /etc/cloud/cloud-init.disabled /etc/cloud/cloud.cfg.d/99-installer.cfg /etc/cloud/cloud.cfg.d/90-installer-network.cfg
  printf 'datasource_list: [ NoCloud, None ]\n' > /etc/cloud/cloud.cfg.d/95-hanalima.cfg
  cloud-init clean --logs
  echo "cloud-init is ready: Lima configures this VM at the next boot."
else
  # No cloud-init available: Lima's user and key, so limactl can ssh in (no guest agent, so
  # shares and port forwards won't work).
  U=$(cat "$D/user")
  id "$U" >/dev/null 2>&1 || useradd -m -u 501 -s /bin/sh "$U" 2>/dev/null || adduser -D -u 501 "$U"
  mkdir -p "/home/$U/.ssh"; cat "$D/user.pub" >> "/home/$U/.ssh/authorized_keys"
  chown -R "$U" "/home/$U/.ssh"; chmod 700 "/home/$U/.ssh"; chmod 600 "/home/$U/.ssh/authorized_keys"
  mkdir -p /etc/sudoers.d; echo "$U ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/$U"; chmod 440 "/etc/sudoers.d/$U"
  (systemctl enable ssh || systemctl enable sshd || rc-update add sshd) >/dev/null 2>&1 || true
  echo "sshd and Lima's user are ready (no cloud-init on this system)."
fi
sync
echo "Done. Shut the VM down now: sudo poweroff"
