// Writes the idf_state_*.bin three-page partitions with ESP-IDF's own,
// unmodified NVS Storage/PageManager/Page code compiled for the host: flash
// states an interrupted ESP-IDF write leaves, each saved as the reset left it
// and, as *_loaded.bin, once a fresh ESP-IDF Storage::init has loaded it.
// The generator checks what ESP-IDF reads from each.
//   torn_entry      a u32's entry written, the bitmap not yet marking it: an
//                   entry marked empty that is not blank, at the first free one
//   torn_string     a string's header written and marked written, its payload
//                   written but still marked empty
//   full_partial    torn_string with its page then marked full (the state word
//                   written here, not by ESP-IDF): a full page holding an item
//                   whose payload is not marked written
//   legacy_blob     a version 1 blob (type 0x41) written with Page::writeItem
//                   between two keys, on an active page and on a full one
//   legacy_blob[_full]_rewritten, _rewriting
//                   Storage::writeItem of a new blob under its key: the result
//                   (version 2, the old item erased and purged), and the flash
//                   once the new index was marked written
//   legacy_blob_erased
//                   Storage::eraseItem of its key
//   legacy_and_index[_erased]
//                   legacy_blob_full_rewriting with another key written after
//                   the index, so that both versions stay; then one erase
//   legacy_and_broken_index
//                   legacy_and_index with the index's chunk erased: ESP-IDF's
//                   load erases the incomplete index and reads the version 1 blob
//   index_then_legacy
//                   a version 2 blob, then a version 1 blob of its key written
//                   with Page::writeItem after it on the active page: ESP-IDF's
//                   load erases the index as an earlier item of the key, and
//                   its chunk as an orphan, and reads the version 1 blob
//   legacy_complete_and_broken_index, legacy_two_broken_indexes,
//   legacy_overlapping_indexes, legacy_broken_then_empty_index,
//   legacy_shared_start
//                   legacy_blob with blob items of its key written with
//                   Page::writeItem, as damage or another writer leaves them,
//                   one index after the version 1 blob before its page is
//                   marked full, one on the next page, then another key (on
//                   an active page the load would erase the earlier of two
//                   indexes): an index with no chunk, then a complete one; two
//                   indexes with no chunk; chunk 0 and its index, then chunk 1
//                   and an index of chunks 0 and 1, which
//                   Storage::eraseMismatchedBlobIndexes credits both to the
//                   first index whose range holds them; chunks 0 and 1 and an
//                   index of chunk 0, then an empty blob's index from 0; chunk
//                   0 and its index, then an index from 0 with no chunk. The
//                   first and fourth also get *_v1_erased.bin: the loaded
//                   partition with the version 1 item then erased by
//                   Page::eraseItem.
//   two_indexes     a blob rewritten across pages, reset after the new index
//                   and before the old one was erased, then another key written
//                   with Page::writeItem so that the new index is no longer the
//                   last item: both indexes stay, on different pages
//   tail_chunk      a 320-byte blob rewritten with 640 bytes on the same page,
//                   reset before the new index: ESP-IDF reads neither version
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
#include <optional>
#include <string>
#include <vector>
#include "nvs_storage.hpp"

static void require(bool ok, const char* what) {
    if (!ok) {
        std::fprintf(stderr, "ESP-IDF state fixture generation failed: %s\n", what);
        std::exit(1);
    }
}

static constexpr size_t page_count = 3;
using Image = std::array<uint8_t, page_count * nvs::Page::SEC_SIZE>;

struct Write {
    Image after;
    size_t offset;
    std::vector<uint8_t> data;
};

