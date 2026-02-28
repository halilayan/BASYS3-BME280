# BASYS3-BME280
# BME280 FPGA Environmental Sensor System

A fully synchronous FPGA-based environmental monitoring system that reads temperature, pressure, and humidity from a **Bosch BME280** sensor over SPI, streams the raw data to a host PC via UART, and processes it with a Python companion script that applies the BME280 compensation formulas and plots the results.

---

## System Overview

```
┌─────────────┐     SPI (Mode 0)     ┌─────────────┐
│   BME280    │◄────────────────────►│ spi_master  │
│   Sensor    │                      │  (VHDL)     │
└─────────────┘                      └──────┬──────┘
                                            │
                                   ┌────────▼────────┐
                                   │bme280_controller│
                                   │    (VHDL)       │
                                   └────────┬────────┘
                                            │
                                   ┌────────▼────────┐
                                   │    uart_tx      │
                                   │    (VHDL)       │
                                   └────────┬────────┘
                                            │ UART
                                   ┌────────▼────────┐
                                   │  bme_280_data   │
                                   │   (Python)      │
                                   └─────────────────┘
```

All four modules are wired together in `top_level.vhd`.

---

## Repository Structure

```
├── spi_master.vhd           # Generic SPI Master (Modes 0–3, configurable width/frequency)
├── bme280_controller.vhd    # BME280 init, calibration readout, and periodic ADC burst reads
├── uart_tx.vhd              # 8-N-2 UART transmitter
├── top_level.vhd            # Top-level instantiation and UART sequencer
└── bme_280_data.py          # Python parser: compensation, printing, and plotting
```

---

## VHDL Modules

### `spi_master.vhd`

A fully synchronous, generic SPI master controller.

| Generic | Default | Description |
|---|---|---|
| `clkfreq_g` | 100 MHz | System clock frequency (Hz) |
| `sclkfreq_g` | 10 MHz | Desired SPI clock frequency (Hz) |
| `cpol_g` | `'0'` | Clock polarity |
| `cpha_g` | `'0'` | Clock phase |
| `data_bit_g` | `8` | Transaction width in bits |

The internal clock divider derives SCLK from the system clock as `sclk_half = clkfreq / (sclkfreq × 2)`. An edge-detect stage generates single-cycle `leading` and `trailing` strobes that drive the shift-register logic, making the module correct for all four SPI modes.

**Ports:** `tx_en_i` triggers a transaction; `data_ready_o` pulses high for one clock when the received byte is valid on `data_o`.

---

### `bme280_controller.vhd`

Manages the full BME280 bring-up sequence and ongoing measurement loop.

**State machine:**

```
ST_INIT ──► ST_CAL1_READ ──► ST_CAL2_READ ──► ST_CAL3_READ ──► ST_CAL_DONE
                                                                      │
              ┌───────────────────────────────────────────────────────┘
              ▼
           ST_IDLE ──► ST_WAIT_MEAS ──► ST_BURST_READ ──► ST_PROCESS_DATA ──► ST_DONE
              ▲                                                                    │
              └────────────────────────────────────────────────────────────────────┘
```

**Initialisation (`ST_INIT`)** writes:
- `0x72 ← 0x01` — humidity oversampling ×1 (`ctrl_hum`)
- `0x74 ← 0x27` — temperature ×1, pressure ×1, forced/normal mode (`ctrl_meas`)

**Calibration readout** is a one-shot sequence across three states:
- `ST_CAL1_READ` — burst reads 24 bytes from registers `0x88–0x9F` → `calib[0..23]` (dig_T1–dig_P9)
- `ST_CAL2_READ` — single read from `0xA1` → `calib[24]` (dig_H1)
- `ST_CAL3_READ` — burst reads 7 bytes from `0xE1–0xE7` → `calib[25..31]` (dig_H2–dig_H6)

All 32 calibration bytes are packed MSB-first into the 256-bit output port `calib_data_o` and flagged with a one-cycle pulse on `calib_valid_o`.

