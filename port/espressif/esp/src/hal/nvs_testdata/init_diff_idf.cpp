// Random foreign NVS states for init_diff_idf.py, and ESP-IDF's own boot of
// them: unmodified ESP-IDF Page code writes each state, and unmodified
// Storage, PageManager and Page code loads it and reads its blobs.
//
//   init_diff_idf generate <out> <seed> <count>
//     Writes <count> four-page partitions: on one to three used pages, the
//     newest active or full, blob chunks, blob indexes and version 1 blobs
//     of three keys ("legacy" and "other" in namespace "fixture", "legacy"
//     in namespace "second"), complete, short, overlapping or out of order,
//     some with a payload that fails its CRC, between other keys; in some,
//     a key "dup" whose newest item, an integer or a string, is the newest
//     page's last and has older items of its type or another. The pages
//     lie in any physical order, and in some partitions one is marked as
//     being freed. The same seed writes the same partitions.
//   init_diff_idf load <in> <out>
//     For each partition in <in>, two boots, the second on what the first
//     left: Storage::init, then each key's blob read four times, as
//     nvs_get_blob reads it. Writes a record of what each step left
//     (`Boot` below).
//
// Run by init_diff_idf.py; the zig build test gate does not run it.
#include <algorithm>
#include <array>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <random>
#include <string>
#include <utility>
#include <vector>
#include "nvs_storage.hpp"

static void require(bool ok, const char* what) {
    if (!ok) {
        std::fprintf(stderr, "init_diff_idf: %s\n", what);
        std::exit(1);
    }
}

static constexpr size_t page_count = 4;
using Image = std::array<uint8_t, page_count * nvs::Page::SEC_SIZE>;

class MemoryPartition : public nvs::Partition {
public:
    Image bytes;

    MemoryPartition() { bytes.fill(0xff); }
    const char* get_partition_name() override { return "init_diff"; }
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
        return ESP_OK;
    }
    esp_err_t write(size_t offset, const void* src, size_t size) override { return write_raw(offset, src, size); }
    esp_err_t erase_range(size_t offset, size_t size) override {
        require(offset <= bytes.size() && size <= bytes.size() - offset, "erase bounds");
        std::memset(bytes.data() + offset, 0xff, size);
        return ESP_OK;
    }
};

static std::vector<uint8_t> pattern(size_t size, uint8_t seed) {
    std::vector<uint8_t> data(size);
    for (size_t i = 0; i < size; ++i) data[i] = static_cast<uint8_t>(i * 7 + seed);
    return data;
}

// Marks a page full (PageState::FULL) or as being freed
// (PageState::FREEING); the header CRC does not cover the state word.
static void mark(Image& image, size_t page, nvs::Page::PageState state) {
    // A page without an item has no header yet.
    if (image[page * nvs::Page::SEC_SIZE] == 0xff) return;
    const uint32_t word = static_cast<uint32_t>(state);
    uint8_t bytes[4];
    std::memcpy(bytes, &word, 4);
    for (size_t i = 0; i < 4; ++i) image[page * nvs::Page::SEC_SIZE + i] &= bytes[i];
}

enum class Kind { chunk, index, legacy };

struct Entry {
    Kind kind;
    uint8_t ns;
    std::string key;
    uint8_t chunk;
    std::vector<uint8_t> data;
    uint32_t size;
    uint8_t count;
    uint8_t start;
    // The payload fails its CRC.
    bool damaged = false;
};

// The entries an item takes.
static size_t span(const Entry& entry) {
    return entry.kind == Kind::index ? 1 : 1 + (entry.data.size() + 31) / 32;
}

static bool put(nvs::Page& page, const Entry& entry) {
    switch (entry.kind) {
    case Kind::chunk:
        return page.writeItem(entry.ns, nvs::ItemType::BLOB_DATA, entry.key.c_str(), entry.data.data(), entry.data.size(), entry.chunk) == ESP_OK;
    case Kind::legacy:
        return page.writeItem(entry.ns, nvs::ItemType::BLOB, entry.key.c_str(), entry.data.data(), entry.data.size()) == ESP_OK;
    case Kind::index: {
        nvs::Item item;
        std::fill_n(item.data, sizeof(item.data), 0xff);
        item.blobIndex.dataSize = entry.size;
        item.blobIndex.chunkCount = entry.count;
        item.blobIndex.chunkStart = static_cast<nvs::VerOffset>(entry.start);
        return page.writeItem(entry.ns, nvs::ItemType::BLOB_IDX, entry.key.c_str(), item.data, sizeof(item.data)) == ESP_OK;
    }
    }
    return false;
}

class Random {
public:
    explicit Random(uint32_t seed) : rng(seed) {}
    uint32_t below(uint32_t n) { return rng() % n; }
    template <typename T> T pick(std::initializer_list<T> values) { return *(values.begin() + below(values.size())); }

private:
    std::mt19937 rng;
};

