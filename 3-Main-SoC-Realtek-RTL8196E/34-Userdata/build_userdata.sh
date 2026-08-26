#!/bin/bash
# build_userdata.sh — Build JFFS2 userdata partition for RTL8196E
#
# By default, this script packages the JFFS2 image from the binaries already
# committed in skeleton/usr/bin/ — boothold, nano, otbr-agent, ot-ctl, vi,
# serialgateway — and skeleton/usr/sbin/ — s40button and friends.  WireGuard
# is NOT built or installed here: see wireguard/README.md.
# It does NOT rebuild those binaries in the default flow.
#
# To rebuild all userland binaries (boothold, s40button, serialgateway, nano,
# otbr-agent, ot-ctl) from source, pass --rebuild-components (full flow) or
# --components-only (skip the image). The ot-br-posix step clones a large
# upstream tree and can take ~30 min on first run.
#
# The default UART<->TCP bridge is in-kernel (CONFIG_RTL8196E_UART_BRIDGE=y
# in the 6.18 kernel).  The userspace serialgateway (restored from v2.1.6)
# ships again on HOLD_RF_RESET=1 builds: there the single kernel bridge
# instance belongs to ttyS0, so ttyS1 needs a userspace bridge.
#
# Usage:
#   ./build_userdata.sh                       # Package image from skeleton (default)
#   ./build_userdata.sh --rebuild-components  # Rebuild all components, then image
#   ./build_userdata.sh --components-only     # Rebuild all components, skip image
#   ./build_userdata.sh --jffs2-only          # Alias of default (used by flash scripts)
#   ./build_userdata.sh --jffs2-only -q       # Quiet mode (used by build_fullflash)
#
# Rebuilt on --rebuild-components / --components-only:
#   +-----------------+----------------------------------------------+-------------+
#   | Component       | Source                                       | License     |
#   +-----------------+----------------------------------------------+-------------+
#   | boothold        | boothold/src/boothold.c (local)              | MIT         |
#   | s40button       | s40button/src/s40button.c (local)            | MIT         |
#   | keepalive       | keepalive/src/keepalive.c (local)            | MIT         |
#   | serialgateway   | serialgateway/src/ (local, from v2.1.6)      | GPL-3.0     |
#   | otbr-monitor    | otbr-monitor/src/otbr-monitor.c (local)      | MIT         |
#   | nano            | https://www.nano-editor.org/                 | GPL-3.0     |
#   | ncursesw        | https://ftp.gnu.org/gnu/ncurses/             | MIT         |
#   | otbr-agent      | https://github.com/openthread/ot-br-posix    | BSD-3       |
#   | ot-ctl          | (same as otbr-agent)                         | BSD-3       |
#   +-----------------+----------------------------------------------+-------------+
#
# Note: vi is a symlink to nano (OpenVi doesn't support UTF-8/emojis)
#
# Output: userdata.bin (ready to flash)
#
# Flash: GD25Q127 (16MB SPI NOR, 64KB erase blocks)
#
# J. Nilo - December 2025

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="${SCRIPT_DIR}/.."
INSTALL_DIR="${SCRIPT_DIR}/skeleton/usr/bin"

# Default: package the JFFS2 image from the binaries committed in skeleton/
# (boothold, nano, otbr-agent, ot-ctl, vi → nano). Rebuilding those binaries
# is opt-in via --rebuild-components (full flow) or --components-only (no image).
BUILD_COMPONENTS=0
BUILD_IMAGE=1
QUIET=0

# Parse arguments
for arg in "$@"; do
    case $arg in
        --jffs2-only)
            # Kept for backward compatibility with flash_userdata.sh,
            # build_fullflash.sh and create_fullflash.sh — same as default.
            BUILD_COMPONENTS=0
            BUILD_IMAGE=1
            ;;
        --rebuild-components)
            BUILD_COMPONENTS=1
            BUILD_IMAGE=1
            ;;
        --components-only)
            BUILD_COMPONENTS=1
            BUILD_IMAGE=0
            ;;
        -q|--quiet)
            QUIET=1
            ;;
        --help|-h)
            echo "Usage: $0 [options]"
            echo ""
            echo "Default: package the JFFS2 image from the binaries already in"
            echo "skeleton/usr/bin/ (tracked in git)."
            echo ""
            echo "Options:"
            echo "  --rebuild-components   Rebuild boothold + nano, then package the image"
            echo "  --components-only      Rebuild boothold + nano, skip the image"
            echo "  --jffs2-only           Alias of the default (kept for flash scripts)"
            echo "  -q, --quiet            Suppress non-essential output"
            echo "  --help, -h             Show this help"
            echo ""
            echo "Rebuilt when --rebuild-components / --components-only is set:"
            echo "  boothold           Static helper to reboot into bootloader"
            echo "  nano               GNU nano editor (with vi symlink)"
            echo "  otbr-agent+ot-ctl  OpenThread Border Router (~30 min on first run)"
            exit 0
            ;;
        *)
            echo "Unknown option: $arg"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

