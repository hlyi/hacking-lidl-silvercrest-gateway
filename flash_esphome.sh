#!/bin/bash
# flash_esphome.sh — Flash ESPHome firmware to ESP32-C3 via UART API Bridge
#
# Flow:
#   1. Calls toggle_ota.py to trigger the ESP32 into OTA mode (via TCP 6053)
#   2. Reconfigures kernel bridge from port 6053 to port 3232
#   3. Waits for ESP32 to restart and listen on OTA port 3232
#   4. Flashes firmware via ESPHome OTA to port 3232
#   5. Restores kernel bridge to original port 6053
#
# Usage:
#   ./flash_esphome.sh                      # Interactive menu
#   ./flash_esphome.sh -y                   # Skip confirmation
#   ./flash_esphome.sh -g 10.0.0.5          # Specify gateway IP
#   ./flash_esphome.sh -y --firmware-file path/to/firmware.ota.bin
#
# Prerequisites:
#   - esphome in PATH
#   - python3 with aioesphomeapi, pyserial
#   - SSH access to gateway (for bridge management)
#
# J. Nilo — September 2026

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/lib/gwconf.sh"
GW_PORT=6053
gwconf_resolve_gateway
GW_IP_DEFAULT="$GWCONF_ADDR"
GW_IP_DEFAULT_SOURCE="$GWCONF_ADDR_SOURCE"
VENV_DIR="${SCRIPT_DIR}/silabs-flasher"
ESPHOME_DIR="${SCRIPT_DIR}/4-Esphome-UART-Bridge/41-BLE-ESP32/esphome_uart_api"
YAML_FILE="bleproxy_via_uart_esp32core.yaml"
FIRMWARE_DIR="${SCRIPT_DIR}/4-Esphome-UART-Bridge/41-BLE-ESP32/firmware"
BRIDGE_SYSFS="/sys/module/rtl8196e_uart_bridge/parameters"

# --- CLI parsing ---------------------------------------------------------

usage() {
    cat <<'USAGE'
Usage: flash_esphome.sh [OPTIONS]

Flash ESPHome firmware to ESP32-C3 via the UART API Bridge.

Options:
  -g, --gateway IP   Gateway IP. Default: GW_IP, else gateway.env, else the
                     last gateway installed or reached, else its hostname.
  -y, --yes          Skip the "Flash?" confirmation prompt
      --firmware-file PATH
                     Flash this exact .bin file instead of resolving by glob
      --build        Build firmware before flashing
      --no-reboot    Do not reboot the gateway after flash
  -h, --help         Show this help and exit

Environment variables:
  SSH_PASSWORD   Root password for non-interactive password auth (CI / no
                 tty). When set, the first ssh call is fed via sshpass and
                 the ControlMaster takes over for the rest. Requires
                 sshpass (sudo apt install sshpass).
USAGE
}

# Parse arguments
GW_IP=
CONFIRM_FLAG=
FIRMWARE_FILE=
BUILD_FIRST=0
NO_REBOOT=0

while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help)         usage; exit 0 ;;
        -y|--yes)          CONFIRM_FLAG=y; shift ;;
        -g|--gateway)
                           shift
                           if [ $# -eq 0 ]; then
                               echo "Error: --gateway requires an argument." >&2
                               exit 1
                           fi
                           GW_IP="$1"; shift
                           ;;
        --gateway=*)       GW_IP="${1#--gateway=}"; shift ;;
        --firmware-file)
                           shift
                           if [ $# -eq 0 ]; then
                               echo "Error: --firmware-file requires an argument." >&2
                               exit 1
                           fi
                           FIRMWARE_FILE="$1"; shift
                           ;;
        --firmware-file=*) FIRMWARE_FILE="${1#--firmware-file=}"; shift ;;
        --build)           BUILD_FIRST=1; shift ;;
        --no-reboot)       NO_REBOOT=1; shift ;;
        --)                shift; break ;;
        -*)
                           echo "Error: unknown option '$1'. See --help." >&2
                           exit 1
                           ;;
        *)
                           echo "Error: unexpected argument '$1'. See --help." >&2
                           exit 1
                           ;;
    esac
done

# Resolve gateway IP
if [ -z "$GW_IP" ]; then
    GW_IP="$GW_IP_DEFAULT"
    echo "Gateway: ${GW_IP}$(gwconf_source_note "$GW_IP_DEFAULT_SOURCE")"
fi
if ! echo "$GW_IP" | grep -qE '^[a-zA-Z0-9.-]+$'; then
    echo "Error: invalid --gateway value '$GW_IP'." >&2
    exit 1
fi

# --- Dependency checks ---------------------------------------------------

if ! command -v python3 >/dev/null 2>&1; then
    echo "Error: python3 not found." >&2
    echo "Install it with: sudo apt install python3" >&2
    exit 1
