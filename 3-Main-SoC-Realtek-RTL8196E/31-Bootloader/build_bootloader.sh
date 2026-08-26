#!/bin/bash
# build_bootloader.sh — Build the RTL8196E bootloader
#
# Original bootloader sources and build flow:
#   Copyright (C) Realtek Semiconductor Corp.
#
# Adapted and simplified for RTL8196E-only builds:
#   J. Nilo - November 2025
#
# Uses the Lexra/musl toolchain from the project x-tools directory.
#
# Two variants are built:
#   - boot:    production flash image (stays in download mode after boot TFTP)
#   - ramtest: RAM-test image with read-back verification of BSS clears
#
# Outputs:
#   boot-img/<board>/boot.bin  - flash image (per-board slot, committed)
#   btcode/build/test.bin      - RAM-loadable image for RAM testing
#
# Usage:
#   ./build_bootloader.sh          # build all variants
#   ./build_bootloader.sh clean    # clean all build outputs

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# Project root is 2 levels up: 31-Bootloader -> 3-Main-SoC -> project root
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

JUMP_ADDR="${JUMP_ADDR:-0x80500000}"
CROSS_PREFIX="mips-lexra-linux-musl-"

# --- Board selection ---------------------------------------------------------
# Per-board constants (DRAM size/top, DDR bring-up) live in
# boards/<board>/board.h — see boards/README.md. Default: the Lidl
# reference board. The build is reproducible: it regenerates the committed
# boot-img/<board>/boot.bin bit-for-bit.

BOARD="${BOARD:-lidl}"
if [ ! -f "$SCRIPT_DIR/boards/$BOARD/board.h" ]; then
    echo "ERROR: unknown BOARD '$BOARD' — no boards/$BOARD/board.h" >&2
    echo "Available boards: $(ls "$SCRIPT_DIR/boards" | grep -v README | tr '\n' ' ')" >&2
    exit 1
fi

# --- HOLD_RF_RESET ----------------------------------------------------------
# Set HOLD_RF_RESET=1 to build a bootloader that holds the board's RF
# reset pad (BOARD_RF_RESET_GPIO in boards/<board>/board.h) LOW from the
# first instruction until userspace releases it — for units with an
# external device (e.g. an ESP32 BLE proxy) wired onto that line and
# ttyS0. It also stamps an "RFHD" marker into the boothold page so the
# gateway's init scripts can tell that the hold is active. See
# boot/main.c and docs/ble-proxy.md. Default: off.
# Flag parsing lives in the shared checker: lib/hold_rf_reset.sh.
LIB_DIR="${SCRIPT_DIR}/../../lib"
if [ ! -f "${LIB_DIR}/hold_rf_reset.sh" ]; then
    echo "ERROR: ${LIB_DIR}/hold_rf_reset.sh not found" >&2
    exit 1
fi
# shellcheck disable=SC1091
. "${LIB_DIR}/hold_rf_reset.sh"
hold_rf_reset_parse || exit 1
HOLD_RF_RESET_VARS=""
[ "$RF_HOLD" = "1" ] && HOLD_RF_RESET_VARS="HOLD_RF_RESET=1"

# Toolchain - check project root first, then walk up the repo tree
find_toolchain() {
    # Check in the project root directory (~/rtl8196e-gateway)
    if [ -d "$PROJECT_ROOT/x-tools/mips-lexra-linux-musl/bin" ]; then
        echo "$PROJECT_ROOT/x-tools/mips-lexra-linux-musl"
        return 0
    fi
    # Fallback: walk up from script directory
    local dir="$SCRIPT_DIR"
    while [ "$dir" != "/" ]; do
        if [ -d "$dir/x-tools/mips-lexra-linux-musl/bin" ]; then
            echo "$dir/x-tools/mips-lexra-linux-musl"
            return 0
        fi
        dir="$(cd "$dir/.." && pwd)"
    done
    return 1
}

TOOLCHAIN_DIR="$(find_toolchain || true)"

# Add toolchain to PATH only if not already available (avoids GLIBC mismatch in Docker)
if ! command -v ${CROSS_PREFIX}gcc >/dev/null 2>&1 && [ -n "$TOOLCHAIN_DIR" ]; then
    export PATH="${TOOLCHAIN_DIR}/bin:$PATH"
fi
export CROSS="${CROSS_PREFIX}"

# --- Locate Realtek tools (cvimg, lzma) ------------------------------------

REALTEK_TOOLS=""
for dir in \
    "/home/builder/realtek-tools/bin" \
    "${PROJECT_ROOT}/1-Build-Environment/11-realtek-tools/bin"; do
    if [ -x "${dir}/cvimg" ] && [ -x "${dir}/lzma" ]; then
        REALTEK_TOOLS="$dir"
        break
    fi