# Checks required only for the image-creation stage
if [ "$BUILD_IMAGE" -eq 1 ]; then
    # Check that fakeroot is installed.
    # Errors go to stderr so they survive when this script is invoked with stdout
    # redirected to /dev/null (build_fullflash.sh -q, called by flash_install_rtl8196e.sh).
    if ! command -v fakeroot >/dev/null 2>&1; then
        echo "fakeroot is not installed" >&2
        echo "   Installation: sudo apt-get install fakeroot" >&2
        exit 1
    fi

    # Check that cvimg is available, build it if missing
    BUILD_ENV="${PROJECT_ROOT}/../1-Build-Environment/11-realtek-tools"
    CVIMG_TOOL="${BUILD_ENV}/bin/cvimg"
    if [ ! -f "$CVIMG_TOOL" ]; then
        echo "cvimg not found — building it..."
        if ! command -v gcc >/dev/null 2>&1; then
            echo "Error: gcc not found (needed to compile cvimg)." >&2
            echo "Install it with: sudo apt install gcc" >&2
            exit 1
        fi
        CVIMG_SRC="${BUILD_ENV}/cvimg/cvimg.c"
        if [ ! -f "$CVIMG_SRC" ]; then
            echo "Error: cvimg source not found at ${CVIMG_SRC}" >&2
            exit 1
        fi
        # Clear a dangling symlink left by the Docker entrypoint when reusing the
        # same workspace from the host (target /home/builder/... only exists in-container).
        [ -L "${BUILD_ENV}/bin" ] && [ ! -d "${BUILD_ENV}/bin" ] && rm -f "${BUILD_ENV}/bin"
        mkdir -p "${BUILD_ENV}/bin"
        gcc -std=c99 -Wall -O2 -D_GNU_SOURCE -o "$CVIMG_TOOL" "$CVIMG_SRC" || {
            echo "Error: failed to compile cvimg" >&2
            exit 1
        }
        echo "cvimg built."
    fi
fi

cd "${SCRIPT_DIR}"

log() { [ "$QUIET" -eq 0 ] && echo "$@" || true; }

# --- HOLD_RF_RESET ----------------------------------------------------------
# Same flag and values as build_bootloader.sh / build_rootfs.sh: set it when
# building images for a unit with an external device on ttyS0 (e.g. an ESP32
# BLE proxy).  In that configuration the packaged /userdata/etc/inittab has
# its ttyS0 getty line commented out from the start (using the #[altuart0]
# marker that altuart0's 'console' action later removes to bring the getty
# back), and the userspace TCP<->serial bridge (serialgateway, restored from
# v2.1.6) is guaranteed to ship in the image: the kernel uart_bridge is a
# single instance owned by ttyS0 there, so a second link for ttyS1 needs the
# userspace bridge.  Default builds keep the active getty line and do not
# touch serialgateway.
# Flag parsing lives in the shared checker: lib/hold_rf_reset.sh.
LIB_DIR="${PROJECT_ROOT}/../lib"
if [ ! -f "${LIB_DIR}/hold_rf_reset.sh" ]; then
    echo "ERROR: ${LIB_DIR}/hold_rf_reset.sh not found" >&2
    exit 1
fi
# shellcheck disable=SC1091
. "${LIB_DIR}/hold_rf_reset.sh"
hold_rf_reset_parse || exit 1

# --- /userdata/etc/inittab ---------------------------------------------------
# Generated at image-build time from the rootfs skeleton's stock inittab
# (single source of truth — 33-Rootfs/skeleton/etc/inittab), with the
# ::sysinit entry stripped: a sysinit action in this re-read table would
# re-run rcS on every SIGHUP.  The generated file is a build artifact,
# not tracked in git.

INITTAB="skeleton/etc/inittab"
ROOTFS_INITTAB="${PROJECT_ROOT}/33-Rootfs/skeleton/etc/inittab"

