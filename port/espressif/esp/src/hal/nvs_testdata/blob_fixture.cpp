// Writes the idf_blob_*.bin partitions with ESP-IDF's own, unmodified NVS
// Storage/PageManager/Page code (nvs_storage.cpp, nvs_pagemanager.cpp,
// nvs_page.cpp, ...) compiled for the host. On a blank five-page partition it
// stores a key, a 9000-byte blob (format version 2: BLOB_DATA chunks on three
// pages and a BLOB_IDX) and another key, then rewrites the blob with 6000 bytes
// (the new version's chunks start at 128), then erases it with
// DEFAULT_PURGE_AFTER_ERASE. Saved partitions:
//   idf_blob_written.bin    the 9000-byte blob stored
//   idf_blob_rewriting.bin  the rewrite's chunks written, its index not yet
//   idf_blob_rewritten.bin  the rewrite done, the old version erased and purged
//   idf_blob_erasing.bin    the erase had erased and zeroed only the index
//   idf_blob_erased.bin     the erase done
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
#include <vector>
#include "nvs_storage.hpp"

static void require(bool ok, const char* what) {
    if (!ok) {
        std::fprintf(stderr, "ESP-IDF blob fixture generation failed: %s\n", what);
        std::exit(1);
    }
}

static constexpr size_t page_count = 5;
using Image = std::array<uint8_t, page_count * nvs::Page::SEC_SIZE>;

class MemoryPartition : public nvs::Partition {
public:
    Image bytes;
    // Every write and erase while recording, as (flash after it, the write).
    bool recording = false;
    std::vector<std::pair<Image, std::vector<uint8_t>>> history;

    MemoryPartition() { bytes.fill(0xff); }
    const char* get_partition_name() override { return "fixture"; }
    uint32_t get_address() override { return 0; }
    uint32_t get_size() override { return bytes.size(); }
    bool get_readonly() override { return false; }
    esp_err_t read_raw(size_t offset, void* dest, size_t size) override {
        require(offset <= bytes.size() && size <= bytes.size() - offset, "read bounds");
        std::memcpy(dest, bytes.data() + offset, size);
        return ESP_OK;
    }
    esp_err_t read(size_t offset, void* dest, size_t size) override { return read_raw(offset, dest, size); }
    esp_err_t write_raw(size_t offset, const void* source, size_t size) override {
        require(offset <= bytes.size() && size <= bytes.size() - offset, "write bounds");
        const auto* src = static_cast<const uint8_t*>(source);
        for (size_t i = 0; i < size; ++i) bytes[offset + i] &= src[i];
        if (recording) history.emplace_back(bytes, std::vector<uint8_t>(src, src + size));
        return ESP_OK;
    }
    esp_err_t write(size_t offset, const void* src, size_t size) override { return write_raw(offset, src, size); }
    esp_err_t erase_range(size_t offset, size_t size) override {
        require(offset <= bytes.size() && size <= bytes.size() - offset, "erase bounds");
        std::memset(bytes.data() + offset, 0xff, size);
        if (recording) history.emplace_back(bytes, std::vector<uint8_t>());
        return ESP_OK;
    }
};

static void save(const Image& image, const std::string& name) {
    auto* file = std::fopen(name.c_str(), "wb");
    require(file != nullptr, "open output");
    const auto written = std::fwrite(image.data(), 1, image.size(), file);
    const auto closed = std::fclose(file);
    require(written == image.size() && closed == 0, "write output");
}

static std::vector<uint8_t> pattern(size_t size, uint8_t seed) {
    std::vector<uint8_t> data(size);
    for (size_t i = 0; i < size; ++i) data[i] = static_cast<uint8_t>(i * 7 + (i >> 8) + seed);
    return data;
}