class MemoryPartition : public nvs::Partition {
public:
    Image bytes;
    bool recording = false;
    std::vector<Write> history;

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
        if (recording) history.push_back({bytes, offset, std::vector<uint8_t>(src, src + size)});
        return ESP_OK;
    }
    esp_err_t write(size_t offset, const void* src, size_t size) override { return write_raw(offset, src, size); }
    esp_err_t erase_range(size_t offset, size_t size) override {
        require(offset <= bytes.size() && size <= bytes.size() - offset, "erase bounds");
        std::memset(bytes.data() + offset, 0xff, size);
        if (recording) history.push_back({bytes, offset, {}});
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
    for (size_t i = 0; i < size; ++i) data[i] = static_cast<uint8_t>(i * 7 + seed);
    return data;
}

static bool is_entry(const Write& write, nvs::ItemType type, const char* key) {
    return write.data.size() == nvs::Page::ENTRY_SIZE && write.data[1] == static_cast<uint8_t>(type) &&
           std::strcmp(reinterpret_cast<const char*>(write.data.data() + 8), key) == 0;
}

// The position in the history of the first entry write of `type` for `key`.
static size_t entry_write(const MemoryPartition& partition, nvs::ItemType type, const char* key) {
    for (size_t i = 0; i < partition.history.size(); ++i) {
        if (is_entry(partition.history[i], type, key)) return i;
    }
    require(false, "entry write found");
    std::abort();
}

// What a fresh ESP-IDF Storage reads for namespace "fixture": a u32 key, or a
// string or blob, or nothing.
struct Reading {
    std::optional<uint32_t> u32;
    std::optional<std::vector<uint8_t>> bytes;
};

static Reading read(nvs::Storage& storage, nvs::ItemType type, const char* key) {
    Reading reading;
    uint8_t ns = 0;
    require(storage.createOrOpenNamespace("fixture", false, ns) == ESP_OK, "namespace");
    if (type == nvs::ItemType::U32) {
        uint32_t value = 0;
        const auto err = storage.readItem(ns, key, value);
        require(err == ESP_OK || err == ESP_ERR_NVS_NOT_FOUND, "read u32");
        if (err == ESP_OK) reading.u32 = value;
        return reading;
    }
    size_t size = 0;
    auto err = storage.getItemDataSize(ns, type, key, size);
    require(err == ESP_OK || err == ESP_ERR_NVS_NOT_FOUND, "read size");
    if (err != ESP_OK) return reading;
    std::vector<uint8_t> data(size);
    require(storage.readItem(ns, type, key, data.data(), size) == ESP_OK, "read data");
    reading.bytes = std::move(data);
    return reading;
}

// Boots ESP-IDF on `image` and returns the flash its load left.
static Image boot(const Image& image) {
    MemoryPartition partition;
    partition.bytes = image;
    nvs::Storage storage(&partition);
    require(storage.init(0, page_count) == ESP_OK, "init");
    return partition.bytes;
}

static void expect_u32(const Image& image, const char* key, std::optional<uint32_t> value, const char* what) {
    MemoryPartition partition;
    partition.bytes = image;
    nvs::Storage storage(&partition);
    require(storage.init(0, page_count) == ESP_OK, what);
    require(read(storage, nvs::ItemType::U32, key).u32 == value, what);
}

static void expect_bytes(const Image& image, nvs::ItemType type, const char* key,
                         const std::optional<std::vector<uint8_t>>& value, const char* what) {
    MemoryPartition partition;
    partition.bytes = image;
    nvs::Storage storage(&partition);
    require(storage.init(0, page_count) == ESP_OK, what);
    require(read(storage, type, key).bytes == value, what);
}

// Saves `image` and what ESP-IDF's load makes of it, which must hold still.
static Image save_pair(const Image& image, const std::string& dir, const std::string& name) {
    save(image, dir + "/idf_state_" + name + ".bin");
    const Image loaded = boot(image);
    require(boot(loaded) == loaded, "a second load changes nothing");
    save(loaded, dir + "/idf_state_" + name + "_loaded.bin");
    return loaded;
}

