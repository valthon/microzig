// Writes the idf_purged_*.bin fixtures with ESP-IDF's own, unmodified NVS
// Page/Item/HashList code (nvs_page.cpp, nvs_types.cpp, nvs_item_hash_list.cpp)
// compiled for the host. Starting from idf.bin it writes longer items and tail
// keys, erases them with Page::eraseItem and DEFAULT_PURGE_AFTER_ERASE, and saves
// each page active and after Page::markFull. The *_partial_* pages are the flash
// contents at the moment purgeEntryRange had zeroed only the item's first entry.
// The idf_erased_* pages are the same erases without purging, as an
// NVS_READWRITE handle makes them (nvs_handle_simple.cpp passes its
// mPurgeAfterErase, true only for NVS_READWRITE_PURGE).
//
// The idf_corrupt_* pages start from the same page with the string's header
// damaged after it was written (a CRC bit, or its span), then let Page::load
// repair it: *_crc_* and *_span_* are the damaged pages, *_repairing_* the flash
// at the moment that repair had erased and zeroed only the header, leaving its
// payload written, and *_repaired_* the page once Page::load returned.
//
// Regenerate (needs a host C++17 compiler; ESP-IDF is only read):
//   python3 <this directory>/generate_fixtures.py <esp-idf checkout>
// The committed fixtures came from ESP-IDF v6.0.2 (7101770dc6db2667b3c477cc31365dd1acd6db4e)
// and g++ 15.2.0; regenerating with them reproduces every file byte for byte.
#include <algorithm>
#include <array>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <limits>
#include "nvs_page.hpp"

static void require(bool ok) {
    if (!ok) {
        std::fputs("ESP-IDF purge fixture generation failed\n", stderr);
        std::exit(1);
    }
}

class MemoryPartition : public nvs::Partition {
public:
    std::array<uint8_t, 3 * nvs::Page::SEC_SIZE> bytes{};
    std::array<uint8_t, 3 * nvs::Page::SEC_SIZE> first_purge{};
    size_t capture_offset = std::numeric_limits<size_t>::max();
    bool captured = false;
    const char* get_partition_name() override { return "fixture"; }
    uint32_t get_address() override { return 0; }
    uint32_t get_size() override { return bytes.size(); }
    bool get_readonly() override { return false; }
    esp_err_t read_raw(size_t offset, void* dest, size_t size) override {
        require(offset <= bytes.size() && size <= bytes.size() - offset);
        std::memcpy(dest, bytes.data() + offset, size);
        return ESP_OK;
    }
    esp_err_t read(size_t offset, void* dest, size_t size) override { return read_raw(offset, dest, size); }
    esp_err_t write_raw(size_t offset, const void* source, size_t size) override {
        require(offset <= bytes.size() && size <= bytes.size() - offset);
        const auto* src = static_cast<const uint8_t*>(source);
        for (size_t i = 0; i < size; ++i) bytes[offset + i] &= src[i];
        if (offset == capture_offset && size == nvs::Page::ENTRY_SIZE &&
            std::all_of(src, src + size, [](uint8_t byte) { return byte == 0; })) {
            first_purge = bytes;
            captured = true;
        }
        return ESP_OK;
    }
    esp_err_t write(size_t offset, const void* src, size_t size) override { return write_raw(offset, src, size); }
    esp_err_t erase_range(size_t offset, size_t size) override {
        require(offset <= bytes.size() && size <= bytes.size() - offset);
        std::memset(bytes.data() + offset, 0xff, size);
        return ESP_OK;
    }
    void save(const std::string& name) {
        auto* file = std::fopen(name.c_str(), "wb");
        require(file != nullptr);
        const auto written = std::fwrite(bytes.data(), 1, nvs::Page::SEC_SIZE, file);
        const auto closed = std::fclose(file);
        require(written == nvs::Page::SEC_SIZE && closed == 0);
    }
};

static constexpr size_t long_text_entry = 64 + 8 * nvs::Page::ENTRY_SIZE;

static void check_repaired(MemoryPartition& image) {
    nvs::Page page;
    require(page.load(&image, 0) == ESP_OK);
    uint32_t tail = 0;
    char text[101];
    require(page.readItem(1, "tail", tail) == ESP_OK && tail == 0x12345678);
    require(page.readItem(1, nvs::ItemType::SZ, "long_text", text, sizeof(text)) == ESP_ERR_NVS_NOT_FOUND);
}

