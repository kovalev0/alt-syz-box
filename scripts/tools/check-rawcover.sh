#!/bin/bash
#
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Copyright (C) 2025 Vasiliy Kovalev <kovalev@altlinux.org>

set -e
source "$(dirname "$0")/../../project.env"
source "$(dirname "$0")/../../scripts/01-setup-env.sh" &>/dev/null

VMLINUX="$KERNEL_BUILD_DIR/vmlinux"
CODE_PATH_FILTER=$1
RAWCOVER_URL="http://0.0.0.0:${DEFAULT_SYZ_HTTP_INTERNAL_PORT}/rawcover"

# Check for correct usage
if [ -z "$CODE_PATH_FILTER" ]; then
    echo "Usage: $0 <code_path_filter>"
    exit 1
fi

comm -1 -2 \
 <(objdump -d "${VMLINUX}" \
   | grep -E 'callq?.*<__sanitizer_cov_trace_pc>' \
   | cut -c -16 \
   | addr2line -aifp -e "${VMLINUX}" \
   | grep "${CODE_PATH_FILTER}" \
   | cut -c -18 \
   | sort -u) \
 <(curl "${RAWCOVER_URL}" 2>/dev/null | sort -u) | grep -c ''