done

# --- Checks ----------------------------------------------------------------

if [ -z "$TOOLCHAIN_DIR" ]; then
    echo "Toolchain not found in parent directories (expected x-tools/mips-lexra-linux-musl)"
    echo ""
    echo "Build the toolchain first:"
    echo "  cd ${PROJECT_ROOT}/1-Build-Environment/10-lexra-toolchain"
    echo "  ./build_toolchain.sh"
    exit 1
fi

if ! command -v "${CROSS_PREFIX}gcc" >/dev/null 2>&1; then
    echo "Compiler not found: ${CROSS_PREFIX}gcc"
    exit 1
fi

# --- Clean target -----------------------------------------------------------

do_clean() {
    echo "Cleaning all build outputs..."
    make -C "$SCRIPT_DIR/boot"   CROSS="$CROSS_PREFIX" clean 2>/dev/null || true
    make -C "$SCRIPT_DIR/btcode" CROSS="$CROSS_PREFIX" clean 2>/dev/null || true
    # boot-img/<board>/boot.bin is a committed artifact, not a build output —
    # clean leaves it alone (git restores it if a build overwrote it).
    echo "Done."
}

if [ "${1:-}" = "clean" ]; then
    do_clean
    exit 0
fi

# --- Build ------------------------------------------------------------------

echo "========================================="
echo "  BUILDING RTL8196E BOOTLOADER"
echo "========================================="
echo ""
echo "Toolchain: $TOOLCHAIN_DIR"
echo "Compiler:  $(${CROSS_PREFIX}gcc --version | head -1)"
echo "Jump addr: $JUMP_ADDR"
echo "Board:     $BOARD"
echo "RF hold:   ${HOLD_RF_RESET:-0} (pin: BOARD_RF_RESET_GPIO in boards/$BOARD/board.h)"
if [ -n "$REALTEK_TOOLS" ]; then
    echo "Realtek:   $REALTEK_TOOLS"
else
    echo "ERROR: Realtek tools (cvimg, lzma) not found"
    echo "  Build them: cd ${PROJECT_ROOT}/1-Build-Environment/11-realtek-tools && ./build_tools.sh"
    exit 1
fi
echo ""

# Pass tool paths to btcode Makefile (overrides hardcoded defaults)
BTCODE_VARS="CROSS=${CROSS_PREFIX} CVIMG=${REALTEK_TOOLS}/cvimg LZMA=${REALTEK_TOOLS}/lzma BOARD=${BOARD}"

# boot/ must be cleaned between variants because the Makefiles do not
# track CFLAGS changes.

# --- boot variant ---
echo "--- Building boot image (board: $BOARD, rf-hold: ${HOLD_RF_RESET:-0}) ---"
make -C "$SCRIPT_DIR/boot" CROSS="$CROSS_PREFIX" clean
make -C "$SCRIPT_DIR/boot" CROSS="$CROSS_PREFIX" boot JUMP_ADDR="$JUMP_ADDR" BOARD="$BOARD" $HOLD_RF_RESET_VARS
make -C "$SCRIPT_DIR/btcode" $BTCODE_VARS clean
make -C "$SCRIPT_DIR/btcode" $BTCODE_VARS
mkdir -p "$SCRIPT_DIR/boot-img/$BOARD"
cp -f "$SCRIPT_DIR/btcode/build/boot.bin" "$SCRIPT_DIR/boot-img/$BOARD/boot.bin"

# --- ramtest variant (btcode CFLAGS change -> clean btcode too) ---
echo ""
echo "--- Building ramtest variant ---"
make -C "$SCRIPT_DIR/boot" CROSS="$CROSS_PREFIX" clean
make -C "$SCRIPT_DIR/boot" CROSS="$CROSS_PREFIX" boot JUMP_ADDR="$JUMP_ADDR" BOARD="$BOARD" RAMTEST_TRACE=1 $HOLD_RF_RESET_VARS
make -C "$SCRIPT_DIR/btcode" $BTCODE_VARS clean
make -C "$SCRIPT_DIR/btcode" $BTCODE_VARS RAMTEST_TRACE=1

# --- Summary ----------------------------------------------------------------

echo ""
echo "========================================="
echo "  BUILD SUMMARY"
echo "========================================="
echo ""
[ -f "$SCRIPT_DIR/boot-img/$BOARD/boot.bin" ] && ls -lh "$SCRIPT_DIR/boot-img/$BOARD/boot.bin"
[ -f "$SCRIPT_DIR/btcode/build/test.bin" ]    && ls -lh "$SCRIPT_DIR/btcode/build/test.bin"
echo ""
echo "Done."