# Build components if requested
if [ "$BUILD_COMPONENTS" -eq 1 ]; then
    echo "========================================="
    echo "  BUILDING USERDATA COMPONENTS"
    echo "========================================="
    echo "  boothold          reboot-to-bootloader helper"
    echo "  s40button         front-panel button daemon"
    echo "  keepalive         process supervisor (issue #109)"
    echo "  serialgateway     userspace TCP<->serial bridge (v2.1.6 revival)"
    echo "  otbr-monitor      OTBR housekeeping daemon (C)"
    echo "  nano              editor (with vi symlink)"
    echo "  otbr-agent+ot-ctl OpenThread Border Router (~30 min on first run)"
    echo ""

    # Build boothold
    echo "========================================="
    echo "  BUILDING BOOTHOLD"
    echo "========================================="
    if [ -x "${SCRIPT_DIR}/boothold/build_boothold.sh" ]; then
        "${SCRIPT_DIR}/boothold/build_boothold.sh"
    else
        echo "Error: boothold/build_boothold.sh not found or not executable"
        exit 1
    fi
    echo ""

    # Build s40button
    echo "========================================="
    echo "  BUILDING S40BUTTON"
    echo "========================================="
    if [ -x "${SCRIPT_DIR}/s40button/build_s40button.sh" ]; then
        "${SCRIPT_DIR}/s40button/build_s40button.sh"
    else
        echo "Error: s40button/build_s40button.sh not found or not executable"
        exit 1
    fi
    echo ""

    # Build keepalive (process supervisor for otbr-agent + otbr-monitor, #109)
    echo "========================================="
    echo "  BUILDING KEEPALIVE"
    echo "========================================="
    if [ -x "${SCRIPT_DIR}/keepalive/build_keepalive.sh" ]; then
        "${SCRIPT_DIR}/keepalive/build_keepalive.sh"
    else
        echo "Error: keepalive/build_keepalive.sh not found or not executable"
        exit 1
    fi
    echo ""

    # Build serialgateway (userspace TCP<->serial bridge, restored from v2.1.6)
    echo "========================================="
    echo "  BUILDING SERIALGATEWAY"
    echo "========================================="
    if [ -x "${SCRIPT_DIR}/serialgateway/build_serialgateway.sh" ]; then
        "${SCRIPT_DIR}/serialgateway/build_serialgateway.sh"
    else
        echo "Error: serialgateway/build_serialgateway.sh not found or not executable"
        exit 1
    fi
    echo ""

    # Build otbr-monitor (C rewrite of the ash housekeeping loop, #109)
    echo "========================================="
    echo "  BUILDING OTBR-MONITOR"
    echo "========================================="
    if [ -x "${SCRIPT_DIR}/otbr-monitor/build_otbr-monitor.sh" ]; then
        "${SCRIPT_DIR}/otbr-monitor/build_otbr-monitor.sh"
    else
        echo "Error: otbr-monitor/build_otbr-monitor.sh not found or not executable"
        exit 1
    fi
    echo ""

    # Clean previous nano binaries, then rebuild
    rm -f "${INSTALL_DIR}/nano" "${INSTALL_DIR}/vi"

    # Build nano (creates vi symlink)
    echo "========================================="
    echo "  BUILDING NANO"
    echo "========================================="
    if [ -x "${SCRIPT_DIR}/nano/build_nano.sh" ]; then
        "${SCRIPT_DIR}/nano/build_nano.sh"
    else
        echo "Error: nano/build_nano.sh not found or not executable"
        exit 1
    fi
    echo ""

    # Build ot-br-posix (otbr-agent + ot-ctl)
    echo "========================================="
    echo "  BUILDING OT-BR-POSIX"
    echo "========================================="
    if [ -x "${SCRIPT_DIR}/ot-br-posix/build_otbr.sh" ]; then
        "${SCRIPT_DIR}/ot-br-posix/build_otbr.sh"
    else
        echo "Error: ot-br-posix/build_otbr.sh not found or not executable"
        exit 1
    fi
    echo ""

fi

# Stop here if the caller asked for components only
if [ "$BUILD_IMAGE" -eq 0 ]; then
    log "========================================="
    log "  USERDATA COMPONENTS READY"
    log "========================================="
    log ""
    log "Binaries staged in: ${INSTALL_DIR}"
    exit 0
fi

log "========================================="
log "  BUILDING USERDATA PARTITION"
log "========================================="
log ""

# Clean old images
rm -f userdata.raw.jffs2 userdata.jffs2 userdata.bin

# Use skeleton directory (callers can override via SKELETON_DIR env var)
SKELETON_DIR="${SKELETON_DIR:-${SCRIPT_DIR}/skeleton}"
if [ ! -d "$SKELETON_DIR" ]; then
    echo "skeleton directory not found"
    exit 1
fi

# Generate /userdata/etc/inittab from the rootfs skeleton's stock file
# (::sysinit stripped — see the comment at the top of this script).
INITTAB="${SKELETON_DIR}/etc/inittab"
if [ ! -f "$ROOTFS_INITTAB" ]; then
    echo "rootfs skeleton inittab not found: $ROOTFS_INITTAB" >&2
    exit 1
