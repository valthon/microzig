#!/usr/bin/env python3
"""Link real ESP-IDF NVS code to write test fixtures; no Zig encoding is used here.

Usage: python3 <absolute-script-path> <absolute-esp-idf-checkout> [output-dir]
Input: idf.bin beside this script, produced by nvs_partition_gen.py.
Output (beside this script unless output-dir is given):
  purge_fixture.cpp: 12 idf_purged_*.bin erase+purge pages, 8 idf_erased_*.bin
  pages with the same erases unpurged, and 8 idf_corrupt_*.bin damaged-header
  pages before, during and after repair.
  blob_fixture.cpp: 5 idf_blob_*.bin five-page partitions holding a
  multi-page blob written, rewritten and erased, two of them interrupted.
  state_fixture.cpp: 21 idf_state_*.bin three-page partitions in states that
  interrupted ESP-IDF writes leave, that ESP-IDF's writes over a version 1
  blob leave, or that hold blob indexes beside one, each with the
  *_loaded.bin ESP-IDF's load makes of it, and two *_v1_erased.bin.
Only fixture generation needs C++/ESP-IDF; zig build test embeds the outputs.
"""
from pathlib import Path
import subprocess
import sys
import tempfile


def compile_idf_program(idf, build, source, with_storage, defines=()):
    """Compiles `source` into `build` with unmodified ESP-IDF NVS code: the
    Page code, and with `with_storage` also PageManager and Storage. Returns
    the executable's path."""
    # Host-only platform shims: no target sections or debug logging.
    # ESP_TEE_BUILD selects IDF's standard malloc/free allocator path.
    (build / "esp_attr.h").write_text("#pragma once\n#define IDF_DEPRECATED(message) __attribute__((deprecated(message)))\n")
    (build / "sdkconfig.h").write_text("#pragma once\n")
    (build / "esp_log.h").write_text("#pragma once\n#define ESP_LOGD(...) ((void)0)\n")
    components = idf / "components"
    nvs = components / "nvs_flash"
    includes = [build, nvs / "src", nvs / "include", nvs / "private_include",
                components / "esp_common/include", components / "esp_rom/include",
                components / "spi_flash/include"]
    sources = [nvs / "src/nvs_page.cpp", nvs / "src/nvs_types.cpp",
               nvs / "src/nvs_item_hash_list.cpp", components / "esp_rom/linux/esp_rom_crc.c"]
    if with_storage:
        sources += [nvs / "src/nvs_pagemanager.cpp", nvs / "src/nvs_storage.cpp"]
    exe = build / source.stem
    command = ["c++", "-std=c++17", "-DESP_TEE_BUILD=1"] + ["-D" + define for define in defines] + ["-o", str(exe)]
    command += ["-I" + str(path) for path in includes]
    command += [str(source)] + [str(path) for path in sources]
    subprocess.run(command, check=True)
    return exe


def main():
    if len(sys.argv) not in (2, 3):
        raise SystemExit(__doc__)
    idf = Path(sys.argv[1]).resolve(strict=True)
    here = Path(__file__).resolve().parent
    out = Path(sys.argv[2]).resolve(strict=True) if len(sys.argv) == 3 else here
    cache = here.parents[2] / ".zig-cache"
    cache.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="idf-nvs-", dir=cache) as temp:
        build = Path(temp)
        programs = [
            ("purge_fixture.cpp", False, [here / "idf.bin", out], []),
            ("blob_fixture.cpp", True, [out], []),
            # As on a target: two blob indexes of one key on different pages
            # trip the host-only Storage::debugCheck.
            ("state_fixture.cpp", True, [out], ["NO_DEBUG_STORAGE"]),
        ]
        for source, with_storage, args, defines in programs:
            exe = compile_idf_program(idf, build, here / source, with_storage, defines)
            subprocess.run([str(exe)] + [str(arg) for arg in args], check=True)
        print("Generated ESP-IDF NVS fixtures in " + str(out))


if __name__ == "__main__":
    main()
