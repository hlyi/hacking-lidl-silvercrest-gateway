# BLE proxy over ttyS0 (experimental hardware mod)

Turn a Sengled G4 gateway into an **ESPHome BLE proxy that is wired to
Ethernet** — no 2.4 GHz Wi-Fi next to your Zigbee network, and the idle
RTL8196E does useful work. The ESP32-C3 speaks [ESPHome's native API]
over its UART; the gateway is only a byte pipe between that UART and a
TCP socket, using the same in-kernel UART bridge that serves the radio.

This is a personal hardware experiment (discussion [#146]). It requires
opening the box and soldering four wires plus one trace tap; it is not
part of any supported firmware configuration.

[ESPHome's native API]: https://esphome.io/components/api.html

## Architecture

```text
Home Assistant ── Ethernet ──> RTL8196E :6053
                                 │  kernel rtl8196e_uart_bridge (single
                                 │  instance, permanently on ttyS0)
                                 │  TCP <-> /dev/ttyS0 (230400 8N1)
                            ESP32-C3  (bluetooth_proxy, uart_api)

Home Assistant ── Ethernet ──> RTL8196E :8888
                                 │  serialgateway (userspace daemon)
                                 │  TCP <-> /dev/ttyS1
                            EFR32MG13  (standalone z3-router firmware)
```

The EFR32 runs standalone **z3-router** firmware: it extends the Zigbee
mesh by itself. Its host link on ttyS1 is the userspace `serialgateway`
daemon, not the kernel bridge — the kernel bridge is a single instance
and stays bound to ttyS0 (:6053) for the life of the mode, so Home
Assistant's ESPHome connection is never interrupted, including while the
EFR32 is being flashed through serialgateway.

## Wiring

| Gateway            | ESP32-C3            | Note                          |
| ------------------ | ------------------- | ----------------------------- |
| ttyS0 TX (J1)      | RX (GPIO6)          | 3.3 kΩ series resistor        |
| ttyS0 RX (J1)      | TX (GPIO7)          | 3.3 kΩ series resistor        |
| EFR32 nRST net     | CHIP_EN             | shared active-low reset line  |
| 5 V                | VCC (board LDO out) | common ground                 |

- GPIO6/GPIO7 are not ESP32-C3 UART0 strapping pins; series resistors
  are still recommended per the ESP32-C3 datasheet (power-up glitch on
  MTCK/MTDO).
- Powering the ESP32 from the gateway's 5 V rail through the board's own
  3.3 V regulator keeps the 3.3 V domain clean; keep grounds common and
  decouple locally.
- Sharing nRST with CHIP_EN works because both are active-low and the
  system **never drives the line HIGH** — it either pulls LOW or
  releases to the pull-up (open-drain discipline). Consequence: every
  EFR32 reset also resets the ESP32.

## What holds the ESP32 in reset during boot

The bootloader polls ttyS0 for `ESC` at power-on; an ESP32 left powered
would inject framing garbage into that poll and could drop the box into
download mode. So a bootloader built with **`HOLD_RF_RESET=1`** gates
the shared reset itself:

```sh
HOLD_RF_RESET=1 BOARD=sengled-e39-g8c ./build_bootloader.sh   # G4: gpio 11
HOLD_RF_RESET=true BOARD=lidl           ./build_bootloader.sh # Lidl: gpio 12
```

- The pad comes from `BOARD_RF_RESET_GPIO` in each board's `board.h`
  (`31-Bootloader/boards/<board>/board.h`), so any board can opt in —
  builds without the env var are bit-for-bit unchanged.
- On entry to `start_kernel()` — before even the console comes up — the
  loader muxes the pad to GPIO mode and **drives it LOW**, tri-stating
  the ESP32 pins. Nothing later flips the mux back: the two
  `PIN_MUX_SEL2` writes in `swCore_init()` preserve that pad's field.
- A USB-UART dongle on J1 still sees all boot messages and can still
  send `ESC`: the dongle simply overpowers nothing — the ESP32 is not
  driving, so the console behaves exactly as on a stock unit.
- The loader also stamps an `"RFHD"` marker word into the reserved
  boothold DRAM page, so init scripts can tell at runtime that the hold
  is active (the build flag itself is invisible to userspace).
- Userspace releases the gate via the existing `nrst_pulse` knob:
  early (`S08rfreset`) on units that keep ttyS0 as console, late
  (`altuart0 start`, invoked by the S99 shim) once the bridge owns
  ttyS0.

## Userspace changes

| Piece | Purpose |
| --- | --- |
| `/etc/inittab -> /userdata/etc/inittab` symlink | Packaged only when the rootfs is built with `HOLD_RF_RESET=1` (same flag as the bootloader). init reads the table before `/userdata` is mounted and falls back to built-ins (`rcS`); the table is only re-read (`kill -HUP 1`) by the `S99enablealtuart0` shim, which is also the only place the getty respawn is controlled. Plain builds keep the stock regular file, and the handover refuses to run on them. |
| `S08rfreset` | On units not in alt-uart0 mode (ttyS0 getty respawn entry active in the userdata inittab): if the bootloader stamped the `RFHD` hold marker (read via `/dev/mem` at the boothold page), consume it and pulse-release the RF reset so the radio starts normally. No-op on stock bootloaders. |
| `S50uart_bridge` guard | Skips arming in alt-uart0 mode — the kernel bridge belongs to ttyS0 (`altuart0`), never ttyS1. |
| `S60serialgateway` | Userspace TCP<->serial bridge for ttyS1 (:8888), started only in alt-uart0 mode (the kernel bridge is busy with ttyS0). Gives Home Assistant direct access to the z3-router coordinator and carries EFR32 flashing traffic. Baud follows radio.conf `FIRMWARE_BAUD`. |
| `S70otbr` guard | Skips otbr-agent in alt-uart0 mode — the EFR32 runs standalone z3-router, ttyS1 belongs to serialgateway. |
| `/etc/init.d/altuart0` service | All alt-uart0 functionality lives here: `start` (handover: disarm bridge, stop getty, optionally unbind/rebind `of_serial`, `dmesg -n 1`, arm `tcp://:6053 <-> /dev/ttyS0` with `flow_control=none`, consume the RFHD marker, release reset ~10 s later), `stop`, `console` (getty back), `enable` (marker + handover), `status`, `chk_enabled`, `chk_rfmagic`, `consume_rfmagic`. It never runs `kill -HUP 1` itself. |
| `S99enablealtuart0` shim | Boot-order wrapper around `altuart0`: runs the handover last, then — only if `/etc/inittab` is a symlink into `/userdata` — reloads init's table (`kill -HUP 1`). Forwarded subcommands get the same reload. |

!!! warning "No serial login while the proxy is enabled"

    ttyS0 is the ESP32 link; the getty is commented out of the inittab
    and kernel messages are silenced on the console. Manage the box over
    SSH only. Post-mortem visibility comes from the panic record
    (`/userdata/panic/`) and `/var/log/messages`.

## Setup

```sh
# 1. Build + flash ALL THREE images with HOLD_RF_RESET=1 (bootloader;
#    rootfs — controls the /etc/inittab symlink; userdata — packages
#    /userdata/etc/inittab with the getty line already commented out),
#    and flash the EFR32 with z3-router (see docs/radio-options.md), then:
ssh root@<gateway-ip>

# 2. Enable the mod (rf-hold userdata images ship enabled; this is only
#    needed if 'console' was used before, or to apply custom tuning)
cp /userdata/etc/alt-uart0.conf.example /userdata/etc/alt-uart0.conf
vi /userdata/etc/alt-uart0.conf         # optional tuning keys only
/etc/init.d/S99enablealtuart0 enable    # or just reboot

# 3. Verify
cat /sys/module/rtl8196e_uart_bridge/parameters/armed    # 1
grep ttyS0 /proc/tty/driver/serial                       # oe: must stay 0
cat /var/log/alt-uart0.log                               # handover log

# 4. Home Assistant: add the ESPHome integration, host = <gateway-ip>
#    (port 6053 is the native-API default, no override needed)
```

There is no ENABLE_ALT_UART0 switch: the mode is derived from
`/userdata/etc/inittab` — the ttyS0 getty respawn entry commented out with
the `#[altuart0]` marker means an external device owns ttyS0.
`S99enablealtuart0 enable` adds it, `console` removes it. Tuning keys live
in [`alt-uart0.conf.example`]
(../3-Main-SoC-Realtek-RTL8196E/34-Userdata/skeleton/etc/alt-uart0.conf.example):
`ALT_BAUD` (default 230400 — raise only after the soak proves the link),
`ALT_PORT` (6053), `ALT_BIND`, `ALT_UNBIND` (leave 0).

## Reflashing the EFR32 afterwards

Nothing to retarget: serialgateway keeps serving `ttyS1` on :8888, which
is exactly what the flash script talks to.

```sh
# from the build host:
./flash_efr32.sh <gateway-ip>      # socket://<gw>:8888 via serialgateway
```

The ESP32 link on :6053 is unaffected — Home Assistant stays connected
throughout.

## Updating the ESP32 firmware over the same link

With the bridge pointed at the ESP32, switch the port to 3232 and use
`esphome upload` from the build host:

```sh
ssh root@<gateway-ip> sh -c '
  echo 0 > /sys/module/rtl8196e_uart_bridge/parameters/enable
  echo 3232 > /sys/module/rtl8196e_uart_bridge/parameters/port
  echo 115200 > /sys/module/rtl8196e_uart_bridge/parameters/baud
  echo 1 > /sys/module/rtl8196e_uart_bridge/parameters/enable'
# trigger the ESP32 OTA/bootstrap mode with your usual script, then:
esphome upload ble-proxy.yaml --device <gateway-ip>   # port 3232
ssh root@<gateway-ip> /etc/init.d/S99enablealtuart0 restart
```

## Known limitations

- **Single-client servers on both ports.** The kernel bridge serves one
  TCP client at a time: Home Assistant's ESPHome connection owns :6053.
  serialgateway likewise serves one client: whoever holds :8888 (Home
  Assistant's Zigbee link, or a flash run).
- **ttyS0 has no flow control** and a 16-byte FIFO. Watch the `oe:`
  counter under load; if it increments, lower `ALT_BAUD`. The same
  applies to serialgateway's ttyS1 link.
- **Console loss is by design.** Recovery paths: panic record in
  `/userdata/panic/`, boothold prompt via `boothold`, and full serial
  recovery returns the moment you run
  `/etc/init.d/S99enablealtuart0 console` (or reflash with a dongle —
  the bootloader hold never touches a dongle-connected console).
- **Kernel console stays registered** on ttyS0 (no bootarg/DTS changes):
  `dmesg -n 1` reduces output to KERN_EMERG. A panic will spray bytes at
  the ESP32 link — harmless, the box is dead anyway and the record is in
  `/userdata/panic/`.
