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
    PACKAGES_TO_INSTALL="$PACKAGES_TO_INSTALL gcc"
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

# 5b. Instantiate an md array at boot.
#
# md_mod's new_array parameter creates one without mdadm and without the legacy
# open-triggered probe, so /sys/block/md0/md/ exists before the machine check --
# which is what openat$md_sysfs needs, and the bitmap/ attributes under it are
# the only way into md-bitmap.c. /dev/md0 follows from add_disk() via devtmpfs.
echo "Installing md boot unit..."
sudo tee "$IMAGE_MOUNT_DIR/etc/systemd/system/syz-md-setup.service" > /dev/null << 'MDSETUP'
[Unit]
Description=Instantiate md0 for the syzkaller machine check
After=local-fs.target systemd-udevd.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'modprobe md_mod 2>/dev/null || true'
ExecStart=/bin/sh -c 'echo md0 > /sys/module/md_mod/parameters/new_array 2>/dev/null || true'
ExecStart=/bin/sh -c 'test -b /dev/md0 || mknod /dev/md0 b 9 0 2>/dev/null || true'
ExecStart=/bin/sh -c 'ls -d /sys/block/md0/md 2>/dev/null || echo "syz-md-setup: /sys/block/md0/md missing" >&2'

[Install]
WantedBy=multi-user.target
MDSETUP
sudo mkdir -p "$IMAGE_MOUNT_DIR/etc/systemd/system/multi-user.target.wants"
sudo ln -sf /etc/systemd/system/syz-md-setup.service \
    "$IMAGE_MOUNT_DIR/etc/systemd/system/multi-user.target.wants/syz-md-setup.service"

# 5c. Build and install the dm-zoned metadata formatter.
#
# ALT has no dm-zoned-tools/dmzadm package. dm-zoned keeps its metadata on the
# conventional zones and refuses to start without a valid on-disk format, so a
# small self-contained formatter writes the two superblocks, the all-unmapped
# chunk mapping table and the zeroed bitmaps that dmz_ctr_metadata() validates.
# Build host and guest are the same ALT p11, so it is compiled here and copied
# into the image; the boot unit below runs it against the memory-backed (and
# therefore empty-on-boot) /dev/nullb0.
echo "Building dm-zoned metadata formatter..."
DMZ_FMT_SRC="$(mktemp --suffix=.c)"
cat > "$DMZ_FMT_SRC" << 'DMZFMT'
// syz-dmz-format: prepare host-managed zoned devices for dm-zoned fuzzing.
//
// ALT has no dm-zoned-tools package, so this writes exactly what the driver
// validates on read:
//   - a primary and a secondary superblock (crc32_le over the 4K block, seeded
//     with the stored generation, crc field zeroed first),
//   - a chunk mapping table whose every entry is DMZ_MAP_UNMAPPED, and
//   - zeroed validity bitmaps.
// Geometry is read from the device, so it follows the null_blk parameters.
//
// usage: syz-dmz-format <device> [--chunks N] [--start NAME:MINOR] [--zone-mib M]
//
// Without --start the device is only formatted and left free, so the fuzzer can
// run dmz_ctr/dmz_ctr_metadata on it itself. With --start a dm-zoned target is
// also built on it and left live at a fixed minor, which gives the fuzzer a
// device whose .map callback is reachable by a plain open of /dev/dm-<minor>.

#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <stdlib.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <linux/fs.h>
#include <linux/blkzoned.h>

#define DMZ_MAGIC	0x445A4244u	/* 'D' 'Z' 'B' 'D' */
#define DMZ_META_VER	2
#define BLOCK		4096u
#define NR_RESERVED_SEQ	8u

struct dmz_super {
	uint32_t magic;
	uint32_t version;
	uint64_t gen;
	uint64_t sb_block;
	uint32_t nr_meta_blocks;
	uint32_t nr_reserved_seq;
	uint32_t nr_chunks;
	uint32_t nr_map_blocks;
	uint32_t nr_bitmap_blocks;
	uint32_t crc;
	uint8_t  dmz_label[32];
	uint8_t  dmz_uuid[16];
	uint8_t  dev_uuid[16];
	uint8_t  reserved[400];
};

/* Kernel lib/crc32.c crc32_le(): poly 0xEDB88320, no pre/post inversion. */
static uint32_t crc32_le(uint32_t crc, const uint8_t *p, size_t len)
{
	while (len--) {
		crc ^= *p++;
		for (int i = 0; i < 8; i++)
			crc = (crc >> 1) ^ (0xEDB88320u & (-(int32_t)(crc & 1)));
	}
	return crc;
}

static int write_block(int fd, uint64_t blk, const void *buf)
{
	ssize_t n = pwrite(fd, buf, BLOCK, (off_t)blk * BLOCK);
	return (n == (ssize_t)BLOCK) ? 0 : -1;
}

