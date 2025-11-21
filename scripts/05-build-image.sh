#!/bin/bash
#
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Copyright (C) 2025 Vasiliy Kovalev <kovalev@altlinux.org>

set -exo pipefail
source "$(dirname "$0")/01-setup-env.sh"

# --- CONFIGURATION ---
# List of packages to install (space-separated)
# PACKAGES_TO_INSTALL=""
PACKAGES_TO_INSTALL="gcc-c++ nano bash_completion"
# Target image size in GB
TARGET_IMAGE_SIZE_GB=8
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
    if mountpoint -q "$IMAGE_MOUNT_DIR"; then
        sudo umount "$IMAGE_MOUNT_DIR"
    fi
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
else
    echo "Guest image $IMAGE_PATH already exists. Skipping download."
fi

# 1.1 Expand image to target size
CURRENT_SIZE=$(stat -c%s "$IMAGE_PATH")
TARGET_SIZE=$((TARGET_IMAGE_SIZE_GB * 1024 * 1024 * 1024))
if [ "$CURRENT_SIZE" -lt "$TARGET_SIZE" ]; then
    echo "Expanding image from $(($CURRENT_SIZE / 1024 / 1024 / 1024))GB to ${TARGET_IMAGE_SIZE_GB}GB..."
    dd if=/dev/zero bs=1M count=$(((TARGET_SIZE - CURRENT_SIZE) / 1024 / 1024)) >> "$IMAGE_PATH"

    # Get partition info
    PART_START=$(sudo fdisk -l "$IMAGE_PATH" | grep img3 | awk '{print $2}')

    # Resize GPT partition using sgdisk or parted
    echo "Resizing partition img3..."
    if command -v sgdisk &> /dev/null; then
        # Using sgdisk (GPT)
        sudo sgdisk -d 3 "$IMAGE_PATH"
        sudo sgdisk -n 3:${PART_START}:0 -t 3:8300 "$IMAGE_PATH"
    else
        # Using parted as fallback
        sudo parted "$IMAGE_PATH" resizepart 3 100%
    fi

    # Setup loop device and resize filesystem
    LOOP_DEV=$(sudo losetup -f --show "$IMAGE_PATH")
    sudo partprobe "$LOOP_DEV"
    sleep 1

    # Check if partition device exists
    if [ ! -b "${LOOP_DEV}p3" ]; then
        echo "Error: ${LOOP_DEV}p3 not found, trying kpartx..."
        sudo kpartx -a "$LOOP_DEV"
        PART_DEV="/dev/mapper/$(basename $LOOP_DEV)p3"
    else
        PART_DEV="${LOOP_DEV}p3"
    fi

    sudo e2fsck -f -y "$PART_DEV" || true
    sudo resize2fs "$PART_DEV"

    # Cleanup
    if [ -b "/dev/mapper/$(basename $LOOP_DEV)p3" ]; then
        sudo kpartx -d "$LOOP_DEV"
    fi
    sudo losetup -d "$LOOP_DEV"
    echo "Image expanded successfully."
else
    echo "Image size is already ${TARGET_IMAGE_SIZE_GB}GB or larger. Skipping expansion."
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

# END. Final adjustments and unmount
echo "Unmounting main image partition..."
echo "✅ Guest image is ready at: $IMAGE_PATH"

# trap cleanup EXIT unmount all