fi
if ! command -v esphome >/dev/null 2>&1; then
    echo "Error: esphome not found." >&2
    echo "Install it with: pip install esphome" >&2
    exit 1
fi
if ! python3 -c "import aioesphomeapi" 2>/dev/null; then
    echo "Installing aioesphomeapi..."
    pip3 install aioesphomeapi pyserial 2>/dev/null || {
        echo "Error: failed to install aioesphomeapi." >&2
        echo "Install manually: pip3 install aioesphomeapi pyserial" >&2
        exit 1
    }
fi
if [ -n "${SSH_PASSWORD:-}" ] && ! command -v sshpass >/dev/null 2>&1; then
    echo "Error: SSH_PASSWORD is set but sshpass is not installed." >&2
    echo "Install it with: sudo apt install sshpass" >&2
    exit 1
fi

. "${SCRIPT_DIR}/lib/ssh.sh"

ssh_gw() {
    local target="root@${GW_IP}"
    if [ $# -gt 0 ]; then
        ssh_retry "${SSH_HARDEN_OPTS[@]}" -o StrictHostKeyChecking=accept-new "$target" "$@"
    else
        ssh_retry "${SSH_HARDEN_OPTS[@]}" -o StrictHostKeyChecking=accept-new "$target" 'sh -s'
    fi
}

# --- Build firmware if requested -----------------------------------------

if [ "$BUILD_FIRST" -eq 1 ]; then
    echo "Building ESPHome firmware..."
    cd "${ESPHOME_DIR}"
    esphome compile "${YAML_FILE}"
    # Copy to firmware directory
    mkdir -p "${FIRMWARE_DIR}"
    cp "${ESPHOME_DIR}/.esphome/build/bleproxy-via-uart/build/firmware.factory.bin" \
       "${FIRMWARE_DIR}/bleproxy-esp32c3.factory.bin"
    cp "${ESPHOME_DIR}/.esphome/build/bleproxy-via-uart/build/firmware.ota.bin" \
       "${FIRMWARE_DIR}/bleproxy-esp32c3.ota.bin"
    echo "Build complete."
    echo ""
fi

# --- Resolve firmware file -----------------------------------------------

if [ -n "$FIRMWARE_FILE" ]; then
    if [ ! -f "$FIRMWARE_FILE" ]; then
        echo "Error: firmware file not found: $FIRMWARE_FILE" >&2
        exit 1
    fi
    FIRMWARE="$FIRMWARE_FILE"
else
    # Look for the latest OTA firmware
    FIRMWARE="${FIRMWARE_DIR}/bleproxy-esp32c3.ota.bin"
    if [ ! -f "$FIRMWARE" ]; then
        echo "Error: no firmware found at $FIRMWARE" >&2
        echo "Build first with: ./flash_esphome.sh --build" >&2
        echo "Or specify: --firmware-file PATH" >&2
        exit 1
    fi
fi

echo ""
echo "Firmware: $(basename "$FIRMWARE")"
echo "Image:    $FIRMWARE"
echo "Gateway:  ${GW_IP}"
echo ""

# --- Detect bridge status ------------------------------------------------

echo "Connecting to ${GW_IP} — detecting bridge status..."
if ! ssh_prime_with_password "${SSH_HARDEN_OPTS[@]}" \
        -o StrictHostKeyChecking=accept-new "root@${GW_IP}"; then
    exit 1
fi

# Check if bridge is active on port 6053 (alt-uart0 mode)
BRIDGE_STATUS=$(ssh_gw "BRIDGE_SYSFS='$BRIDGE_SYSFS' sh -s" <<'REMOTE_EOF'
if [ ! -d "$BRIDGE_SYSFS" ]; then
    echo "STATUS=no-bridge"
    exit 0
fi
BRIDGE_TTY=$(cat "$BRIDGE_SYSFS/tty" 2>/dev/null || echo "")
BRIDGE_PORT=$(cat "$BRIDGE_SYSFS/port" 2>/dev/null || echo "")
BRIDGE_ARMED=$(cat "$BRIDGE_SYSFS/armed" 2>/dev/null || echo "0")
echo "STATUS=ok"
echo "TTY=$BRIDGE_TTY"
echo "PORT=$BRIDGE_PORT"
echo "ARMED=$BRIDGE_ARMED"
REMOTE_EOF
)

detect_get() { echo "$BRIDGE_STATUS" | awk -F= -v k="$1" '$1==k {print $2}' | tail -1; }
DETECT_STATUS=$(detect_get STATUS)
BRIDGE_TTY=$(detect_get TTY)
BRIDGE_PORT=$(detect_get PORT)
BRIDGE_ARMED=$(detect_get ARMED)

case "$DETECT_STATUS" in
    ok) ;;
    no-bridge)
        echo "Warning: in-kernel UART bridge not found on ${GW_IP}." >&2
        echo "Continuing anyway — ESP32 may be reachable directly." >&2
        ;;
    *)
        echo "Error: unexpected bridge detection status: ${DETECT_STATUS}" >&2
        exit 1
        ;;
