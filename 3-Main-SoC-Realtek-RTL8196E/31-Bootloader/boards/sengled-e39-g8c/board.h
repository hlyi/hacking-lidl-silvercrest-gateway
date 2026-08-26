/*
 * board.h — Sengled Smart Hub E39-G8C ("Sengled G4")
 *
 * One directory per board under 31-Bootloader/boards/<board>/, selected
 * with `BOARD=<board> ./build_bootloader.sh` (default: lidl). Every
 * macro below is mandatory — see boards/README.md for the contract and
 * the validation requirements before flashing a new board.
 */
#ifndef __BOARD_H__
#define __BOARD_H__

/* Human-readable DRAM size, shown in the stage-2 banner ("RAM: 64MB"). */
#define BOARD_DRAM_BANNER "64MB"

/*
 * KSEG1 (uncached) address one past the last DRAM byte.  Drives the
 * boothold flag page (DRAM top - 0x2000; see boot/main.c) — this MUST
 * match the `boothold` reserved-memory node of the board's kernel DTS,
 * or `boothold && reboot` from Linux silently stops working.
 */
#define BOARD_DRAM_TOP_KSEG1 0xA4000000

/*
 * DDR controller bring-up values, written by btcode/start.S before any
 * DRAM access (nothing overwrites them later — these two macros ARE the
 * DRAM configuration).  Macros are named by REGISTER ADDRESS on purpose:
 * the historical names (DDR_TIMING_VAL at 0x1004, DDR1_32MB_193MHZ at
 * 0x1008) were swapped vs the usual DCR/DTR convention and misled DRAM
 * debugging more than once — go by the address, not by any name.
 */
#define BOARD_DDR_REG_1004 0x54880000	/* -> 0xB8001004 */
#define BOARD_DDR_REG_1008 0x91051D20	/* -> 0xB8001008: 64 MB DDR2 @ 193 MHz */

/*
 * RF reset pad (mandatory).
 *
 * The EFR32 nRST line, active-low: RTL GPIO 11 / pad B3 on this board
 * (the same pad the kernel DTS declares as `efr32-nrst`).  Referenced
 * only when the bootloader is built with HOLD_RF_RESET=1 (see
 * build_bootloader.sh): the loader then drives the pad LOW from the
 * first instruction of start_kernel() and keeps it there until
 * userspace releases it (nrst_pulse), so a device wired to that line —
 * e.g. an ESP32 BLE proxy whose CHIP_EN shares nRST — cannot drive
 * ttyS0 while the loader polls it for ESC.  It also leaves an "RFHD"
 * marker word in the boothold page so userspace can tell that the hold
 * happened.
 *
 * Contract — the code built around this macro only ever:
 *   - asserts the gate by DRIVING THE PAD LOW;
 *   - de-asserts by switching the pad to input (open-drain release);
 * it never drives the line HIGH.  The pull-up on nRST provides the
 * released-high level.
 *
 * Must be a port-B pad shared with the ASIC LED controller
 * (GPIO 10–14): those are the only pins whose PIN_MUX_SEL2 mux field
 * the switch-core init touches (and therefore preserves).
 */
#define BOARD_RF_RESET_GPIO 11

#endif /* __BOARD_H__ */