**Measurement loop** waits `g_meas_wait` clock cycles (default 1 000 000), then burst-reads 8 bytes from `0xF7` (press_msb … hum_lsb). Raw 20-bit ADC values for temperature and pressure and 16-bit for humidity are presented on the output ports with a one-cycle `data_valid_o` pulse.

---

### `uart_tx.vhd`

An 8-N-2 UART transmitter clocked at 100 MHz with a baud divisor of 868, giving approximately **115 200 baud**. A `tx_start` pulse loads `data_in` and shifts it out LSB-first through the `START → DATA → STOP → DONE` state machine. `tx_done` pulses for one clock on completion; `tx_busy` stays high throughout the transfer.

---

### `top_level.vhd`

Wires the three modules together and contains a **UART sequencer** (`P_UART_SEQ`) that serialises all data to the host in two phases:

1. **Calibration phase** — triggered once by `calib_valid_o`. Sends a `0xFE` header followed by all 32 calibration bytes (33 bytes total).
2. **Measurement phase** — triggered by `data_valid_o` with a 50 000 000-cycle rate limiter (~0.5 s at 100 MHz). Sends a `0xFF` header followed by 8 data bytes encoding the 20-bit temperature, 20-bit pressure, and 16-bit humidity values.

The SPI CS line is managed by `bme280_controller`; the `cs_o` pin from `spi_master` is left unconnected in this design since the controller drives CS directly.

---

## Python Companion Script — `bme_280_data.py`

Paste the raw hex dump received over UART into the `hex_data` string at the top of the file, then run:

```bash
python bme_280_data.py
```

The script:
1. Locates the `0xFE` calibration frame and unpacks all dig_T, dig_P, and dig_H coefficients.
2. Iterates over every subsequent `0xFF` measurement frame and applies the **official Bosch integer compensation formulas** for temperature (°C), pressure (hPa), and humidity (%RH).
3. Prints a table of all readings.
4. Renders three time-series plots using `matplotlib`.

### Wire Protocol Summary

| Byte | Calibration frame (`0xFE`) | Measurement frame (`0xFF`) |
|------|---------------------------|----------------------------|
| 0 | `0xFE` (header) | `0xFF` (header) |
| 1–32 | calib[0]…calib[31] | temp[19:12] |
| — | — | temp[11:4] |
| — | — | temp[3:0] \|\| `0000` |
| — | — | press[19:12] |
| — | — | press[11:4] |
| — | — | press[3:0] \|\| `0000` |
| — | — | hum[15:8] |
| — | — | hum[7:0] |

---

## Getting Started

### Hardware Requirements

- FPGA board with a 100 MHz system clock (e.g. Basys 3, Arty A7, Nexys A7)
- BME280 breakout board connected via SPI
- USB-UART bridge for data capture (e.g. on-board FTDI or CP2102)

### FPGA Build

1. Add all four `.vhd` files to your project (Vivado / Quartus / ISE).
2. Set `top_level` as the top module.
3. Assign pins: `clk_i`, `rst_i`, `spi_cs_o`, `spi_sclk_o`, `spi_mosi_o`, `spi_miso_i`, `uart_tx_o`.
4. Synthesise, implement, generate bitstream and program the device.

### Data Capture & Plotting

1. Open a serial terminal at **115200 8-N-2** and capture the raw output to a file, or copy the hex stream.
2. Paste the hex string into `hex_data` in `bme_280_data.py`.
3. Install dependencies if needed:
   ```bash
   pip install matplotlib
   ```
4. Run the script:
   ```bash
   python bme_280_data.py
   ```

---

## Configuration

| Parameter | Location | Purpose |
|---|---|---|
| `sclkfreq_g` | `top_level.vhd` | SPI clock speed |
| `g_meas_wait` | `bme280_controller.vhd` | Delay between measurements (clock cycles) |
| `TX_RATE_LIMIT` | `top_level.vhd` | Minimum cycles between UART transmissions |
| `baudrate` | `uart_tx.vhd` | UART baud divisor (868 → 115 200 baud @ 100 MHz) |

---

## Author

**Halil Ibrahim Ayan** — FPGA design (SPI master, BME280 controller, top-level integration)