fi
log "📝 Generating ${INITTAB} (from 33-Rootfs skeleton, ::sysinit stripped)..."
{
    echo "# /userdata/etc/inittab - GENERATED by build_userdata.sh; do not edit."
    echo "# Source of truth: 33-Rootfs/skeleton/etc/inittab with the ::sysinit"
    echo "# entry stripped (a sysinit action here would re-run rcS on every"
    echo "# SIGHUP).  init runs on built-in fallback defaults until"
    echo "# S99enablealtuart0 re-reads this table (kill -HUP 1)."
    echo "#"
    echo "# Alt-uart0 mode (external device on ttyS0) = the getty line below"
    echo "# commented out with the #[altuart0] marker - see altuart0.common."
    # Action lines only: drop ::sysinit and the rootfs file's comments,
    # which describe the squashfs side and would be wrong here.
    grep -v -e '^::sysinit:' -e '^#' "$ROOTFS_INITTAB"
} > "$INITTAB"

# rf-hold build: package the getty line already commented out (same
# #[altuart0] marker S99enablealtuart0 uses, so its 'console' subcommand
# restores it).  Stock builds keep the active getty line.
if [ "$RF_HOLD" = "1" ]; then
    log "🔇 /userdata/etc/inittab: getty line pre-commented (rf-hold build)"
    sed -i 's|^ttyS0::respawn:|#[altuart0] ttyS0::respawn:|' "$INITTAB"
fi

# rf-hold build: guarantee the userspace TCP<->serial bridge ships in the
# image (restored from v2.1.6; see the HOLD_RF_RESET note above).  The
# prebuilt binary is tracked in skeleton/usr/bin; rebuild it only when
# missing — same policy as dropbearmulti in build_rootfs.sh.
if [ "$RF_HOLD" = "1" ] && [ ! -f "${INSTALL_DIR}/serialgateway" ]; then
    echo "HOLD_RF_RESET=1 requires serialgateway — building it..."
    "${SCRIPT_DIR}/serialgateway/build_serialgateway.sh"
fi

log "Binaries installed:"
if [ "$QUIET" -eq 0 ]; then
    ls -lh "$INSTALL_DIR" 2>/dev/null || echo "  (none)"
fi
log ""

# JFFS2 image creation with sumtool optimization
# Partition mtd3 spans 0x400000-0x1000000 -> 0xC00000 bytes (12MB).
# cvimg sets Header.len = payload_size + 2 (checksum). To make burnLen fit exactly
# 0xC00000, we pad the final JFFS2 to 0xC00000 - 2 = 0xBFFFFE.
# NOTE: Keep erase size in sync with kernel MTD layout. Here: 64KB (SPI NOR).
ERASEBLOCK_HEX=0x10000
PARTITION_SIZE_HEX=0xC00000
JFFS2_PAD_HEX=$((PARTITION_SIZE_HEX - 2))

log "Generating JFFS2 (big endian, 64KB eraseblocks, zlib-only, padded to ${JFFS2_PAD_HEX} bytes)..."
# Force zlib-only: -X enables zlib, -x disables rtime (on by default in mkfs.jffs2)
# Kernel has CONFIG_JFFS2_ZLIB=y but NOT rtime/lzo/rubin
fakeroot mkfs.jffs2 \
  -r "$SKELETON_DIR" \
  -o "${SCRIPT_DIR}/userdata.jffs2" \
  -e ${ERASEBLOCK_HEX} \
  -b \
  -n \
  --squash \
  --pad=${JFFS2_PAD_HEX} \
  -X zlib \
  -x rtime \
  -x lzo

log "JFFS2 image created"
log ""

# Convert to RTL format
log "Converting to RTL format (signature r6cr)..."
if [ "$QUIET" -eq 1 ]; then
    $CVIMG_TOOL \
        -i userdata.jffs2 \
        -o userdata.bin \
        -e 0x80c00000 \
        -b 0x400000 \
        -s r6cr >/dev/null
else
    $CVIMG_TOOL \
        -i userdata.jffs2 \
        -o userdata.bin \
        -e 0x80c00000 \
        -b 0x400000 \
        -s r6cr
fi

# Remove intermediate file
rm -f userdata.jffs2

log ""
log "========================================="
log "  BUILD SUMMARY"
log "========================================="
if [ "$BUILD_COMPONENTS" -eq 1 ] && [ "$QUIET" -eq 0 ]; then
    echo "  Components: boothold, s40button, keepalive, serialgateway, otbr-monitor,"
    echo "              nano (vi -> nano symlink), otbr-agent, ot-ctl"
fi
log ""
if [ "$QUIET" -eq 0 ]; then
    ls -lh userdata.bin
    echo ""
fi
log "Userdata image ready: userdata.bin ($(ls -lh userdata.bin | awk '{print $5}'))"
log "RF hold:   $RF_HOLD (getty pre-commented in image: $([ "$RF_HOLD" = 1 ] && echo yes || echo no))"
log ""
log "To flash: ./flash_userdata.sh"