static void mark_full(Image& image, size_t page) {
    // PageState::FULL; the header CRC does not cover the state word.
    const uint32_t full = 0xfffffffc;
    uint8_t bytes[4];
    std::memcpy(bytes, &full, 4);
    for (size_t i = 0; i < 4; ++i) image[page * nvs::Page::SEC_SIZE + i] &= bytes[i];
}

// Boots ESP-IDF's Storage on `image`, as `partition`, and opens "fixture".
static uint8_t open_fixture(MemoryPartition& partition, nvs::Storage& storage, const Image& image) {
    partition.bytes = image;
    require(storage.init(0, page_count) == ESP_OK, "init");
    uint8_t ns = 0;
    require(storage.createOrOpenNamespace("fixture", false, ns) == ESP_OK, "namespace");
    return ns;
}

static void expect_legacy_neighbours(const Image& image, const char* what) {
    expect_u32(image, "before", 0x0badcafe, what);
    expect_u32(image, "after", 0xfeedf00d, what);
}

// From the version 1 blob `image` (`name`): ESP-IDF's Storage writes a new
// blob under its key (format version 2, then the old item erased and
// purged), and erases the key. Saves the result, and the flash once the new
// index was marked written, before the old item's erase.
static void write_over_legacy(const Image& image, const std::string& dir, const std::string& name, bool full) {
    const bool purge = nvs::Page::DEFAULT_PURGE_AFTER_ERASE;
    const auto second = pattern(150, 0x21);
    MemoryPartition partition;
    nvs::Storage storage(&partition);
    const uint8_t ns = open_fixture(partition, storage, image);
    partition.recording = true;
    require(storage.writeItem(ns, nvs::ItemType::BLOB, "legacy", second.data(), second.size(), purge) == ESP_OK, "rewrite legacy");
    const size_t index = entry_write(partition, nvs::ItemType::BLOB_IDX, "legacy");
    const auto& entry = partition.history[index];
    require((entry.offset >= nvs::Page::SEC_SIZE) == full, "a full page's blob goes to the next page");
    require(partition.history.size() > index + 2 && partition.history[index + 1].data.size() == 4, "index state write");
    const Image rewriting = partition.history[index + 1].after;
    expect_bytes(rewriting, nvs::ItemType::BLOB, "legacy", second, "legacy rewriting: the new blob read");
    expect_legacy_neighbours(rewriting, "legacy rewriting: neighbours read");
    const Image loaded = save_pair(rewriting, dir, name + "_rewriting");
    require(loaded != rewriting, "legacy rewriting: the load erases the old item");
    expect_bytes(partition.bytes, nvs::ItemType::BLOB, "legacy", second, "legacy rewritten: the new blob read");
    expect_legacy_neighbours(partition.bytes, "legacy rewritten: neighbours read");
    save_pair(partition.bytes, dir, name + "_rewritten");

    if (full) {
        // As two_indexes: another key after the new index, so that the load
        // does not erase the old item. Both versions stay.
        MemoryPartition composed;
        composed.bytes = rewriting;
        nvs::Page page;
        require(page.load(&composed, entry.offset / nvs::Page::SEC_SIZE) == ESP_OK, "load active page");
        require(page.writeItem<uint32_t>(ns, "later", 7) == ESP_OK, "later");
        expect_bytes(composed.bytes, nvs::ItemType::BLOB, "legacy", second, "legacy and index: the index read");
        expect_u32(composed.bytes, "later", 7, "legacy and index: later read");
        save_pair(composed.bytes, dir, "legacy_and_index");
        // Storage::eraseItem finds the version 1 item first, on the older
        // page, and erases only it.
        MemoryPartition erasing;
        nvs::Storage erase_storage(&erasing);
        const uint8_t erase_ns = open_fixture(erasing, erase_storage, composed.bytes);
        require(erase_storage.eraseItem(erase_ns, nvs::ItemType::ANY, "legacy", purge) == ESP_OK, "erase one version");
        expect_bytes(erasing.bytes, nvs::ItemType::BLOB, "legacy", second, "legacy and index erased once: the index read");
        save_pair(erasing.bytes, dir, "legacy_and_index_erased");
        // The index's chunk lost, as damage would lose it: ESP-IDF's load
        // erases the incomplete index (Storage::eraseMismatchedBlobIndexes)
        // and reads the version 1 blob.
        MemoryPartition damaged;
        damaged.bytes = composed.bytes;
        nvs::Page chunk_page;
        require(chunk_page.load(&damaged, entry.offset / nvs::Page::SEC_SIZE) == ESP_OK, "load the chunk's page");
        require(chunk_page.eraseItem(ns, nvs::ItemType::BLOB_DATA, "legacy", purge, 0) == ESP_OK, "erase the chunk");
        expect_bytes(damaged.bytes, nvs::ItemType::BLOB, "legacy", pattern(100, 3), "broken index: the version 1 blob read");
        expect_legacy_neighbours(damaged.bytes, "broken index: neighbours read");
        const Image repaired = save_pair(damaged.bytes, dir, "legacy_and_broken_index");
        require(repaired != damaged.bytes, "broken index: the load erases the index");
    } else {
        MemoryPartition erasing;
        nvs::Storage erase_storage(&erasing);
        const uint8_t erase_ns = open_fixture(erasing, erase_storage, image);
        require(erase_storage.eraseItem(erase_ns, nvs::ItemType::ANY, "legacy", purge) == ESP_OK, "erase legacy");
        expect_bytes(erasing.bytes, nvs::ItemType::BLOB, "legacy", std::nullopt, "legacy erased: nothing read");
        expect_legacy_neighbours(erasing.bytes, "legacy erased: neighbours read");
        save_pair(erasing.bytes, dir, name + "_erased");
    }
}

