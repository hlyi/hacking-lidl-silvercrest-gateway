# ESP32-C3 BLE Proxy via UART

This directory contains the ESPHome UART API Bridge firmware for ESP32-C3, which provides BLE proxy functionality over UART instead of TCP.

## Architecture

```
RTL8196E (UART)  ──UART──  ESP32-C3  ──loopback TCP──  ESPHome API Server
  (230400 baud)           (uart_api)                   (port 6053)
```

The firmware bridges UART communication from the RTL8196E to ESPHome's Native API via a loopback TCP connection on the ESP32-C3.

## Directory Structure

```
41-BLE-ESP32/
├── esphome_uart_api/       # Cloned from https://github.com/hlyi/esphome_uart_api
├── firmware/               # Built firmware binaries
│   ├── bleproxy-esp32c3.factory.bin   # For USB flashing
│   └── bleproxy-esp32c3.ota.bin       # For OTA updates
├── build.sh               # Build script
└── README.md              # This file
```

## Building

### Prerequisites

- ESPHome (`pip install esphome`)
- ESP-IDF framework (auto-installed by ESPHome on first build)

### Build Commands

```bash
# Build firmware only
./build.sh

# Build and upload via USB
./build.sh upload

# Build and upload via OTA
./build.sh ota

# Clean build
./build.sh clean
```

## Flashing

### USB Flashing (First Time)

1. Connect ESP32-C3 to USB
2. Put in bootloader mode (hold BOOT, press RESET)
3. Run:
   ```bash
   esphome run bleproxy_via_uart_esp32c3_super_mini_plus.yaml --device /dev/ttyUSB0
   ```

### OTA Updates

After initial USB flash, updates can be done over the air:
```bash
esphome run bleproxy_via_uart_esp32c3_super_mini_plus.yaml --device bleproxy-via-uart.local
```

## Configuration

The firmware is configured for:

- **Board**: ESP32-C3 DevKitM-1
- **Framework**: ESP-IDF
- **UART**: TX=GPIO7, RX=GPIO6, 230400 baud
- **API Port**: 6053
- **BLE Proxy**: 4 connection slots, passive scanning

## LED Status

- **Red**: OTA mode active
- **Green**: Normal operation

## Integration with RTL8196E Gateway

This firmware works with the `altuart0` mode in the RTL8196E gateway:

1. Gateway bridges ttyS0 (ESP32-C3) to Home Assistant on port 6053
2. ESP32-C3 bridges UART to loopback TCP on port 6053
3. Home Assistant connects to ESPHome API via the gateway

## References

- [ESPHome UART API Bridge](https://github.com/hlyi/esphome_uart_api)
- [BLE Proxy Documentation](../../docs/ble-proxy.md)