static Image generate(Random& random) {
    // Mostly states some ESP-IDF write could leave; then indexes without
    // their chunks or with more, stray chunks, indexes of either half from
    // any first chunk number, damaged payloads and shuffled order.
    struct Key {
        uint8_t ns;
        const char* key;
    };
    const Key keys[] = {{1, "legacy"}, {1, "other"}, {2, "legacy"}};
    const bool any_start = random.below(4) == 0;
    std::vector<Entry> entries;
    uint8_t seed = 0;
    const int groups = random.pick({1, 1, 2, 2, 2, 3, 3, 4});
    for (int g = 0; g < groups; ++g) {
        const Key key = keys[random.pick({0, 0, 0, 0, 0, 1, 2})];
        Entry index{Kind::index, key.ns, key.key, 0, {}, 0, 0, 0};
        index.start = any_start ? random.pick<uint8_t>({0, 0, 0, 0x80, 0x80, 0x80, 1, 0x81, 0x40, 0x7f}) : random.pick<uint8_t>({0, 0x80});
        index.count = random.pick<uint8_t>({0, 1, 1, 2, 2, 3});
        const int missing = (random.below(4) == 0 && index.count) ? int(random.below(index.count)) : -1;
        for (int k = 0; k < index.count; ++k) {
            const size_t size = random.pick<size_t>({10, 40, 60, 1, 33, 0});
            index.size += size;
            if (k == missing) continue;
            entries.push_back({Kind::chunk, key.ns, key.key, uint8_t(index.start + k), pattern(size, seed += 17), 0, 0, 0});
        }
        if (random.below(7) == 0) index.size += random.pick<uint32_t>({1, 10, 65536});
        if (random.below(7) == 0) index.count += 1;
        if (random.below(6) == 0) {
            const uint8_t chunk = random.pick<uint8_t>({0, 1, 2, 3, 0x7f, 0x80, 0x81, 0x82, 0xfe});
            entries.push_back({Kind::chunk, key.ns, key.key, chunk, pattern(random.pick<size_t>({10, 40}), seed += 17), 0, 0, 0});
        }
        entries.push_back(index);
    }
    const int swaps = random.pick({0, 0, 1, 2, 4, 8});
    for (int s = 0; s < swaps && entries.size() > 1; ++s) std::swap(entries[random.below(entries.size())], entries[random.below(entries.size())]);
    const int legacies = random.pick({1, 1, 1, 1, 1, 2, 2, 3, 0});
    for (int v = 0; v < legacies; ++v) {
        const Key key = keys[random.pick({0, 0, 0, 0, 1, 2})];
        const auto at = entries.begin() + random.below(entries.size() + 1);
        entries.insert(at, Entry{Kind::legacy, key.ns, key.key, 0xff, pattern(100 - 30 * v, 3 + 6 * v), 0, 0, 0});
    }
    if (random.below(4) == 0) {
        Entry& entry = entries[random.below(entries.size())];
        entry.damaged = entry.kind != Kind::index && !entry.data.empty();
    }
    // The used pages: all but the newest full, the newest active or, as
    // after a reset before the next page is activated, full too.
    const size_t used = random.pick<size_t>({1, 2, 2, 2, 3, 3});
    const bool newest_full = random.below(8) == 0;
    std::vector<size_t> cuts{0};
    for (size_t page = 1; page < used; ++page) cuts.push_back(random.below(4) == 0 ? (random.below(2) ? 0 : entries.size()) : random.below(entries.size() + 1));
    cuts.push_back(entries.size());
    std::sort(cuts.begin(), cuts.end());
    // Without it, the last item of the newest page may be a blob item.
    const bool later = random.below(4) != 0;
    // The key "dup", as a reset before the old item's erase leaves it: the
    // newest page's last item a u32 or a string, after an item of its
    // type on the oldest page (1, 3), of another type (2), or of its type
    // on the oldest page and the next (4).
    const int dup = used > 1 ? random.pick({0, 0, 0, 1, 2, 3, 4}) : 0;
    // Where each page lies, oldest first: sequence order is not physical
    // order once a reclaim has wrapped around the partition.
    size_t place[page_count];
    for (size_t i = 0; i < page_count; ++i) place[i] = i;
    for (size_t i = page_count - 1; i > 0; --i) std::swap(place[i], place[random.below(i + 1)]);
    // The page being freed, if any: a reset in a reclaim leaves one.
    const size_t freeing = random.below(6) == 0 ? random.below(used) : used;

    MemoryPartition partition;
    std::vector<size_t> damaged;
    for (size_t number = 0; number < used; ++number) {
        nvs::Page page;
        require(page.load(&partition, place[number]) == ESP_OK, "load page");
        require(page.setSeqNumber(number) == ESP_OK, "sequence page");
        size_t next = 0;
        if (number == 0) {
            require(page.writeItem<uint8_t>(0, "fixture", 1) == ESP_OK, "namespace fixture");
            require(page.writeItem<uint8_t>(0, "second", 2) == ESP_OK, "namespace second");
            require(page.writeItem<uint32_t>(1, "before", 0x0badcafe) == ESP_OK, "key before");
            next = 3;
        }
        for (size_t i = cuts[number]; i < cuts[number + 1]; ++i) {
            require(put(page, entries[i]), "entry");
            if (entries[i].damaged) damaged.push_back(place[number] * nvs::Page::SEC_SIZE + 64 + (next + 1) * 32);
            next += span(entries[i]);
        }
        if (number == 0) require(page.writeItem<uint32_t>(1, "after", 0xfeedf00d) == ESP_OK, "key after");
        if (number == used - 1 && later) require(page.writeItem<uint32_t>(1, "later", 7) == ESP_OK, "key later");
        const bool newest = number == used - 1;
        if (dup == 3) {
            if (number == 0 || newest) require(page.writeItem(1, nvs::ItemType::SZ, "dup", newest ? "new" : "old", 4) == ESP_OK, "dup string");
        } else if (dup == 2 && number == 0) {
            require(page.writeItem<uint8_t>(1, "dup", 1) == ESP_OK, "dup u8");
        } else if (dup != 0 && (number == 0 || newest || (dup == 4 && number == 1))) {
            require(page.writeItem<uint32_t>(1, "dup", number) == ESP_OK, "dup u32");
        }
    }
    for (size_t number = 0; number < used; ++number) {
        if (number + 1 < used || newest_full) mark(partition.bytes, place[number], nvs::Page::PageState::FULL);
    }
    if (freeing < used) mark(partition.bytes, place[freeing], nvs::Page::PageState::FREEING);
    for (const size_t at : damaged) partition.bytes[at] ^= 1;
    return partition.bytes;
}