/* ---- device-mapper ioctl plumbing ------------------------------------- */

#define DMI_SIZE 312
#define DM_PERSISTENT_DEV 8
struct dm_ioc {
	uint32_t version[3];
	uint32_t data_size;
	uint32_t data_start;
	uint32_t target_count;
	int32_t  open_count;
	uint32_t flags;
	uint32_t event_nr;
	uint32_t padding;
	uint64_t dev;
	char name[128];
	char uuid[129];
	char data[7];
};
struct dm_tspec {
	uint64_t sector_start;
	uint64_t length;
	int32_t  status;
	uint32_t next;
	char target_type[16];
};
#define DMOP(nr) _IOWR(0xfd, nr, struct dm_ioc)

static void dmi_hdr(struct dm_ioc *d, const char *name)
{
	memset(d, 0, DMI_SIZE);
	d->version[0] = 4;
	d->data_size = DMI_SIZE;
	d->data_start = DMI_SIZE;
	strncpy(d->name, name, sizeof(d->name) - 1);
}

/* Build a dm-zoned target on backing and leave it live at the given minor. */
static void dmz_start(const char *backing, const char *name, unsigned minor,
		      uint64_t dev_bytes)
{
	if (sizeof(struct dm_ioc) != DMI_SIZE) {
		fprintf(stderr, "syz-dmz-format: dm_ioc size %zu != %d\n",
			sizeof(struct dm_ioc), DMI_SIZE);
		return;
	}
	int ctl = open("/dev/mapper/control", O_RDWR | O_CLOEXEC);
	if (ctl < 0) {
		fprintf(stderr, "syz-dmz-format: open /dev/mapper/control: %s\n",
			strerror(errno));
		return;
	}
	char buf[DMI_SIZE + sizeof(struct dm_tspec) + 64];
	struct dm_ioc *d = (struct dm_ioc *)buf;

	dmi_hdr(d, name);
	d->flags = DM_PERSISTENT_DEV;
	d->dev = minor;
	int rc = ioctl(ctl, DMOP(3), d);		/* DM_DEV_CREATE */
	fprintf(stderr, "syz-dmz-format: create %s minor %u rc=%d (%s)\n",
		name, minor, rc, rc ? strerror(errno) : "ok");
	if (rc) {
		close(ctl);
		return;
	}

	memset(buf, 0, sizeof(buf));
	dmi_hdr(d, name);
	struct dm_tspec *t = (struct dm_tspec *)(buf + DMI_SIZE);
	char *p = (char *)(t + 1);
	t->length = dev_bytes / 512;
	strncpy(t->target_type, "zoned", sizeof(t->target_type) - 1);
	snprintf(p, 48, "%s", backing);
	t->next = sizeof(struct dm_tspec) + strlen(p) + 1;
	d->target_count = 1;
	d->data_size = DMI_SIZE + t->next;
	rc = ioctl(ctl, DMOP(9), d);			/* DM_TABLE_LOAD -> dmz_ctr */
	fprintf(stderr, "syz-dmz-format: table_load(zoned %s) rc=%d (%s)\n",
		backing, rc, rc ? strerror(errno) : "ok");
	if (rc) {
		dmi_hdr(d, name);
		ioctl(ctl, DMOP(4), d);			/* DM_DEV_REMOVE */
		close(ctl);
		return;
	}

	dmi_hdr(d, name);
	rc = ioctl(ctl, DMOP(6), d);			/* DM_DEV_SUSPEND -> resume */
	fprintf(stderr, "syz-dmz-format: resume rc=%d (%s)\n",
		rc, rc ? strerror(errno) : "ok");
	close(ctl);

	/* Confirm the live node is readable, which is what the fuzzer needs. */
	char node[64];
	snprintf(node, sizeof(node), "/dev/dm-%u", minor);
	int fd = open(node, O_RDONLY);
	if (fd < 0) {
		fprintf(stderr, "syz-dmz-format: open %s: %s\n", node, strerror(errno));
		return;
	}
	static char io[BLOCK];
	ssize_t n = pread(fd, io, BLOCK, 0);
	close(fd);
	fprintf(stderr, "syz-dmz-format: live %s read %zd (%s)\n",
		node, n, n == (ssize_t)BLOCK ? "ok" : strerror(errno));
}

