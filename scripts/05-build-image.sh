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
    # netlabelctl is needed by the CIPSO DOI unit installed in step 5b below.
    # NOTE: this only runs on a fresh image download. If $IMAGE_PATH already
    # exists, install it by hand once:
    #   ./scripts/ssh-to-vm.sh 'apt-get update && apt-get install -y netlabel_tools'
    if [ "${SYZ_CONFIG_TEMPLATE:-}" = "netfilter-addons" ]; then
        PACKAGES_TO_INSTALL="$PACKAGES_TO_INSTALL netlabel_tools"
    fi
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

# 5. Configure automatic root login on the serial console (ttyS0).
echo "Configuring serial console autologin..."
GETTY_DROP="$IMAGE_MOUNT_DIR/etc/systemd/system/serial-getty@ttyS0.service.d"
sudo mkdir -p "$GETTY_DROP"
sudo tee "$GETTY_DROP/autologin.conf" > /dev/null << 'AUTOLOGIN'
[Service]
# Clear the inherited ExecStart before overriding it (systemd requirement).
ExecStart=
ExecStart=-/sbin/agetty --autologin root --keep-baud 115200,38400,9600 %I $TERM
AUTOLOGIN

# 5b. Register a CIPSO DOI at boot (netfilter-addons / ipt-so).
#
# ip_options_compile() hands every IPOPT_CIPSO option to cipso_v4_validate(),
# which fails with -EINVAL when the DOI is not registered; the packet is then
# dropped with ICMP_PARAMETERPROB long before it reaches any netfilter hook.
# xt_so has no .checkentry, so its entire 64 lines live in the packet path --
# without a registered DOI parse_cipso() / copy_msb0_bits() / bitrev64() are
# unreachable by construction, no matter how many labelled packets
# syz_emit_ethernet emits.
# The Astra/IPOPT_SEC path needs no registration: it falls into the default
# branch of ip_options_compile() and is simply skipped.
if [ "${SYZ_CONFIG_TEMPLATE:-}" = "netfilter-addons" ]; then
    echo "Installing CIPSO DOI registration unit..."
    sudo tee "$IMAGE_MOUNT_DIR/etc/systemd/system/syz-cipso-doi.service" > /dev/null << 'CIPSO'
[Unit]
Description=Register a CIPSO DOI so that labelled packets reach netfilter
After=local-fs.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'netlabelctl cipso add pass doi:1 tags:1 || true'
ExecStart=/bin/sh -c 'netlabelctl unlbl setdef address:0.0.0.0/0 label:unlabelled || true'

[Install]
WantedBy=multi-user.target
CIPSO
    sudo mkdir -p "$IMAGE_MOUNT_DIR/etc/systemd/system/multi-user.target.wants"
    sudo ln -sf /etc/systemd/system/syz-cipso-doi.service \
        "$IMAGE_MOUNT_DIR/etc/systemd/system/multi-user.target.wants/syz-cipso-doi.service"
fi

# 6. Install packages to image
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

# 7. Copy syzkaller/bin/linux_amd64 to image
sudo cp -rf "$SYZKALLER_DIR/bin/linux_amd64" "$IMAGE_MOUNT_DIR/bin/"

# 8. Remove vfat mount to avoid conflicts on boot
sudo sed -i '/vfat/d' "$IMAGE_MOUNT_DIR/etc/fstab"

# END. Final adjustments and unmount
echo "Unmounting main image partition..."
echo "✅ Guest image is ready at: $IMAGE_PATH"

# trap cleanup EXIT unmount all
