# Base driver interfaces

Covers: drivers/build.zig, drivers/src/root.zig, drivers/src/base/, drivers/src/display/, drivers/src/input/, drivers/src/io_expander/, drivers/src/led/ws2812.zig, drivers/src/sensor/, drivers/src/stepper/, drivers/src/wireless/cyw43/bus.zig, drivers/src/wireless/nrf24l01.zig, port/espressif/esp/src/hal/drivers.zig, port/espressif/esp/src/hal/i2c.zig, port/espressif/esp/src/hal/spi.zig, port/espressif/esp/src/hal/uart.zig, port/microchip/atmega/src/hals/atmega328p/drivers.zig, port/microchip/atmega/src/hals/atmega328p/time.zig, port/nordic/nrf5x/src/hal/drivers.zig, port/nordic/nrf5x/src/hal/i2c.zig, port/nordic/nrf5x/src/hal/i2cdma.zig, port/nordic/nrf5x/src/hal/spim.zig, port/nordic/nrf5x/src/hal/time.zig, port/nxp/mcx/src/mcxn947/hal/flexcomm/LP_I2C.zig, port/raspberrypi/rp2xxx/src/hal/drivers.zig, port/raspberrypi/rp2xxx/src/hal/i2c.zig, port/raspberrypi/rp2xxx/src/hal/spi.zig, port/stmicro/stm32/src/hals/STM32F103/drivers.zig, port/stmicro/stm32/src/hals/STM32F103/i2c.zig, port/stmicro/stm32/src/hals/common/i2c_v2.zig, port/stmicro/stm32/src/hals/common/pins_v2.zig, port/stmicro/stm32/src/hals/common/spi_v2.zig, port/stmicro/stm32/src/hals/common/systick_timer.zig, port/stmicro/stm32/src/hals/common/systick.zig, port/wch/ch32v/src/hals/drivers.zig, port/wch/ch32v/src/hals/gpio.zig, port/wch/ch32v/src/hals/i2c.zig, port/wch/ch32v/src/hals/spi.zig, port/wch/ch32v/src/hals/dma.zig, port/wch/ch32v/src/hals/time.zig, port/wch/ch32v/src/chips/, examples/espressif/esp/build.zig, examples/espressif/esp/src/selftest_i2c.zig, examples/espressif/esp/src/selftest_uart.zig, port/espressif/esp/README.md, examples/nordic/nrf5x/src/selftest/sense.zig, examples/nxp/mcx/src/lp_i2c.zig, examples/raspberrypi/rp2xxx/src/rp2350_only/always_on_timer.zig

## Purpose

Portable drivers call device operations supplied by a HAL, another driver or a test.
The application configures the concrete device and lends a handle to the consumer.

## Code map

- `drivers/src/root.zig:base` exports the runtime device types. Some consumers also accept concrete adapters.
- `drivers/src/root.zig:DateTime` exports the calendar value, and `drivers/src/root.zig:time` supplies monotonic types.

## Invariants

Hand out handles after peripheral initialization and retire them before teardown.
Handles borrow an erased context and point to a constant vtable. `BlockMemory` stores
its table by value. Keep contexts stationary and tables alive while borrowed.

Calls may report acceptance before hardware finishes. End the borrow of caller buffers
and their vectors on every return, including errors. Use adapter-owned storage for DMA
that outlives the call. Serialize unguarded shared buses and staging storage, and reserve
the bus from selection through deselection. Check the adapter's timeout scope and ISR rules.

- `drivers/src/base/BlockMemory.zig:VTable` has optional write enable and disable hooks
  that default to no-ops. Absent data or sector-size slots return `Unsupported`.
  `write` checks capacity, erases the indexed sector, then writes. Failed writes can
  leave a sector erased. Read by byte offset and use the count to bound valid data.
- `drivers/src/base/ClockDevice.zig:VTable` requires a monotonic microsecond clock since
  boot. `sleep_us` uses the blocking hook or polls a deadline, so keep the clock
  advancing in the caller's context. A saved `Timeout` borrows the clock through its handle.