// A blob index of "legacy", written with Page::writeItem as Storage writes one.
static void write_index(nvs::Page& page, uint8_t ns, uint32_t size, uint8_t count, uint8_t start) {
    nvs::Item item;
    std::fill_n(item.data, sizeof(item.data), 0xff);
    item.blobIndex.dataSize = size;
    item.blobIndex.chunkCount = count;
    item.blobIndex.chunkStart = static_cast<nvs::VerOffset>(start);
    require(page.writeItem(ns, nvs::ItemType::BLOB_IDX, "legacy", item.data, sizeof(item.data)) == ESP_OK, "blob index");
}

static void write_chunk(nvs::Page& page, uint8_t ns, const std::vector<uint8_t>& data, uint8_t chunk) {
    require(page.writeItem(ns, nvs::ItemType::BLOB_DATA, "legacy", data.data(), data.size(), chunk) == ESP_OK, "blob chunk");
}

// Whether `page` of `image` holds an item of "legacy" of `type`. A search by
// key would stop at the key's first item of another type.
static bool holds(const Image& image, size_t page, nvs::ItemType type) {
    MemoryPartition partition;
    partition.bytes = image;
    nvs::Page loaded;
    require(loaded.load(&partition, page) == ESP_OK, "load page");
    size_t index = 0;
    nvs::Item item;
    while (loaded.findItem(nvs::Page::NS_ANY, type, nullptr, index, item) == ESP_OK) {
        if (std::strcmp(item.key, "legacy") == 0) return true;
        index += item.span;
    }
    return false;
}

