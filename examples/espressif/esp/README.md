# Examples for the Port `espressif-esp`

- [Blinky](src/blinky.zig) on [ESP32-C3-32S-Kit](https://www.waveshare.com/wiki/ESP-C3-32S-Kit)
  Showcases how to do a simple RGB cycling.

- [XIAO blinky](src/xiao_esp32_c6_blinky.zig) on a
  [Seeed Studio XIAO ESP32C6](https://wiki.seeedstudio.com/xiao_esp32c6_getting_started/)
  Blinks the user led through the board definition and logs over the USB-C connector.

Most examples build for both the esp32c3 and the esp32c6; the `chips` field of each entry in
[build.zig](build.zig) lists its targets. `rtos`, `tcp_server`, `i2c_display_ssd1306_c3_oled_042`,
`selftest_ledc_fade` and the `selftest_sleep` stages are esp32c3 only, and `selftest_c6_core` and
`selftest_c6_ledc` are esp32c6 only. The pin numbers in the examples are the ones of the C3 kit, so
pick the pads of your own board. On a Seeed XIAO ESP32C6 the user led sits on GPIO15 and the usb
serial/jtag port is the USB-C connector itself.

## How to flash the image onto the device

- esp image

```sh
esptool.py --chip esp32c3 --baud 460800 --before default_reset --after hard_reset write_flash \
        0x0 bootloader.bin 0x8000 partition_table.bin 0x10000 zig-out/firmware/esp32_c3_blinky.bin
```
NOTE: you have to provide a [bootloader](https://docs.espressif.com/projects/esp-idf/en/stable/esp32c3/api-guides/bootloader.html) and a [partition table](https://docs.espressif.com/projects/esp-idf/en/stable/esp32c3/api-guides/partition-tables.html).

- [direct boot image](https://github.com/espressif/esp32c3-direct-boot-example)

```sh
esptool.py --chip esp32c3 --baud 460800 --before default_reset --after hard_reset write_flash 0x0 \
    zig-out/firmware/esp32_c3_direct_boot_blinky.bin
```

- flashless image

```sh
esptool.py --chip esp32c3 --baud 460800 --no-stub load_ram zig-out/firmware/esp32_c3_flashless_blinky.bin
```

For the esp32c6, and for the XIAO ESP32C6 board example, the commands are the same with
`--chip esp32c6` and the matching firmware name, for example:

```sh
esptool.py --chip esp32c6 --baud 460800 --before default_reset --after hard_reset write_flash 0x0 \
    zig-out/firmware/esp32_c6_direct_boot_blinky.bin
```