int main(int argc, char **argv)
{
	const char *path = NULL, *start = NULL;
	unsigned long chunk_cap = 0, zone_mib = 0;

	for (int i = 1; i < argc; i++) {
		if (!strcmp(argv[i], "--chunks") && i + 1 < argc)
			chunk_cap = strtoul(argv[++i], NULL, 0);
		else if (!strcmp(argv[i], "--start") && i + 1 < argc)
			start = argv[++i];
		else if (!strcmp(argv[i], "--zone-mib") && i + 1 < argc)
			zone_mib = strtoul(argv[++i], NULL, 0);
		else if (!path)
			path = argv[i];
	}
	if (!path)
		path = "/dev/nullb0";

	int fd = open(path, O_RDWR | O_CLOEXEC);
	if (fd < 0) {
		fprintf(stderr, "syz-dmz-format: open %s failed\n", path);
		return 1;
	}

	uint64_t dev_bytes = 0;
	if (ioctl(fd, BLKGETSIZE64, &dev_bytes) != 0) {
		off_t end = lseek(fd, 0, SEEK_END);	/* regular file: for testing */
		if (end > 0)
			dev_bytes = (uint64_t)end;
	}
	uint32_t zone_sectors = 0;
	if (ioctl(fd, BLKGETZONESZ, &zone_sectors) != 0 || zone_sectors == 0)
		zone_sectors = (uint32_t)((zone_mib ? zone_mib : 4) * 1024 * 1024 / 512);
	uint64_t zone_bytes = (uint64_t)zone_sectors * 512;

	if (dev_bytes == 0 || zone_bytes < BLOCK || dev_bytes < 3 * zone_bytes) {
		fprintf(stderr, "syz-dmz-format: %s unusable geometry "
			"(dev=%llu zone=%llu); skipping\n", path,
			(unsigned long long)dev_bytes, (unsigned long long)zone_bytes);
		close(fd);
		return 2;
	}

	const uint32_t zone_nr_blocks = (uint32_t)(zone_bytes / BLOCK);
	const uint32_t nr_zones       = (uint32_t)(dev_bytes / zone_bytes);
	uint32_t zone_bmp_blocks      = (zone_nr_blocks / 8) / BLOCK;
	if (zone_bmp_blocks == 0)
		zone_bmp_blocks = 1;
	const uint32_t nr_bitmap_blocks = nr_zones * zone_bmp_blocks;

	uint32_t reserved_seq = NR_RESERVED_SEQ;
	if (reserved_seq >= nr_zones / 2)
		reserved_seq = 1;

	uint32_t nr_meta_zones = 1, nr_chunks = 0, nr_map_blocks = 0, nr_meta_blocks = 0;
	for (int it = 0; it < 8; it++) {
		uint32_t nr_data_zones = nr_zones - (2 * nr_meta_zones + reserved_seq);
		nr_chunks = nr_data_zones;
		if (chunk_cap && chunk_cap < nr_chunks)
			nr_chunks = (uint32_t)chunk_cap;
		nr_map_blocks = (nr_chunks + 511) / 512;
		nr_meta_blocks = 1 + nr_map_blocks + nr_bitmap_blocks;
		uint32_t need = (nr_meta_blocks + zone_nr_blocks - 1) / zone_nr_blocks;
		if (need == nr_meta_zones)
			break;
		nr_meta_zones = need;
	}

	static uint8_t block[BLOCK];
	int rc = 0;

	for (int set = 0; set < 2 && rc == 0; set++) {
		uint64_t base = (uint64_t)set * zone_nr_blocks * nr_meta_zones;

		memset(block, 0, BLOCK);
		struct dmz_super *sb = (struct dmz_super *)block;
		sb->magic           = DMZ_MAGIC;
		sb->version         = DMZ_META_VER;
		sb->gen             = 1;
		sb->sb_block        = base;
		sb->nr_meta_blocks  = nr_meta_blocks;
		sb->nr_reserved_seq = reserved_seq;
		sb->nr_chunks       = nr_chunks;
		sb->nr_map_blocks   = nr_map_blocks;
		sb->nr_bitmap_blocks = nr_bitmap_blocks;
		/* Label is a C string the driver copies and strlen()s, so it must
		 * be NUL-terminated within its 32 bytes; the UUIDs are raw 16-byte
		 * values checked only for being non-zero (uuid_is_null). */
		memcpy(sb->dmz_label, "syzdmz", 6);
		memset(sb->dmz_uuid,  0x5a, sizeof(sb->dmz_uuid));
		memset(sb->dev_uuid,  0x5a, sizeof(sb->dev_uuid));
		sb->crc = 0;
		sb->crc = crc32_le((uint32_t)sb->gen, block, BLOCK);
		rc |= write_block(fd, base, block);

		memset(block, 0xff, BLOCK);
		for (uint32_t i = 0; i < nr_map_blocks && rc == 0; i++)
			rc |= write_block(fd, base + 1 + i, block);

		memset(block, 0, BLOCK);
		for (uint32_t i = 0; i < nr_bitmap_blocks && rc == 0; i++)
			rc |= write_block(fd, base + 1 + nr_map_blocks + i, block);
	}

	if (rc == 0)
		fsync(fd);
	close(fd);

	if (rc) {
		fprintf(stderr, "syz-dmz-format: write failed on %s\n", path);
		return 1;
	}
	fprintf(stderr, "syz-dmz-format: %s formatted (v%d, %u zones of %u blocks, "
		"%u chunks, %u meta zones, %u meta blocks, %u reserved seq)\n",
		path, DMZ_META_VER, nr_zones, zone_nr_blocks, nr_chunks,
		nr_meta_zones, nr_meta_blocks, reserved_seq);

	if (start) {
		char name[64];
		unsigned minor = 0;
		const char *colon = strchr(start, ':');
		if (!colon) {
			fprintf(stderr, "syz-dmz-format: --start needs NAME:MINOR\n");
			return 0;
		}
		size_t nlen = (size_t)(colon - start);
		if (nlen >= sizeof(name))
			nlen = sizeof(name) - 1;
		memcpy(name, start, nlen);
		name[nlen] = 0;
		minor = (unsigned)strtoul(colon + 1, NULL, 0);
		dmz_start(path, name, minor, dev_bytes);
	}
	return 0;
}
DMZFMT
if gcc -O2 -static -o /tmp/syz-dmz-format "$DMZ_FMT_SRC" 2>/dev/null || gcc -O2 -o /tmp/syz-dmz-format "$DMZ_FMT_SRC"; then
    sudo install -D -m 0755 /tmp/syz-dmz-format "$IMAGE_MOUNT_DIR/usr/local/sbin/syz-dmz-format"
    echo "  installed /usr/local/sbin/syz-dmz-format"