- `drivers/src/base/DateTime.zig:from_timestamp` converts epoch milliseconds to a calendar value formatted in caller storage.
- `drivers/src/base/DatagramDevice.zig:VTable` has optional connect and disconnect hooks.
  They default to no-ops. Pair a successful connect with disconnect when using device
  selection. Absent slots return `Unsupported`. Read returns a count and on `BufferOverrun`
  fills the buffers and discards the rest. Fill every RX byte before returning success from
  write-then-read or full duplex. For full duplex, match the total lengths of both vectors.
- `drivers/src/base/Digital_IO.zig:VTable` requires direction, bias, write and read
  slots. Direction is input or output, state is electrical low or high, and null bias
  requests no pull. A slot can return `Unsupported`, and a bus-backed pin can block.
- `drivers/src/base/I2C_Device.zig:VTable` has optional vectored write, read and
  write-then-read slots with an unshifted seven-bit address. Erased scalar calls wrap
  each buffer in a one-slice vector. Standalone reads return counts. Fill every RX byte
  on success from write-then-read, which returns no count.
  Select an adapter whose slots, framing and address rules meet the consumer's needs.
  A combined slot can issue a STOP between phases, and vector splits can change framing.
- `drivers/src/base/StreamDevice.zig:VTable` has optional connect and disconnect hooks
  that default to no-ops. Pair successful selection with `disconnect`. Optional
  vectored reads and writes return byte counts and can be short. The std.Io
  adapters retain caller-provided buffers and cache the underlying error. Keep
  the enclosing adapter stationary while its embedded interface is borrowed.
  The reader treats a zero-byte read as end of stream.

## Design tables

### Implementations

Each dispatched interface has a local `TestDevice`. Port names refer to the `drivers.zig` files in Covers.

| Interface | Adapter | Operations provided |
| --- | --- | --- |
| BlockMemory | Local test double only | It exercises sector writes and byte-offset reads. |
| ClockDevice | ESP, RP2xxx, CH32V and nRF5x | They report boot time. CH32V time stays monotonic across reinitialization. TIM2 ticks between a system clock switch and `time.init()` are scaled at the old rate, which can skew elapsed time and deadlines spanning the switch. Let `port/wch/ch32v/src/hals/time.zig:tim2_handler` run during CH32V adapter sleeps and deadline polling. Keep `port/nordic/nrf5x/src/hal/time.zig:rtc_interrupt` servicing RTC0 compare and overflow events to extend the nRF5x counter. |
| ClockDevice | ATmega328P | Install `port/microchip/atmega/src/hals/atmega328p/time.zig:timer0_overflow` on `TIMER0_OVF`, call `hal.time.init()`, and leave interrupts enabled during sleeps. |
| ClockDevice | `port/stmicro/stm32/src/hals/common/systick_timer.zig:clock_device` | It rejects creation before SysTick initialization. Let `port/stmicro/stm32/src/hals/common/systick.zig:SysTick_handler` run during sleeps so the wrap count advances. |
| DatagramDevice | `I2C_DatagramDevice` on ESP, RP2xxx, nRF5x and STM32F103 | They bind an address, with combined transfer slots on RP2xxx and nRF5x. |
| DatagramDevice | `SPI_Device` on ESP, RP2xxx and nRF5x, `SPI_DatagramDevice` on ATmega328P and CH32V | They provide selection and transfer, with combined transfer slots on ESP, ATmega328P and CH32V. |
| Digital_IO | `GPIO_Device` on ESP, RP2xxx, CH32V and ATmega328P, plus `port/stmicro/stm32/src/hals/common/pins_v2.zig:Digital_IO_Pin` | These adapt concrete GPIO pins. |
| Digital_IO | `drivers/src/io_expander/pcf8574.zig:PCF8574.digital_IO` | Pins support read and write but return `Unsupported` for direction and bias. |
| I2C_Device | ESP and nRF5x `I2C_Device` | The combined slot uses a repeated START under one deadline. ESP starts with a write address even for an empty write, and nRF5x rejects either empty phase. |
| I2C_Device | RP2xxx `I2C_Device` | The combined slot shares a deadline and requires `port/raspberrypi/rp2xxx/src/hal/i2c.zig:Config`'s `repeated_start` for a restart, which enables `IC_RESTART_EN` by default. |
| I2C_Device | CH32V and STM32F103 `I2C_Device` | The combined slot uses separate write and read transactions with a fresh timeout for each. |
| I2C_Device | `port/stmicro/stm32/src/hals/common/i2c_v2.zig:I2C_Device` | Standalone vectors use one transaction per chunk. Supply matching vector counts for combined calls and keep each chunk length representable in `u8`. |
| I2C_Device | `port/nxp/mcx/src/mcxn947/hal/flexcomm/LP_I2C.zig:LP_I2C.i2c_device` | It submits the combined write and read in one transfer. Limit the total across all RX chunks to `get_fifo_sizes().tx * 256` bytes. |
| I2C_Device | `examples/nordic/nrf5x/src/selftest/sense.zig:ImuBus` | It stages one chunk per direction in DMA storage and has no standalone read slot. |
| StreamDevice | `port/espressif/esp/src/hal/uart.zig:Stream` | UART uses an optional per-call deadline, and a successful write enqueues bytes whose final stop bit can be awaited with `port/espressif/esp/src/hal/uart.zig:UART.flush_blocking`. |

