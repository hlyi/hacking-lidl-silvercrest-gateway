# lib/hold_rf_reset.sh — single checker for the HOLD_RF_RESET build flag.
#
# Sourced by every image build script that honours the flag:
#   31-Bootloader/build_bootloader.sh   (bootloader holds the shared RF
#                                        reset pad through boot)
#   33-Rootfs/build_rootfs.sh           (/etc/inittab symlink)
#   33-Rootfs/busybox/build_busybox.sh  (builtin fallback inittab patch)
#   34-Userdata/build_userdata.sh       (/userdata/etc/inittab getty
#                                        pre-commented + serialgateway)
#
# Usage:
#   . "${LIB_DIR}/hold_rf_reset.sh"
#   hold_rf_reset_parse || exit 1
#
# After parsing:
#   RF_HOLD       - 1 if HOLD_RF_RESET is truthy, else 0
#   HOLD_RF_RESET - normalized to "1" when enabled (exported, so sub-makes
#                   and child build scripts see a canonical value)
#
# All images flashed onto one unit must be built with the same value;
# userspace cannot detect the bootloader's flag at runtime (the RFHD
# marker only says whether the hold is active this boot). See
# docs/ble-proxy.md for the full picture.

hold_rf_reset_parse() {
    case "${HOLD_RF_RESET:-0}" in
        1|[Tt]rue|[Yy]es|[Oo]n)
            RF_HOLD=1
            HOLD_RF_RESET=1
            ;;
        0|""|[Ff]alse|[Nn]o|[Oo]ff)
            RF_HOLD=0
            ;;
        *)
            echo "ERROR: invalid HOLD_RF_RESET '${HOLD_RF_RESET}' (use 1/true/yes/on or 0/false/no/off)" >&2
            return 1
            ;;
    esac
}
