#!/bin/bash
#
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Copyright (C) 2025 Vasiliy Kovalev <kovalev@altlinux.org>

# bisect_step.sh - A utility script to manually bisect a file by dividing it
# into two halves.

FILENAME=$1

# Check for correct usage
if [ -z "$FILENAME" ]; then
    echo "Usage: $0 <file_to_bisect>"
    exit 1
fi

# Check if the file exists
if [ ! -f "$FILENAME" ]; then
    echo "Error: File $FILENAME not found."
    exit 1
fi

# 1. Count total lines in the file
TOTAL_LINES=$(wc -l < "$FILENAME")

# Check if bisection is complete
if [ "$TOTAL_LINES" -le 1 ]; then
    echo "Bisection complete. File contains 1 or 0 lines."
    exit 0
fi

# 2. Calculate the split point
MID=$((TOTAL_LINES / 2))
HALF_LINES=$((TOTAL_LINES - MID))

# 3. Divide the file into two parts: top_half and bottom_half
# TOP_HALF: The first MID lines
head -n $MID "$FILENAME" > top_half.txt

# BOTTOM_HALF: Lines from MID + 1 to the end
tail -n +$((MID + 1)) "$FILENAME" > bottom_half.txt

echo "-----------------------------------"
echo "Divided file: $FILENAME"
echo "Total lines: $TOTAL_LINES"
echo "Top half (top_half.txt): $MID lines"
echo "Bottom half (bottom_half.txt): $HALF_LINES lines"
echo "-----------------------------------"
echo "Manual Bisection Step:"
echo "1. Test top_half.txt."
echo "2. If the issue reproduces: mv top_half.txt $FILENAME"
echo "3. If it does NOT reproduce: mv bottom_half.txt $FILENAME"