// Damages the long_text header of `base` after the fact, as a bit flip would,
// and saves the page before, during and after ESP-IDF's Page::load repairs it.
static void write_corrupt_fixtures(const MemoryPartition& base, const std::string& dir) {
    const char* states[] = {"active", "full"};
    for (const char* state : states) {
        MemoryPartition intact = base;
        if (std::string(state) == "full") {
            nvs::Page page;
            require(page.load(&intact, 0) == ESP_OK);
            require(page.markFull() == ESP_OK);
        }
        require(intact.bytes[long_text_entry + 1] == static_cast<uint8_t>(nvs::ItemType::SZ));
        require(intact.bytes[long_text_entry + 2] == 5);
        MemoryPartition repairing[2];
        MemoryPartition repaired[2];
        const char* damages[] = {"crc", "span"};
        for (size_t i = 0; i < 2; ++i) {
            MemoryPartition image = intact;
            if (i == 0) {
                image.bytes[long_text_entry + 4] ^= 0x01;
            } else {
                image.bytes[long_text_entry + 2] = 4;
            }
            image.save(dir + "/idf_corrupt_" + damages[i] + "_" + state + ".bin");
            image.capture_offset = long_text_entry;
            check_repaired(image);
            require(image.captured);
            repairing[i].bytes = image.first_purge;
            repaired[i].bytes = image.bytes;
        }
        // Once the header is zeroed, how it was damaged no longer shows.
        require(repairing[0].bytes == repairing[1].bytes && repaired[0].bytes == repaired[1].bytes);
        // ESP-IDF finishes an interrupted repair the same way.
        MemoryPartition resumed = repairing[0];
        check_repaired(resumed);
        require(resumed.bytes == repaired[0].bytes);
        repairing[0].save(dir + "/idf_corrupt_repairing_" + state + ".bin");
        repaired[0].save(dir + "/idf_corrupt_repaired_" + state + ".bin");
    }
}

int main(int argc, char** argv) {
    require(argc == 3);
    MemoryPartition base;
    auto* file = std::fopen(argv[1], "rb");
    require(file != nullptr);
    const auto read = std::fread(base.bytes.data(), 1, base.bytes.size(), file);
    const auto closed = std::fclose(file);
    require(read == base.bytes.size() && closed == 0);
    const std::string text(100, 'x');
    std::array<uint8_t, 96> blob;
    for (size_t i = 0; i < blob.size(); ++i) blob[i] = static_cast<uint8_t>(i * 7);
    // A header-shaped payload could otherwise swallow the live tail keys
    // when a purge destroys the real enclosing header first.
    nvs::Item fake(1, nvs::ItemType::SZ, 6, "fake");
    fake.varLength.dataSize = 160;
    fake.crc32 = fake.calculateCrc32();
    std::memcpy(blob.data(), &fake, sizeof(fake));
    {
        nvs::Page page;
        require(page.load(&base, 0) == ESP_OK);
        require(page.writeItem(1, nvs::ItemType::SZ, "long_text", text.c_str(), text.size() + 1) == ESP_OK);
        require(page.writeItem(1, nvs::ItemType::BLOB_DATA, "long_blob", blob.data(), blob.size(), 0) == ESP_OK);
        nvs::Item index;
        std::memset(&index, 0xff, sizeof(index));
        index.blobIndex.dataSize = blob.size();
        index.blobIndex.chunkCount = 1;
        index.blobIndex.chunkStart = nvs::VerOffset::VER_0_OFFSET;
        require(page.writeItem(1, nvs::ItemType::BLOB_IDX, "long_blob", index.data, sizeof(index.data)) == ESP_OK);
        const uint32_t tail = 0x12345678;
        require(page.writeItem(1, "tail", tail) == ESP_OK);
        const char after[] = "after purged items";
        require(page.writeItem(1, nvs::ItemType::SZ, "tail_text", after, sizeof(after)) == ESP_OK);
    }
    static_assert(nvs::Page::DEFAULT_PURGE_AFTER_ERASE, "fixtures require the IDF purge default");
    write_corrupt_fixtures(base, argv[2]);
    const int masks[] = {1, 2, 4, 7};
    const char* names[] = {"integer", "string", "blob", "all"};
    for (size_t i = 0; i < 4; ++i) for (const bool purge : {nvs::Page::DEFAULT_PURGE_AFTER_ERASE, false}) {
        MemoryPartition image = base;
        nvs::Page page;
        require(page.load(&image, 0) == ESP_OK);
        if (purge && masks[i] == 2) image.capture_offset = 64 + 8 * nvs::Page::ENTRY_SIZE;
        if (purge && masks[i] == 4) image.capture_offset = 64 + 13 * nvs::Page::ENTRY_SIZE;
        if (masks[i] & 1) require(page.eraseItem(1, nvs::ItemType::U64, "unsigned", purge) == ESP_OK);
        if (masks[i] & 2) require(page.eraseItem(1, nvs::ItemType::SZ, "long_text", purge) == ESP_OK);
        if (masks[i] & 4) {
            require(page.eraseItem(1, nvs::ItemType::BLOB_IDX, "long_blob", purge) == ESP_OK);
            require(page.eraseItem(1, nvs::ItemType::BLOB_DATA, "long_blob", purge, 0) == ESP_OK);
        }
        int32_t signed_value = 0;
        uint32_t tail = 0;
        require(page.readItem(1, "signed", signed_value) == ESP_OK && signed_value == -123456);
        require(page.readItem(1, "tail", tail) == ESP_OK && tail == 0x12345678);
        const std::string prefix = std::string(argv[2]) + (purge ? "/idf_purged_" : "/idf_erased_") + names[i];
        image.save(prefix + "_active.bin");
        require(page.markFull() == ESP_OK);
        image.save(prefix + "_full.bin");
        if (purge && (masks[i] == 2 || masks[i] == 4)) {
            require(image.captured);
            MemoryPartition partial;
            partial.bytes = image.first_purge;
            nvs::Page check;
            require(check.load(&partial, 0) == ESP_OK);
            require(check.readItem(1, "tail", tail) == ESP_OK && tail == 0x12345678);
            partial.save(prefix + "_partial_active.bin");
            require(check.markFull() == ESP_OK);
            partial.save(prefix + "_partial_full.bin");
        }
    }
}
