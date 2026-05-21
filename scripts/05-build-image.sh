#!/bin/bash
#
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Copyright (C) 2025 Vasiliy Kovalev <kovalev@altlinux.org>

set -exo pipefail
source "$(dirname "$0")/01-setup-env.sh"

# --- CONFIGURATION ---
# List of packages to install (space-separated)
PACKAGES_TO_INSTALL=""
# PACKAGES_TO_INSTALL="gcc-c++ lcov nano bash-completion"
# --------------------

help() {
    echo "Usage: $0"
    echo "Downloads a base image, mounts it, installs the custom-built kernel,"
    echo "installs build tools via chroot, and sets up SSH access."
}

if [[ "$1" == "-h" || "$1" == "--help" ]]; then
    help
    exit 0
fi

# Function for clean unmounting of virtual filesystems (/dev, /sys, /proc)
cleanup() {
    echo "--> Running cleanup (unmounting /dev, /sys, /proc)..."
    # Unmount system directories only if they are mounted
    if mountpoint -q "$IMAGE_MOUNT_DIR/proc"; then
        sudo umount "$IMAGE_MOUNT_DIR/proc"
    fi
    if mountpoint -q "$IMAGE_MOUNT_DIR/sys"; then
        sudo umount "$IMAGE_MOUNT_DIR/sys"
    fi
    if mountpoint -q "$IMAGE_MOUNT_DIR/dev"; then
        sudo umount "$IMAGE_MOUNT_DIR/dev"
    fi
    sudo umount "$IMAGE_MOUNT_DIR"
}

# Register cleanup function to run upon any exit (SUCCESS or FAILURE)
trap cleanup EXIT

echo "▶ Starting guest image preparation..."

mkdir -p "$IMAGE_DIR" "$IMAGE_MOUNT_DIR"
cd "$IMAGE_DIR"

# 1. Download and extract the image
if [ ! -f "$IMAGE_PATH" ]; then
    echo "Downloading guest image..."
    wget --no-check-certificate --progress=dot:mega "$IMAGE_BASE_URL/$IMAGE_FILENAME.xz"
    unxz "./$IMAGE_FILENAME.xz"
    # Needed for C repro generation
    PACKAGES_TO_INSTALL="gcc"
else
    echo "Guest image $IMAGE_PATH already exists. Skipping download."
fi

# 2. Mount the image partition
echo "Mounting the image file system..."
SECTOR_SIZE=$(sudo fdisk -l "$IMAGE_PATH" | awk '/^Units:/ {print $8}')
OFFSET=$(sudo fdisk -l "$IMAGE_PATH" | awk -v size="$SECTOR_SIZE" '/img3/ {print $2 * size}')
sudo mount -o loop,offset="$OFFSET" "$IMAGE_PATH" "$IMAGE_MOUNT_DIR"

# 3. Install kernel and modules
echo "Installing kernel and modules into the image..."
cd "$KERNEL_BUILD_DIR"
sudo make INSTALL_PATH="$IMAGE_MOUNT_DIR/boot" -j"$(nproc)" install
sudo rm -rf "$IMAGE_MOUNT_DIR/lib/modules/"*
sudo make INSTALL_MOD_PATH="$IMAGE_MOUNT_DIR" -j"$(nproc)" modules_install

# 4. Setup SSH key for passwordless access
if [ ! -f "$SSH_KEY_PATH" ]; then
    echo "Generating SSH key..."
    ssh-keygen -t rsa -f "$SSH_KEY_PATH" -N ""
fi
sudo mkdir -p "$IMAGE_MOUNT_DIR/root/.ssh"
sudo cp "$SSH_KEY_PATH.pub" "$IMAGE_MOUNT_DIR/root/.ssh/authorized_keys"
sudo chmod 700 "$IMAGE_MOUNT_DIR/root/.ssh"
sudo chmod 600 "$IMAGE_MOUNT_DIR/root/.ssh/authorized_keys"

# 5. Install packages to image
if [ -n "$PACKAGES_TO_INSTALL" ]; then
    echo "Installing packages ($PACKAGES_TO_INSTALL) via chroot..."
    # Prepare chroot environment by mounting necessary virtual filesystems
    sudo mount --bind /dev "$IMAGE_MOUNT_DIR/dev"
    sudo mount --bind /sys "$IMAGE_MOUNT_DIR/sys"
    sudo mount -t proc /proc "$IMAGE_MOUNT_DIR/proc"

    # Fix DNS resolution inside chroot
    sudo rm -f "$IMAGE_MOUNT_DIR/etc/resolv.conf"
    sudo cp /etc/resolv.conf "$IMAGE_MOUNT_DIR/etc/resolv.conf"
    # Execute installation inside chroot
    sudo chroot "$IMAGE_MOUNT_DIR" /bin/bash -c "apt-get update && apt-get install -y $PACKAGES_TO_INSTALL && apt-get clean"

    # The cleanup function (trap) will automatically unmount /dev, /sys, /proc here.