// legacy_blob (`image`, its active page 0 holding namespace 1 and the
// version 1 blob) with `older` written on page 0 by Page::writeItem, the page
// then marked full, and `newer` written on page 1, then another key. Saves it
// and its loaded partition; returns the latter.
template <typename Older, typename Newer>
static Image legacy_with_indexes(const Image& image, const std::string& dir, const std::string& name,
                                 const std::optional<std::vector<uint8_t>>& read_after_load, Older older, Newer newer) {
    MemoryPartition composed;
    composed.bytes = image;
    {
        nvs::Page page;
        require(page.load(&composed, 0) == ESP_OK, "load the version 1 blob's page");
        older(page);
    }
    mark_full(composed.bytes, 0);
    nvs::Page page;
    require(page.load(&composed, 1) == ESP_OK, "load blank page");
    require(page.setSeqNumber(1) == ESP_OK, "sequence number");
    newer(page);
    // Not an index last: PageManager::load would erase the version 1 item.
    require(page.writeItem<uint32_t>(1, "later", 7) == ESP_OK, "later");
    expect_bytes(composed.bytes, nvs::ItemType::BLOB, "legacy", read_after_load, name.c_str());
    expect_legacy_neighbours(composed.bytes, name.c_str());
    expect_u32(composed.bytes, "later", 7, name.c_str());
    return save_pair(composed.bytes, dir, name);
}

// `loaded` with its version 1 item erased and purged by Page::eraseItem.
static void save_v1_erased(const Image& loaded, const std::string& dir, const std::string& name) {
    MemoryPartition partition;
    partition.bytes = loaded;
    nvs::Page page;
    require(page.load(&partition, 0) == ESP_OK, "load the version 1 blob's page");
    require(page.eraseItem(1, nvs::ItemType::BLOB, "legacy", nvs::Page::DEFAULT_PURGE_AFTER_ERASE) == ESP_OK, "erase the version 1 blob");
    save(partition.bytes, dir + "/idf_state_" + name + "_v1_erased.bin");
}