esac

# Determine if we're in alt-uart0 mode (bridge on ttyS0 at port 6053)
ALTUART0_MODE=0
if echo "$BRIDGE_TTY" | grep -q '/dev/ttyS0' && [ "$BRIDGE_PORT" = "6053" ]; then
    ALTUART0_MODE=1
    echo "Alt-uart0 mode detected: bridge on ttyS0:6053"
fi

# --- Step 1: Trigger OTA mode --------------------------------------------
# Must be done BEFORE disabling the bridge — toggle_ota.py needs the bridge
# active to communicate with the ESP32 via TCP 6053.

echo ""
echo "[1/4] Triggering OTA mode on ESP32..."
TOGGLE_SCRIPT="${ESPHOME_DIR}/toggle_ota.py"
if [ ! -f "$TOGGLE_SCRIPT" ]; then
    echo "Error: toggle_ota.py not found at $TOGGLE_SCRIPT" >&2
    exit 1
fi

python3 "$TOGGLE_SCRIPT" "${GW_IP}:6053" on
echo "  OTA mode enabled."

# --- Step 2: Reconfigure bridge for OTA ----------------------------------
# Disable bridge, reconfigure to listen on port 3232, re-enable.
# ESPHome needs the bridge active on port 3232 for OTA flashing.

echo ""
echo "[2/4] Reconfiguring UART bridge for OTA..."
if [ "$ALTUART0_MODE" -eq 1 ] && [ "$BRIDGE_ARMED" = "1" ]; then
    ssh_gw "
        # Disable bridge
        echo 0 > ${BRIDGE_SYSFS}/enable 2>/dev/null || true
        sleep 0.5
        # Reconfigure to port 3232
        echo 3232 > ${BRIDGE_SYSFS}/port 2>/dev/null || true
        # Re-enable bridge
        echo 1 > ${BRIDGE_SYSFS}/enable 2>/dev/null || true
        sleep 1
        # Verify
        if [ \"\$(cat ${BRIDGE_SYSFS}/armed 2>/dev/null)\" != '1' ]; then
            echo 'ERROR: bridge failed to arm on port 3232'
            exit 1
        fi
    " >/dev/null 2>&1 || {
        echo "Error: failed to reconfigure bridge for OTA on ${GW_IP}." >&2
        echo "The bridge may be in an inconsistent state. Reboot the gateway." >&2
        exit 1
    }
    echo "  Bridge reconfigured: port 3232."
else
    echo "  Bridge not active on 6053 — skipping reconfiguration."
fi

# --- Step 3: Wait for ESP32 to enter OTA mode ----------------------------

echo ""
echo "[3/4] Waiting for ESP32 to enter OTA mode..."
echo "  (ESP32 will restart and listen on port 3232)"

# Wait for port 3232 to become available
OTA_READY=0
for i in $(seq 1 30); do
    if nc -z -w1 "$GW_IP" 3232 2>/dev/null; then
        OTA_READY=1
        break
    fi
    sleep 1
done

if [ "$OTA_READY" -ne 1 ]; then
    echo "Error: ESP32 did not enter OTA mode within 30 seconds." >&2
    echo "Check that the ESP32 is connected and running the UART API Bridge firmware." >&2
    exit 1
fi
echo "  ESP32 is ready for OTA on port 3232."

# --- Step 4: Flash firmware via ESPHome ----------------------------------

echo ""
echo "[4/4] Flashing firmware..."

# Use ESPHome's upload command with explicit device address
cd "${ESPHOME_DIR}"
esphome upload "${YAML_FILE}" --device "${GW_IP}"

echo ""
echo "========================================="
echo "  FLASH COMPLETE"
echo "========================================="

# --- Restore bridge ------------------------------------------------------

echo ""
echo "Restoring UART bridge..."
if [ "$ALTUART0_MODE" -eq 1 ]; then
    ssh_gw "
        # Disable bridge
        echo 0 > ${BRIDGE_SYSFS}/enable 2>/dev/null || true
        sleep 0.5
        # Restore original port
        echo ${BRIDGE_PORT:-6053} > ${BRIDGE_SYSFS}/port 2>/dev/null || true
        # Re-enable bridge
        echo 1 > ${BRIDGE_SYSFS}/enable 2>/dev/null || true
        sleep 1
    " >/dev/null 2>&1 || true
    echo "  Bridge restored: port ${BRIDGE_PORT:-6053}."
else
    echo "  No bridge restoration needed."
fi

if [ "$NO_REBOOT" -ne 1 ]; then
    echo ""
    echo "Rebooting gateway..."
    ssh_gw "reboot" >/dev/null 2>&1 || true
    echo "Gateway is rebooting."
else
    echo ""
    echo "Skipping gateway reboot (--no-reboot)."
fi

echo ""
echo "Done."