else
    echo "The list of packages is empty. Installation skipped."
fi

# 6. Copy syzkaller/bin/linux_amd64 to image
sudo cp -rf "$SYZKALLER_DIR/bin/linux_amd64" "$IMAGE_MOUNT_DIR/bin/"

# 7. Remove vfat mount to avoid conflicts on boot
sudo sed -i '/vfat/d' "$IMAGE_MOUNT_DIR/etc/fstab"

# ------------------------------------------------
# drivers_gpio
# 8. Create gpio-sim boot setup script and invoke it from rc.local
#
# Creates two configfs devices in the guest on every boot:
#   syz  - live, 8 named lines (syz-line-0..7), exposes /dev/gpiochip0
#   syz0 - non-live (bank0/line0..3/hog + bank1) for fuzzer
#          machine-check: paths in syz descriptions must exist at start

sudo tee "$IMAGE_MOUNT_DIR/usr/local/bin/setup-gpio-sim.sh" > /dev/null << 'END_OF_SETUP_SCRIPT'
#!/bin/bash
set -u

mountpoint -q /sys/kernel/config 2>/dev/null || mount -t configfs none /sys/kernel/config

modprobe gpio-sim        2>/dev/null || true
modprobe gpio-aggregator 2>/dev/null || true

for i in $(seq 1 50); do
    [ -d /sys/kernel/config/gpio-sim ] && break
    sleep 0.1
done

ROOT=/sys/kernel/config/gpio-sim

# Tear down any leftover from previous boot
for DEV in syz syz0 syz1 syz2 syz3; do
    [ -d $ROOT/$DEV ] || continue
    echo 0 > $ROOT/$DEV/live 2>/dev/null || true
    rmdir $ROOT/$DEV/*/line*/hog 2>/dev/null || true
    rmdir $ROOT/$DEV/*/line*     2>/dev/null || true
    rmdir $ROOT/$DEV/*           2>/dev/null || true
    rmdir $ROOT/$DEV             2>/dev/null || true
done

# LIVE device "syz" : provides /dev/gpiochip0
mkdir -p $ROOT/syz/bank0
echo 8         > $ROOT/syz/bank0/num_lines
echo syz-bank0 > $ROOT/syz/bank0/label
for i in 0 1 2 3 4 5 6 7; do
    mkdir -p $ROOT/syz/bank0/line$i
    echo "syz-line-$i" > $ROOT/syz/bank0/line$i/name
done
echo 1 > $ROOT/syz/live
chmod 666 /dev/gpiochip0 2>/dev/null || true

# NOT LIVE gpio-sim device "syz0" : satisfies machine-check probes
mkdir -p $ROOT/syz0/bank0
echo 4              > $ROOT/syz0/bank0/num_lines
echo scaffold-bank0 > $ROOT/syz0/bank0/label
for i in 0 1 2 3; do
    mkdir -p $ROOT/syz0/bank0/line$i/hog
    echo "scaffold-line-$i" > $ROOT/syz0/bank0/line$i/name
    echo "hog-$i"           > $ROOT/syz0/bank0/line$i/hog/name
    echo input              > $ROOT/syz0/bank0/line$i/hog/direction
done
mkdir -p $ROOT/syz0/bank1
echo 4 > $ROOT/syz0/bank1/num_lines
exit 0
END_OF_SETUP_SCRIPT

sudo chmod +x "$IMAGE_MOUNT_DIR/usr/local/bin/setup-gpio-sim.sh"

RC_LOCAL_DIR="$IMAGE_MOUNT_DIR/etc/rc.d"
RC_LOCAL_SCRIPT="$RC_LOCAL_DIR/rc.local"
SCRIPT_BLOCK='
# drivers_gpio
/usr/local/bin/setup-gpio-sim.sh
'

sudo mkdir -p "$RC_LOCAL_DIR"
if [ ! -f "$RC_LOCAL_SCRIPT" ]; then
    echo '#!/bin/bash'     | sudo tee    "$RC_LOCAL_SCRIPT"
    echo "${SCRIPT_BLOCK}" | sudo tee -a "$RC_LOCAL_SCRIPT"
    sudo chmod +x "$RC_LOCAL_SCRIPT"
else
    if ! sudo grep -q '# drivers_gpio' "$RC_LOCAL_SCRIPT"; then
        echo "${SCRIPT_BLOCK}" | sudo tee -a "$RC_LOCAL_SCRIPT"
    fi
fi

# ------------------------------------------------

# END. Final adjustments and unmount
echo "Unmounting main image partition..."
echo "✅ Guest image is ready at: $IMAGE_PATH"

# trap cleanup EXIT unmount all