Only the datagram test double supplies full duplex. Use DMA-accessible RAM for nRF5x SPI
slices, which the blocking slots pass directly to EasyDMA. CH32V SPI creates deadlines
per phase and DMA chunk. With DMA configured, CH32V I²C uses a transaction and timeout
per chunk even when polling. Limit CH32V SPI and I²C DMA chunks to 65,535 bytes so the
count fits `CNTR.NDT` in the port's register definitions.

### Consumer calls

| Interface | Consumer | Calls and obligations |
| --- | --- | --- |
| BlockMemory | Local test only | It enables writes, checks overrun and reads by byte offset. |
| ClockDevice | A4988, DRV8825 and ULN2003 | They read time and delay between steps. |
| ClockDevice | nRF24L01 and WS2812 | They use sleeps and poll deadlines for sends or the spacing between writes. |
| ClockDevice | DS18B20, ICM_20948, MPU_6050, MLX90640 and TLV493D | They use sleep to sequence wire operations or device commands. |
| DatagramDevice | SSD1306, SH1106, ST77xx, SharpMemory LCD and WS2812 | They bracket display or color writes with selection. |
| DatagramDevice | MPU_6050 and nRF24L01 | They select the bus for register writes and combined command/read calls. |
| DatagramDevice | PCA9685 | It reads and writes an already usable link, with no selection calls. |
| Digital_IO | DebouncedButton, RotaryEncoder and KeyboardMatrix | They configure direction and bias and sample inputs. The matrix also drives columns. |
| Digital_IO | SSD1306, SH1106, ST77xx, SharpMemory LCD and HD44780 | They drive control pins or the parallel data bus. SharpMemory's display-enable pin is optional. |
| Digital_IO | DS18B20, A4988, DRV8825, ULN2003, nRF24L01 and CYW43_Bus | DS18B20 switches its wire between input and output, and the others drive step, CE or power pins. |
| Digital_IO | `port/stmicro/stm32/src/hals/common/spi_v2.zig:SPI` | Software NSS borrows a pin handle, configures it as an output with null bias, and drives it low during transfer and high on return. |
| I2C_Device | AHT30, PCF8574, AS5600 and TMP117 | They use separate writes and reads. |
| I2C_Device | HTS221, ICM_20948, LSM6DS3TR_C and MLX90640 | They require the combined slot for register reads and also use standalone writes. |
| I2C_Device | TLV493D | It uses vectored I/O and writes a general call when reset is enabled. |
| I2C_Device | `examples/nxp/mcx/src/lp_i2c.zig:main` | It calls standalone write, read and combined transfer. |
| DateTime | `examples/raspberrypi/rp2xxx/src/rp2350_only/always_on_timer.zig:main` | It converts epoch milliseconds and formats them with `to_rfc_7231`. |
| StreamDevice | Local test only | It connects and calls read and write, while the std.Io adapters have no in-tree consumer. |