// Version 1 blob states with blob indexes ESP-IDF never writes beside one.
static void legacy_index_states(const Image& image, const std::string& dir) {
    const auto first = pattern(100, 3);
    const auto second = pattern(150, 0x21);
    const auto at_0 = pattern(60, 0x40);
    const auto at_1 = pattern(40, 0x60);

    // Storage::eraseMismatchedBlobIndexes erases the index with no chunk and
    // keeps the complete one, which is read; the version 1 item stays.
    Image loaded = legacy_with_indexes(image, dir, "legacy_complete_and_broken_index", second, [&](nvs::Page& page) {
        write_index(page, 1, 10, 1, 0x80);
    }, [&](nvs::Page& page) {
        write_chunk(page, 1, second, 0);
        write_index(page, 1, second.size(), 1, 0);
    });
    require(holds(loaded, 0, nvs::ItemType::BLOB), "complete and broken: the version 1 item kept");
    require(!holds(loaded, 0, nvs::ItemType::BLOB_IDX), "complete and broken: the index with no chunk erased");
    require(holds(loaded, 1, nvs::ItemType::BLOB_IDX), "complete and broken: the complete index kept");
    save_v1_erased(loaded, dir, "legacy_complete_and_broken_index");

    // Both indexes erased, the version 1 blob read.
    loaded = legacy_with_indexes(image, dir, "legacy_two_broken_indexes", first, [&](nvs::Page& page) {
        write_index(page, 1, 10, 1, 0x80);
    }, [&](nvs::Page& page) {
        write_index(page, 1, 20, 1, 0);
    });
    require(!holds(loaded, 0, nvs::ItemType::BLOB_IDX) && !holds(loaded, 1, nvs::ItemType::BLOB_IDX), "two broken: both indexes erased");

    // Chunk 0 and an index of it, then chunk 1 and an index of chunks 0
    // and 1. Both chunks are credited to the first index in the list: it
    // has two chunks, the second none. Both erased (by their first chunk
    // number, 0 for both), then the chunks as orphans, and the version 1
    // blob read.
    loaded = legacy_with_indexes(image, dir, "legacy_overlapping_indexes", first, [&](nvs::Page& page) {
        write_chunk(page, 1, at_0, 0);
        write_index(page, 1, at_0.size(), 1, 0);
    }, [&](nvs::Page& page) {
        write_chunk(page, 1, at_1, 1);
        write_index(page, 1, at_0.size() + at_1.size(), 2, 0);
    });
    for (size_t p = 0; p < 2; ++p) {
        require(!holds(loaded, p, nvs::ItemType::BLOB_IDX) && !holds(loaded, p, nvs::ItemType::BLOB_DATA), "overlapping: indexes and chunks erased");
    }

    // Chunks 0 and 1, and an index of 10 bytes in one chunk from 0, then an
    // empty blob's index from 0 (no chunk). Both chunks are credited to the
    // first, which is erased; the second, credited none, is complete, and
    // read. Credited the chunks without the first, it would not be.
    loaded = legacy_with_indexes(image, dir, "legacy_broken_then_empty_index", std::vector<uint8_t>{}, [&](nvs::Page& page) {
        write_chunk(page, 1, pattern(10, 0x70), 0);
        write_chunk(page, 1, pattern(5, 0x78), 1);
        write_index(page, 1, 10, 1, 0);
    }, [&](nvs::Page& page) {
        write_index(page, 1, 0, 0, 0);
    });
    require(!holds(loaded, 0, nvs::ItemType::BLOB_IDX) && !holds(loaded, 0, nvs::ItemType::BLOB_DATA) &&
                holds(loaded, 1, nvs::ItemType::BLOB_IDX) && holds(loaded, 0, nvs::ItemType::BLOB),
            "broken then empty: the first index and the chunks erased, the empty one and the version 1 item kept");
    save_v1_erased(loaded, dir, "legacy_broken_then_empty_index");

    // Chunk 0 and its complete index, then an index from 0 with no chunk of
    // its own. The second is incomplete, and ESP-IDF erases the first index
    // from chunk 0 it finds, the complete one; the chunk stays, credited to
    // it, and the second index is read.
    loaded = legacy_with_indexes(image, dir, "legacy_shared_start", at_0, [&](nvs::Page& page) {
        write_chunk(page, 1, at_0, 0);
        write_index(page, 1, at_0.size(), 1, 0);
    }, [&](nvs::Page& page) {
        write_index(page, 1, at_0.size(), 1, 0);
    });
    require(!holds(loaded, 0, nvs::ItemType::BLOB_IDX) && holds(loaded, 0, nvs::ItemType::BLOB_DATA) &&
                holds(loaded, 1, nvs::ItemType::BLOB_IDX) && holds(loaded, 0, nvs::ItemType::BLOB),
            "shared start: the complete index erased, the chunk, the other index and the version 1 item kept");
}

