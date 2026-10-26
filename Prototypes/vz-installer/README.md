# vz-installer: spike for creating a Lima VM from an installer ISO

Lima only boots cloud images, but its files can be written by anyone. This spike boots an
installer ISO with Virtualization.framework straight into a Lima instance's `disk`, so the
installed OS ends up where Lima expects it; after a one-line fix-up in the guest, `limactl start`
takes over as if it were a regular Lima VM. Results: docs/07-iso-install-investigation.md. The app's copy of the fix-up script (`InstallerFixup` in LimaKit) is the canonical one; `limaify.sh` here is the spike's snapshot.

```sh
# 1. A Lima instance with a blank disk of the wanted size (1 MiB placeholder image).
mkfile -n 1m placeholder.raw
limactl create --tty=false --name=NAME --cpus=2 --memory=4 --disk=20 --vm-type=vz \
  --set '.images = [{"location": "'$PWD'/placeholder.raw", "arch": "aarch64"}]' template:default

# 2. The helper ISO (label HANALIMA): limaify.sh, Lima's public key, the user name.
mkdir -p helper && cp limaify.sh ~/.lima/_config/user.pub helper/ && id -un > helper/user
hdiutil makehybrid -iso -joliet -default-volume-name HANALIMA -o helper.iso helper

# 3. Build, sign, and boot the installer into the instance's disk (a window opens).
swiftc -O -o vz-installer main.swift -framework Virtualization -framework AppKit
codesign -s - -f --entitlements entitlements.plist vz-installer
./vz-installer --name NAME --iso ubuntu-26.04-live-server-arm64.iso --helper helper.iso

# 4. Install by hand (plain ext4, OpenSSH server). After the reboot, log in and run:
#      sudo mount -L HANALIMA /mnt && sudo sh /mnt/limaify.sh && sudo poweroff
# 5. Back to Lima.
limactl start NAME
```