## Prior art

- `port/raspberrypi/rp2xxx/src/hal/drivers.zig:I2C_Device` stores its timeout policy in a borrowed adapter.
- `drivers/src/wireless/nrf24l01.zig:NRF24L01_Generic` defers disconnect around an SPI command/read.

## Shared patterns

- [Interrupt handling and ISR routing](interrupts.md) covers handoff inside an adapter.
- [Network and lwIP](network.md) covers the Ethernet link vtable.

## Evidence

`zig build test` in `drivers/` runs the following host tests through `drivers/src/root.zig`.

- Block size and enable gates use "TestDevice" in `drivers/src/base/BlockMemory.zig`.
- Deadline checks and widened ms conversion use "TestDevice" and "sleep_ms" in `drivers/src/base/ClockDevice.zig`.
- Selection, short buffer prefix and vectored writes use "TestDevice" in `drivers/src/base/DatagramDevice.zig`.
  Full-duplex lengths and slot absence use "transceive", "transceive fails if the reply doesn't fill the buffer"
  and "transceive is unsupported without transceivev_fn" in that file.
- nRF24L01 command/read, CE and send polling use "read_register sends R_REGISTER and reads one byte",
  "send loads the payload, pulses CE and waits for TX_DS" and "send flushes the payload and fails on timeout"
  in `drivers/src/wireless/nrf24l01.zig`.
- Epoch and timezone conversion, formatting and boundaries use "DateTime-Conversion", "TimeZone-Compare",
  "DateTime to string", "Boundary Conditions - Year", "Boundary Conditions - Feb/Mar - Non-Leap Year"
  and "Boundary Conditions - Feb/Mar - Leap Year" in `drivers/src/base/DateTime.zig`.
- Direction and levels use "TestDevice" in `drivers/src/base/Digital_IO.zig`. Input consumers use
  "DebouncedButton" in `drivers/src/input/debounced_button.zig`, "RotaryEncoder" in
  `drivers/src/input/rotary_encoder.zig` and "KeyboardMatrix" in `drivers/src/input/keyboard_matrix.zig`.
- Address classes, byte counts and vectors use "Address.check_reserved returns correct error types"
  and "TestDevice" in `drivers/src/base/I2C_Device.zig`. Combined register reads use
  "LSM6DS3TR-C register commands and signed axis order" in `drivers/src/sensor/LSM6DS3TR_C.zig`
  and "read_byte" in `drivers/src/sensor/ICM_20948.zig`.