// A read: u8 status (0 read, 1 not found, 2 failed, 3 type mismatch,
// 4 longer than the buffer), u32 length, the buffer.
struct Read {
    uint8_t status = 0;
    uint32_t len = 0;
    std::array<uint8_t, 256> data{};
};

// As nvs_get_blob (nvs_handle_simple.cpp, nvs_api.cpp): the size, then the
// item read with that size.
static Read read_blob(nvs::Storage& storage, uint8_t ns, const char* key) {
    Read read;
    size_t size = 0;
    esp_err_t err = storage.getItemDataSize(ns, nvs::ItemType::BLOB, key, size);
    if (err == ESP_OK && size > read.data.size()) {
        read.status = 4;
        return read;
    }
    if (err == ESP_OK) err = storage.readItem(ns, nvs::ItemType::BLOB, key, read.data.data(), size);
    if (err == ESP_OK) {
        read.len = size;
    } else {
        read.status = err == ESP_ERR_NVS_NOT_FOUND ? 1 : err == ESP_ERR_NVS_TYPE_MISMATCH ? 3 : 2;
        read.data.fill(0);
    }
    return read;
}

static void write_bytes(FILE* out, const void* bytes, size_t size) {
    require(std::fwrite(bytes, 1, size, out) == size, "write record");
}

// A boot, as both halves record it: u8 0 if init succeeded, else 9; the
// partition as init left it; each of the three keys read in turn, four
// times (all zeros after a failed init); the partition as the reads left
// it.
static void boot(MemoryPartition& partition, FILE* out) {
    nvs::Storage storage(&partition);
    const uint8_t failed = storage.init(0, page_count) == ESP_OK ? 0 : 9;
    write_bytes(out, &failed, 1);
    write_bytes(out, partition.bytes.data(), partition.bytes.size());
    for (int round = 0; round < 4; ++round) {
        for (const auto& [ns, key] : {std::pair<uint8_t, const char*>{1, "legacy"}, {1, "other"}, {2, "legacy"}}) {
            Read read;
            if (!failed) read = read_blob(storage, ns, key);
            write_bytes(out, &read.status, 1);
            write_bytes(out, &read.len, 4);
            write_bytes(out, read.data.data(), read.data.size());
        }
    }
    write_bytes(out, partition.bytes.data(), partition.bytes.size());
}

int main(int argc, char** argv) {
    if (argc == 5 && std::string(argv[1]) == "generate") {
        Random random(static_cast<uint32_t>(std::strtoul(argv[3], nullptr, 10)));
        const long count = std::strtol(argv[4], nullptr, 10);
        FILE* out = std::fopen(argv[2], "wb");
        require(out != nullptr, "open output");
        for (long c = 0; c < count; ++c) {
            const Image image = generate(random);
            require(std::fwrite(image.data(), 1, image.size(), out) == image.size(), "write partition");
        }
        require(std::fclose(out) == 0, "close output");
        return 0;
    }
    if (argc == 4 && std::string(argv[1]) == "load") {
        FILE* in = std::fopen(argv[2], "rb");
        FILE* out = std::fopen(argv[3], "wb");
        require(in != nullptr && out != nullptr, "open files");
        Image image;
        while (std::fread(image.data(), 1, image.size(), in) == image.size()) {
            MemoryPartition partition;
            partition.bytes = image;
            boot(partition, out);
            boot(partition, out);
        }
        require(std::feof(in) && std::fclose(in) == 0 && std::fclose(out) == 0, "read input");
        return 0;
    }
    std::fprintf(stderr, "usage: init_diff_idf generate <out> <seed> <count> | load <in> <out>\n");
    return 2;
}
