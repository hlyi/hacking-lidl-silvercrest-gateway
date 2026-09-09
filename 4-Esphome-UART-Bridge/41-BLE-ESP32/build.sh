#!/bin/bash
# build.sh — Build ESP32-C3 BLE Proxy firmware
#
# Builds the ESPHome UART API Bridge firmware for ESP32-C3.
#
# Usage:
#   ./build.sh                  # Build firmware
#   ./build.sh clean            # Clean build
#   ./build.sh upload           # Build and upload via USB
#   ./build.sh ota              # Build and upload via OTA
#
# Prerequisites:
#   - esphome in PATH
#   - ESP-IDF framework (auto-installed by ESPHome)
#
# Output:
#   firmware/bleproxy-esp32c3.factory.bin  (USB flashing)
#   firmware/bleproxy-esp32c3.ota.bin      (OTA updates)

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="${SCRIPT_DIR}/esphome_uart_api"
OUTPUT_DIR="${SCRIPT_DIR}/firmware"
YAML_FILE="bleproxy_via_uart_esp32core.yaml"

# Handle arguments
case "${1:-}" in
    clean)
        echo "Cleaning build..."
        rm -rf "${REPO_DIR}/.esphome"
        rm -rf "${OUTPUT_DIR}"
        echo "Done."
        exit 0
        ;;
    upload)
        echo "Building and uploading via USB..."
        cd "${REPO_DIR}"
        esphome run "${YAML_FILE}" --device /dev/ttyUSB0
        exit $?
        ;;
    ota)
        echo "Building and uploading via OTA..."
        cd "${REPO_DIR}"
        esphome run "${YAML_FILE}" --device bleproxy-via-uart.local
        exit $?
        ;;
    --help|-h)
        sed -n '2,18p' "$0"
        exit 0
        ;;
    "")
        # Build only
        ;;
    *)
        echo "Unknown option: $1"
        echo "Use --help for usage"
        exit 1
        ;;
esac

echo "========================================="
echo "  ESP32-C3 BLE Proxy Firmware Builder"
echo "========================================="
echo ""

# Check esphome
if ! command -v esphome >/dev/null 2>&1; then
    echo "ERROR: esphome not found in PATH"
    echo ""
    echo "Install it first:"
    echo "  pip install esphome"
    exit 1
fi

echo "ESPHome: $(esphome version | head -1)"
echo ""

# Build firmware
echo "Building firmware..."
cd "${REPO_DIR}"
esphome compile "${YAML_FILE}"

# Copy output
echo ""
echo "Copying firmware to output directory..."
mkdir -p "${OUTPUT_DIR}"
cp "${REPO_DIR}/.esphome/build/bleproxy-via-uart/build/firmware.factory.bin" \
   "${OUTPUT_DIR}/bleproxy-esp32c3.factory.bin"
cp "${REPO_DIR}/.esphome/build/bleproxy-via-uart/build/firmware.ota.bin" \
   "${OUTPUT_DIR}/bleproxy-esp32c3.ota.bin"

echo ""
echo "========================================="
echo "  BUILD COMPLETE"
echo "========================================="
echo ""
echo "Firmware:"
ls -lh "${OUTPUT_DIR}/bleproxy-esp32c3."*.bin
echo ""
echo "Flash commands:"
echo "  USB:    esphome run ${YAML_FILE} --device /dev/ttyUSB0"
echo "  OTA:    esphome run ${YAML_FILE} --device bleproxy-via-uart.local"
echo ""