- Stream selection, short reads and vectored writes use "TestDevice" in `drivers/src/base/StreamDevice.zig`.
- The HAL check "repeated_start" in `examples/espressif/esp/src/selftest_i2c.zig` ran on Super Mini ESP32-C6 with
  a Pico 2 W peer. Build with `-Dexample=selftest_i2c`. [I²C peer self-test](../../port/espressif/esp/README.md#i2c-master-peer-self-test)
- The direct HAL checks "timing_115200" and "timing_1000000" in `examples/espressif/esp/src/selftest_uart.zig`
  ran on ESP32-C3, Super Mini ESP32-C6 and XIAO ESP32-C6. Build with `-Dexample=selftest_uart`.
  [Driver evidence](../../port/espressif/esp/README.md#drivers)
- No host test verifies hardware framing or timing, adapter and DMA lifetimes, erase
  side effects, the clock polling fallback, port GPIO bias or std.Io edge cases.

## Open questions

- `drivers/src/base/BlockMemory.zig:write` can erase a sector before discovering the write slot is absent. ([#75](https://github.com/valthon/microzig/issues/75))
- `drivers/src/base/BlockMemory.zig:TestDevice.read` checks the write-enable flag despite having a separate read flag. ([#75](https://github.com/valthon/microzig/issues/75))
- `port/microchip/atmega/src/hals/atmega328p/drivers.zig:SPI_DatagramDevice` waits without a timeout.
- `drivers/src/base/ClockDevice.zig:Timeout.diff` can underflow if called after the deadline. ([#75](https://github.com/valthon/microzig/issues/75))
- `port/wch/ch32v/src/hals/time.zig:get_time_since_boot` can read a torn `u64` on RV32 when the TIM2 interrupt increments it across a low-word rollover. ([#78](https://github.com/valthon/microzig/issues/78))
- `port/stmicro/stm32/src/hals/common/systick.zig:get_time_since_boot` can go backwards when it reads a reloaded counter before the pending SysTick interrupt advances the wrap count. ([#77](https://github.com/valthon/microzig/issues/77))
- `drivers/src/base/DateTime.zig:from_timestamp` can underflow on the final day of a leap year and overflow its 12-bit year counter on large timestamps. ([#75](https://github.com/valthon/microzig/issues/75))
- `drivers/src/base/DateTime.zig:offset` casts a negative offset to an unsigned addend even when it passes the underflow check. ([#75](https://github.com/valthon/microzig/issues/75))
- `drivers/src/base/DatagramDevice.zig:TestDevice.writev_then_readv` discards a short read count and can report success with unfilled RX bytes. ([#75](https://github.com/valthon/microzig/issues/75))
- `drivers/src/base/I2C_Device.zig:TestDevice.writev_then_readv` discards a short read count and can report success with unfilled RX bytes. ([#75](https://github.com/valthon/microzig/issues/75))
- `port/raspberrypi/rp2xxx/src/hal/drivers.zig:I2C_DatagramDevice.writev_then_readv_fn` maps `NoData` on an empty write phase to success without filling a nonempty RX buffer. ([#79](https://github.com/valthon/microzig/issues/79))
- `port/nordic/nrf5x/src/hal/drivers.zig:I2C_DatagramDevice.writev_then_readv_fn` maps `NoData` on an empty write phase to success without filling a nonempty RX buffer. ([#76](https://github.com/valthon/microzig/issues/76))
- `drivers/src/io_expander/pca9685.zig:PCA9685.read_register` ignores the byte count and can return an unfilled byte. ([#75](https://github.com/valthon/microzig/issues/75))
- `port/wch/ch32v/src/hals/gpio.zig:Pin.set_pull` can put an output into floating input when bias is disabled. ([#78](https://github.com/valthon/microzig/issues/78))
- `drivers/src/io_expander/pcf8574.zig:PCF8574.read` tests the I²C byte count against its pin mask instead of the received byte. ([#75](https://github.com/valthon/microzig/issues/75))
- `port/nordic/nrf5x/src/hal/drivers.zig:I2C_DatagramDevice.writev_then_readv` discards the configured timeout. ([#76](https://github.com/valthon/microzig/issues/76))
- `port/espressif/esp/src/hal/spi.zig:SPI.wait_for_transfer_blocking` has no software deadline.
- `port/raspberrypi/rp2xxx/src/hal/spi.zig:SPI.writev_blocking` and `SPI.readv_blocking` wait without software deadlines.
- `port/nordic/nrf5x/src/hal/drivers.zig:SPI_Device` passes null timeouts through its erased slots. ([#76](https://github.com/valthon/microzig/issues/76))
- `port/nordic/nrf5x/src/hal/drivers.zig:SPI_Device` uses incompatible HAL signatures in its concrete read/write helpers. ([#76](https://github.com/valthon/microzig/issues/76))
- `port/nordic/nrf5x/src/hal/spim.zig:SPIM.inner_tx_rx` can slice past an exhausted direction on a later DMA chunk, including when a one-way transfer spans multiple chunks. ([#76](https://github.com/valthon/microzig/issues/76))
- `port/nordic/nrf5x/src/hal/spim.zig:SPIM.inner_tx_rx_chunk` can return `Timeout` after starting DMA without stopping it or confirming completion, so the buffers can still be in use. ([#76](https://github.com/valthon/microzig/issues/76))
- `port/nordic/nrf5x/src/hal/i2cdma.zig:I2C.wait` requests STOP on timeout and returns before waiting for STOPPED, so the DMA buffers may still be in use. ([#76](https://github.com/valthon/microzig/issues/76))
- `port/raspberrypi/rp2xxx/src/hal/drivers.zig:SPI_Device.readv` takes read-only chunks where the HAL needs writable chunks. ([#79](https://github.com/valthon/microzig/issues/79))
- `port/wch/ch32v/src/hals/spi.zig:SPI.write_dma` waits for DMA without a deadline and uses an incrementing RX slice over a one-byte dummy, which can overwrite adjacent stack bytes. ([#78](https://github.com/valthon/microzig/issues/78))
- `port/wch/ch32v/src/hals/spi.zig:SPI.read_dma` waits for DMA without a deadline and uses an incrementing TX slice over a one-byte dummy, which can transmit adjacent stack bytes. ([#78](https://github.com/valthon/microzig/issues/78))
- `port/wch/ch32v/src/hals/i2c.zig:I2C.write_dma` and `I2C.read_dma` also wait for DMA completion without a deadline. ([#78](https://github.com/valthon/microzig/issues/78))
- `port/wch/ch32v/src/hals/dma.zig:Channel.setup_transfer` writes the count without checking that it fits `CNTR.NDT`, so an oversized DMA slice can be only partly transferred. ([#78](https://github.com/valthon/microzig/issues/78))
- MCX has no software deadline for TX space, STOP polling or RX data in `port/nxp/mcx/src/mcxn947/hal/flexcomm/LP_I2C.zig:LP_I2C.wait_for_tx_space`, `LP_I2C.send_stop_blocking` and `LP_I2C.readv_blocking`.
- `port/nxp/mcx/src/mcxn947/hal/flexcomm/LP_I2C.zig:LP_I2C.send_stop_blocking` can return on `TDF` before `SDF` is set, so both `send_blocking` and `transfer_blocking` can succeed with the bus still occupied. ([#79](https://github.com/valthon/microzig/issues/79))
- `port/nxp/mcx/src/mcxn947/hal/flexcomm/LP_I2C.zig:LP_I2C.i2c_device` converts the instance index to a non-null pointer, so instance zero violates the pointer type's invariant. ([#79](https://github.com/valthon/microzig/issues/79))
- `port/nxp/mcx/src/mcxn947/hal/flexcomm/LP_I2C.zig:readv` builds a write message and returns the requested size. ([#79](https://github.com/valthon/microzig/issues/79))
- `port/stmicro/stm32/src/hals/STM32F103/i2c.zig:I2C.readv_blocking` clears ACK at each chunk's end and can terminate a vectored read before later chunks are filled. ([#77](https://github.com/valthon/microzig/issues/77))
- `port/stmicro/stm32/src/hals/STM32F103/drivers.zig:I2C_Device.write_then_read` calls a missing HAL method on the concrete scalar path. ([#77](https://github.com/valthon/microzig/issues/77))
- `port/nordic/nrf5x/src/hal/drivers.zig:I2C_Device.write_then_read` calls a missing non-DMA HAL method on the concrete scalar path. ([#76](https://github.com/valthon/microzig/issues/76))
- `port/stmicro/stm32/src/hals/common/i2c_v2.zig:I2C_Device.writev_then_readv_fn` pairs chunks by index, so a shorter RX vector can be indexed past its end and extra RX chunks are left untouched. ([#77](https://github.com/valthon/microzig/issues/77))
- `port/stmicro/stm32/src/hals/common/i2c_v2.zig:I2C.read_blocking` and `I2C.write_blocking_intern` poll flags without a software deadline. ([#77](https://github.com/valthon/microzig/issues/77))
- `port/stmicro/stm32/src/hals/common/i2c_v2.zig:I2C_Device.writev_fn` rejects reserved addresses including TLV493D's general call.
- `drivers/src/base/StreamDevice.zig:Writer.drain` can write new chunks while earlier buffered bytes remain after a short write. ([#75](https://github.com/valthon/microzig/issues/75))