else
    echo "WARNING: could not build syz-dmz-format; dm-zoned will be left unformatted at boot"
fi
rm -f "$DMZ_FMT_SRC" /tmp/syz-dmz-format

# 5d. Prepare the dm-zoned devices at boot.
#
# null_blk comes up memory-backed and empty every boot, so every backing device
# is formatted here. The layout gives each fuzzing proc its own backing so that
# nothing is shared, because a dm-zoned ctr opens its backing with FMODE_EXCL and
# a shared backing would admit only one proc:
#
#   /dev/nullb0        formatted, with a live target left on it at minor 100
#                      (name syzdmzlive). This is the always-present I/O target
#                      reached by a plain open, so dmz_map and the handlers are
#                      hit from the first program.
#   /dev/nullb1 .. b8  formatted and left free, one per proc. syz_dmz_create(index)
#                      builds its own target on /dev/nullb<index+1> at minor
#                      110 + index, which is what runs dmz_ctr and dmz_ctr_metadata
#                      in the context of the fuzzer (where KCOV sees them) instead
#                      of once at boot.
#   /dev/nullb9        formatted and left free as the shared backing the raw
#                      DM_TABLE_LOAD path in the descriptions aims at.
#
# A small chunk count keeps the exposed capacity tiny, so a burst of writes fills
# the few cache zones quickly and drives the reclaim worker. Host-managed zoned
# devices require the mq-deadline scheduler.
echo "Installing dm-zoned boot unit..."
sudo tee "$IMAGE_MOUNT_DIR/etc/systemd/system/syz-dmz-setup.service" > /dev/null << 'DMZSETUP'
[Unit]
Description=Format null_blk devices (dm-zoned) for the syzkaller machine check
After=local-fs.target systemd-udevd.service
Before=multi-user.target

[Service]
Type=oneshot
RemainAfterExit=yes
StandardOutput=journal+console
StandardError=journal+console
ExecStart=/bin/sh -c 'for d in nullb0 nullb1 nullb2 nullb3 nullb4 nullb5 nullb6 nullb7 nullb8 nullb9; do [ -e /sys/block/$d/queue/scheduler ] && echo mq-deadline > /sys/block/$d/queue/scheduler || true; done'
ExecStart=/bin/sh -c 'for i in $(seq 1 50); do [ -b /dev/nullb0 ] && [ -b /dev/nullb9 ] && break; sleep 0.1; done; test -x /usr/local/sbin/syz-dmz-format || { echo "syz-dmz-setup: formatter missing"; exit 0; }; /usr/local/sbin/syz-dmz-format /dev/nullb0 --chunks 16 --start syzdmzlive:100; for i in 1 2 3 4 5 6 7 8 9; do /usr/local/sbin/syz-dmz-format /dev/nullb$i --chunks 16; done'
ExecStart=/bin/sh -c 'mkdir -p /dev/mapper; [ -b /dev/dm-100 ] && ln -sf /dev/dm-100 /dev/mapper/syzdmzlive || true'

[Install]
WantedBy=multi-user.target
DMZSETUP
sudo mkdir -p "$IMAGE_MOUNT_DIR/etc/systemd/system/multi-user.target.wants"
sudo ln -sf /etc/systemd/system/syz-dmz-setup.service "$IMAGE_MOUNT_DIR/etc/systemd/system/multi-user.target.wants/syz-dmz-setup.service"

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