int main(int argc, char** argv) {
    require(argc == 2, "usage: state_fixture <output-dir>");
    const std::string dir = argv[1];
    static_assert(nvs::Page::DEFAULT_PURGE_AFTER_ERASE, "fixtures require the IDF purge default");
    const bool purge = nvs::Page::DEFAULT_PURGE_AFTER_ERASE;

    {
        MemoryPartition partition;
        nvs::Storage storage(&partition);
        require(storage.init(0, page_count) == ESP_OK, "init blank");
        uint8_t ns = 0;
        require(storage.createOrOpenNamespace("fixture", true, ns) == ESP_OK, "namespace");
        require(storage.writeItem(ns, "before", uint32_t(0x0badcafe), purge) == ESP_OK, "before");
        partition.recording = true;
        require(storage.writeItem(ns, "torn", uint32_t(0x5eed), purge) == ESP_OK, "torn");
        // Page::writeEntry: the entry, then its bitmap word.
        const auto& torn = partition.history[entry_write(partition, nvs::ItemType::U32, "torn")].after;
        expect_u32(torn, "torn", std::nullopt, "torn entry not read");
        expect_u32(torn, "before", 0x0badcafe, "torn entry: before read");
        const Image loaded = save_pair(torn, dir, "torn_entry");
        require(loaded != torn, "torn entry erased");

        partition.history.clear();
        const std::string text(100, 't');
        require(storage.writeItem(ns, nvs::ItemType::SZ, "text", text.c_str(), text.size() + 1, purge) == ESP_OK, "text");
        // Page::writeItem: the header entry and its state, then the payload's
        // whole entries (Page::writeEntryData: data, then their states).
        const size_t header = entry_write(partition, nvs::ItemType::SZ, "text");
        require(partition.history.size() > header + 2 && partition.history[header + 2].data.size() == 3 * nvs::Page::ENTRY_SIZE,
                "payload write follows the header and its state");
        const Image string = partition.history[header + 2].after;
        expect_bytes(string, nvs::ItemType::SZ, "text", std::nullopt, "torn string not read");
        expect_u32(string, "before", 0x0badcafe, "torn string: before read");
        save_pair(string, dir, "torn_string");

        Image full = string;
        mark_full(full, 0);
        expect_bytes(full, nvs::ItemType::SZ, "text", std::nullopt, "partial item on a full page not read");
        expect_u32(full, "before", 0x0badcafe, "full partial: before read");
        save_pair(full, dir, "full_partial");
    }

    {
        // Format version 1 blobs are single items of type 0x41, which only
        // Page::writeItem still writes; ESP-IDF v6 Storage still reads them.
        MemoryPartition partition;
        nvs::Page page;
        require(page.load(&partition, 0) == ESP_OK, "load blank page");
        require(page.setSeqNumber(0) == ESP_OK, "sequence number");
        require(page.writeItem<uint8_t>(0, "fixture", 1) == ESP_OK, "namespace entry");
        require(page.writeItem<uint32_t>(1, "before", 0x0badcafe) == ESP_OK, "before");
        const auto blob = pattern(100, 3);
        require(page.writeItem(1, nvs::ItemType::BLOB, "legacy", blob.data(), blob.size()) == ESP_OK, "legacy blob");
        require(page.writeItem<uint32_t>(1, "after", 0xfeedf00d) == ESP_OK, "after");
        for (const bool full : {false, true}) {
            Image image = partition.bytes;
            if (full) mark_full(image, 0);
            expect_bytes(image, nvs::ItemType::BLOB, "legacy", blob, "legacy blob read");
            expect_u32(image, "after", 0xfeedf00d, "legacy: after read");
            expect_u32(image, "before", 0x0badcafe, "legacy: before read");
            const std::string name = full ? "legacy_blob_full" : "legacy_blob";
            save_pair(image, dir, name);
            write_over_legacy(image, dir, name, full);
            if (!full) legacy_index_states(image, dir);
        }
    }

    {
        // A version 1 blob after a version 2 blob of its key on the active
        // page, where no ESP-IDF since v3.3 puts one.
        MemoryPartition partition;
        nvs::Storage storage(&partition);
        require(storage.init(0, page_count) == ESP_OK, "init blank");
        uint8_t ns = 0;
        require(storage.createOrOpenNamespace("fixture", true, ns) == ESP_OK, "namespace");
        require(storage.writeItem(ns, "before", uint32_t(0x0badcafe), purge) == ESP_OK, "before");
        const auto second = pattern(150, 0x21);
        require(storage.writeItem(ns, nvs::ItemType::BLOB, "legacy", second.data(), second.size(), purge) == ESP_OK, "version 2 blob");
        MemoryPartition composed;
        composed.bytes = partition.bytes;
        nvs::Page page;
        require(page.load(&composed, 0) == ESP_OK, "load active page");
        const auto first = pattern(100, 3);
        require(page.writeItem(ns, nvs::ItemType::BLOB, "legacy", first.data(), first.size()) == ESP_OK, "version 1 blob");
        require(page.writeItem<uint32_t>(ns, "after", 0xfeedf00d) == ESP_OK, "after");
        expect_bytes(composed.bytes, nvs::ItemType::BLOB, "legacy", first, "index then legacy: the version 1 blob read");
        expect_legacy_neighbours(composed.bytes, "index then legacy: neighbours read");
        const Image loaded = save_pair(composed.bytes, dir, "index_then_legacy");
        require(loaded != composed.bytes, "index then legacy: the load erases the index");
    }

    {
        MemoryPartition partition;
        nvs::Storage storage(&partition);
        require(storage.init(0, page_count) == ESP_OK, "init blank");
        uint8_t ns = 0;
        require(storage.createOrOpenNamespace("fixture", true, ns) == ESP_OK, "namespace");
        const auto first = pattern(100, 0);
        const auto second = pattern(200, 0x5a);
        require(storage.writeItem(ns, nvs::ItemType::BLOB, "big", first.data(), first.size(), purge) == ESP_OK, "blob");
        // Fill the first page: namespace, chunk (5 entries), index, fillers.
        for (int i = 0; i < 119; ++i) {
            const std::string key = "f" + std::to_string(i);
            require(storage.writeItem(ns, key.c_str(), uint32_t(i), purge) == ESP_OK, "filler");
        }
        partition.recording = true;
        require(storage.writeItem(ns, nvs::ItemType::BLOB, "big", second.data(), second.size(), purge) == ESP_OK, "rewrite");
        // The new index's entry, then its bitmap word.
        const size_t index = entry_write(partition, nvs::ItemType::BLOB_IDX, "big");
        const auto& entry = partition.history[index];
        require(entry.offset >= nvs::Page::SEC_SIZE, "the new index is on a later page");
        require(partition.history.size() > index + 1 && partition.history[index + 1].data.size() == 4, "index state write");
        // Write another key after it, so that PageManager::load's last-item
        // check does not erase the old index.
        MemoryPartition composed;
        composed.bytes = partition.history[index + 1].after;
        nvs::Page page;
        require(page.load(&composed, entry.offset / nvs::Page::SEC_SIZE) == ESP_OK, "load active page");
        require(page.writeItem<uint32_t>(ns, "later", 7) == ESP_OK, "later");
        // Storage::findItem returns the index on the first page of the list.
        expect_bytes(composed.bytes, nvs::ItemType::BLOB, "big", first, "two indexes: the older page's read");
        expect_u32(composed.bytes, "later", 7, "two indexes: later read");
        save_pair(composed.bytes, dir, "two_indexes");
    }

    {
        MemoryPartition partition;
        nvs::Storage storage(&partition);
        require(storage.init(0, page_count) == ESP_OK, "init blank");
        uint8_t ns = 0;
        require(storage.createOrOpenNamespace("fixture", true, ns) == ESP_OK, "namespace");
        require(storage.writeItem(ns, "before", uint32_t(0x0badcafe), purge) == ESP_OK, "before");
        const auto first = pattern(320, 0);
        const auto second = pattern(640, 0x5a);
        require(storage.writeItem(ns, nvs::ItemType::BLOB, "big", first.data(), first.size(), purge) == ESP_OK, "blob");
        partition.recording = true;
        require(storage.writeItem(ns, nvs::ItemType::BLOB, "big", second.data(), second.size(), purge) == ESP_OK, "rewrite");
        const size_t index = entry_write(partition, nvs::ItemType::BLOB_IDX, "big");
        require(index > 0 && partition.history[index].offset < nvs::Page::SEC_SIZE, "all on one page");
        const Image& cut = partition.history[index - 1].after;
        // Page::mLoadEntryTable's last-item check erases the old chunk: the
        // last item is the new chunk, and findItem matches any chunk index.
        expect_bytes(cut, nvs::ItemType::BLOB, "big", std::nullopt, "tail chunk: neither version read");
        expect_u32(cut, "before", 0x0badcafe, "tail chunk: before read");
        save_pair(cut, dir, "tail_chunk");
    }
    return 0;
}
