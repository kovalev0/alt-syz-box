#!/bin/bash
#
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Copyright (C) 2025 Vasiliy Kovalev <kovalev@altlinux.org>

# --- Environment Setup Script ---
# This script defines all necessary environment variables for the fuzzing setup.
# Modify the variables in the "User Configuration" section to fit your needs.

# --- ⚙️ User Configuration ---
export TERM="xterm-256color"

# General kernel local verion
export KERNEL_LOCALVERSION="alt-syz-box-altsp-6.12"

# Select which syzkaller config template to use from 'config/syzkaller/'
export SYZ_CONFIG_TEMPLATE="altsp-6.12"

# ALT Linux branch ('p11', 'p10', 'sisyphus', etc.)
export ALT_BRANCH="p11"

# Container repo directory with all scripts and patches
export CONTAINER_REPO_DIR="/home/user/alt-syz-box"

# ------------------------

# Kernel git repository URL and tag/branch
# Default is ALT Linux kernel, but you can change it to mainline or any other kernel
export KERNEL_GIT_URL="git://git.altlinux.org/people/kernelbot/packages/kernel-image.git"
export KERNEL_GIT_TAG="kernel-image-6.12-6.12.85-alt0.c10f.2"

# To use the LVC fork version, uncomment these lines:
# export KERNEL_GIT_URL="https://git.linuxtesting.ru/pub/scm/linux/kernel/git/lvc/linux-stable.git"
# export KERNEL_GIT_TAG="linux-6.12-lvc"
# export KERNEL_GIT_TAG="linux-6.1-lvc"
# export KERNEL_GIT_TAG="linux-5.10-lvc"
# export KERNEL_GIT_TAG="v6.12.57-lvc6"
# export KERNEL_GIT_TAG="v6.1.157-lvc37"
# export KERNEL_GIT_TAG="v5.10.245-lvc65"

# To use the upstream linux-next version, uncomment these lines:
# export KERNEL_GIT_URL="https://git.kernel.org/pub/scm/linux/kernel/git/next/linux-next.git"
# export KERNEL_GIT_TAG="master"

# Linus github repos
#export KERNEL_GIT_URL="https://github.com/torvalds/linux.git"
#export KERNEL_GIT_TAG="master"

# kernel/git/netdev/net.git
# export KERNEL_GIT_URL="git://git.kernel.org/pub/scm/linux/kernel/git/netdev/net.git"
# export KERNEL_GIT_URL="https://git.kernel.org/pub/scm/linux/kernel/git/netdev/net.git"
# export KERNEL_GIT_TAG="main"

# To use the upstream stable version, uncomment these lines:
# export KERNEL_GIT_URL="https://github.com/gregkh/linux.git"
# export KERNEL_GIT_TAG="v6.17"
# export KERNEL_GIT_TAG="v6.12.56"
# export KERNEL_GIT_TAG="v6.6.115"
# export KERNEL_GIT_TAG="v6.1.158"
# export KERNEL_GIT_TAG="v5.15.196"
# export KERNEL_GIT_TAG="v5.10.246"
# export KERNEL_GIT_TAG="master"

# ------------------------

# QEMU repository. Default is upstream version
export QEMU_GIT_URL="https://github.com/qemu/qemu.git"
# export QEMU_GIT_TAG="master"
export QEMU_GIT_TAG="v9.1.2"

# ALT gear repo (see qemu.spec)
# export QEMU_GIT_URL="git://git.altlinux.org/gears/q/qemu.git"
# export QEMU_GIT_URL="http://git.altlinux.org/gears/q/qemu.git"
# export QEMU_GIT_TAG="sisyphus"
# export QEMU_GIT_TAG="p11"
# export QEMU_GIT_TAG="9.1.2-alt1"

# ------------------------

# Syzkaller repository. Default is upstream version
# export SYZKALLER_GIT_URL="https://github.com/google/syzkaller.git"
# export SYZKALLER_GIT_TAG="master"
# To use the LVC fork version, uncomment these lines:
# export SYZKALLER_GIT_URL="https://git.linuxtesting.ru/pub/scm/tools/lvc/syzkaller.git"
# export SYZKALLER_GIT_TAG="lvc"
# Use Syzkaller fork compatible with Go < 1.26 (required for ALT Linux p11).
# This branch points to a state before the upstream migration to
# go1.26 (commit a3d21242b).
export SYZKALLER_GIT_URL="https://github.com/kovalev0/syzkaller.git"
export SYZKALLER_GIT_TAG="compat-go1.25"

# ------------------------

# Guest image URL. The script will append '/${IMAGE_FILENAME}.xz'
export IMAGE_BASE_URL="https://nightly.altlinux.org/${ALT_BRANCH}/permalink"

# --- 🛠️ Core Variables (usually no need to change) ---

# Base directory for all operations inside the container
export BASE_DIR=~/volume

# Kernel paths
export KERNEL_DIR="$BASE_DIR/linux-${KERNEL_GIT_TAG}"
export KERNEL_BUILD_DIR="$KERNEL_DIR/build"
export KERNEL_BZIMAGE="$KERNEL_BUILD_DIR/arch/x86/boot/bzImage"

# QEMU paths
export QEMU_DIR="$BASE_DIR/qemu-${QEMU_GIT_TAG}"
export QEMU_BUILD_DIR="$QEMU_DIR/build"
export QEMU_SYSTEM_DIR=""
# To use installed system binary path /usr/bin/, uncomment these lines:
# export QEMU_BUILD_DIR="$QEMU_SYSTEM_DIR"

# Syzkaller paths
export SYZKALLER_DIR="$BASE_DIR/syzkaller-${SYZKALLER_GIT_TAG}"
export SYZKALLER_WORKDIR="$BASE_DIR/workdir-${SYZ_CONFIG_TEMPLATE}"
export SYZKALLER_CONFIG_PATH="$SYZKALLER_WORKDIR/config.json"

# Guest Image paths
export IMAGE_DIR="$BASE_DIR/image"
export IMAGE_FILENAME="alt-${ALT_BRANCH}-jeos-systemd-latest-x86_64.img"
export IMAGE_PATH="$IMAGE_DIR/$IMAGE_FILENAME"
export IMAGE_MOUNT_DIR="$IMAGE_DIR/mnt"
export SSH_KEY_PATH="$IMAGE_DIR/id_rsa"

# QEMU VM Configuration
export DEBUG_VM_LOG_FILE="$BASE_DIR/vm_boot.linux-${KERNEL_GIT_TAG}.log"

echo "✅ Environment variables are set for config: ${SYZ_CONFIG_TEMPLATE}"