// Opens `image` with a fresh Storage, as at boot, and checks what it reads.
static void check(const Image& image, const std::vector<uint8_t>* blob, const char* what) {
    MemoryPartition partition;
    partition.bytes = image;
    nvs::Storage storage(&partition);
    require(storage.init(0, page_count) == ESP_OK, what);
    uint8_t ns = 0;
    require(storage.createOrOpenNamespace("fixture", false, ns) == ESP_OK, what);
    uint32_t value = 0;
    require(storage.readItem(ns, "before", value) == ESP_OK && value == 0x0badcafe, what);
    require(storage.readItem(ns, "after", value) == ESP_OK && value == 0xfeedf00d, what);
    size_t size = 0;
    const auto found = storage.getItemDataSize(ns, nvs::ItemType::BLOB, "big", size);
    if (blob == nullptr) {
        require(found == ESP_ERR_NVS_NOT_FOUND, what);
        return;
    }
    require(found == ESP_OK && size == blob->size(), what);
    std::vector<uint8_t> read(size);
    require(storage.readItem(ns, nvs::ItemType::BLOB, "big", read.data(), size) == ESP_OK && read == *blob, what);
}

// The flash before the first write of a 32-byte entry of type `type` for "big".
static const Image& before_entry(const MemoryPartition& partition, nvs::ItemType type) {
    for (size_t i = 0; i < partition.history.size(); ++i) {
        const auto& written = partition.history[i].second;
        if (written.size() == nvs::Page::ENTRY_SIZE && written[1] == static_cast<uint8_t>(type) &&
            std::strcmp(reinterpret_cast<const char*>(written.data() + 8), "big") == 0) {
            require(i > 0, "entry write has a predecessor");
            return partition.history[i - 1].first;
        }
    }
    require(false, "entry write found");
    std::abort();
}

// The flash after the first purge: the first 32-byte write of zeros.
static const Image& after_first_purge(const MemoryPartition& partition) {
    for (const auto& [image, written] : partition.history) {
        if (written.size() == nvs::Page::ENTRY_SIZE &&
            std::all_of(written.begin(), written.end(), [](uint8_t byte) { return byte == 0; })) return image;
    }
    require(false, "purge write found");
    std::abort();
}

int main(int argc, char** argv) {
    require(argc == 2, "usage: blob_fixture <output-dir>");
    const std::string dir = argv[1];
    static_assert(nvs::Page::DEFAULT_PURGE_AFTER_ERASE, "fixtures require the IDF purge default");
    const bool purge = nvs::Page::DEFAULT_PURGE_AFTER_ERASE;
    const auto first = pattern(9000, 0);
    const auto second = pattern(6000, 0x5a);

    MemoryPartition partition;
    nvs::Storage storage(&partition);
    require(storage.init(0, page_count) == ESP_OK, "init blank");
    uint8_t ns = 0;
    require(storage.createOrOpenNamespace("fixture", true, ns) == ESP_OK, "namespace");
    require(storage.writeItem(ns, "before", uint32_t(0x0badcafe), purge) == ESP_OK, "before");
    require(storage.writeItem(ns, nvs::ItemType::BLOB, "big", first.data(), first.size(), purge) == ESP_OK, "blob");
    require(storage.writeItem(ns, "after", uint32_t(0xfeedf00d), purge) == ESP_OK, "after");
    check(partition.bytes, &first, "written");
    save(partition.bytes, dir + "/idf_blob_written.bin");

    partition.recording = true;
    require(storage.writeItem(ns, nvs::ItemType::BLOB, "big", second.data(), second.size(), purge) == ESP_OK, "rewrite");
    const Image rewriting = before_entry(partition, nvs::ItemType::BLOB_IDX);
    check(rewriting, &first, "rewriting");
    save(rewriting, dir + "/idf_blob_rewriting.bin");
    check(partition.bytes, &second, "rewritten");
    save(partition.bytes, dir + "/idf_blob_rewritten.bin");

    partition.history.clear();
    require(storage.eraseItem(ns, nvs::ItemType::ANY, "big", purge) == ESP_OK, "erase");
    // Storage::eraseMultiPageBlob erases and zeroes the index first; the
    // chunks follow, orphaned.
    const Image& erasing = after_first_purge(partition);
    check(erasing, nullptr, "erasing");
    save(erasing, dir + "/idf_blob_erasing.bin");
    check(partition.bytes, nullptr, "erased");
    save(partition.bytes, dir + "/idf_blob_erased.bin");
    return 0;
}
