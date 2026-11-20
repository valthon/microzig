// Reads every flash image nvs_crash_test.zig dumped (zig build test
// -Dnvs-crash-dump=<file>) with ESP-IDF's own, unmodified NVS Storage code
// compiled for the host, as ESP-IDF would at boot, and checks that it reads the
// values the dump allows: for an image as a crash in this store's writer left
// it, every committed key and the in-flight key's old or new value; for the
// same image once this store had recovered it, exactly what this store read.
// It then reopens ESP-IDF on what its own load left, writes a key, reopens
// again, and checks that the values it chose stay as they were.
//
// Run by crosscheck_idf.py; the zig build test gate does not run it.
#include <array>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <optional>
#include <string>
#include <vector>
#include "nvs_storage.hpp"

static constexpr size_t page_count = 3;
static constexpr size_t image_size = page_count * nvs::Page::SEC_SIZE;
using Image = std::array<uint8_t, image_size>;

class MemoryPartition : public nvs::Partition {
public:
    Image bytes;
    const char* get_partition_name() override { return "crosscheck"; }
    uint32_t get_address() override { return 0; }
    uint32_t get_size() override { return bytes.size(); }
    bool get_readonly() override { return false; }
    esp_err_t read_raw(size_t offset, void* dest, size_t size) override {
        if (offset > bytes.size() || size > bytes.size() - offset) return ESP_ERR_INVALID_ARG;
        std::memcpy(dest, bytes.data() + offset, size);
        return ESP_OK;
    }
    esp_err_t read(size_t offset, void* dest, size_t size) override { return read_raw(offset, dest, size); }
    esp_err_t write_raw(size_t offset, const void* source, size_t size) override {
        if (offset > bytes.size() || size > bytes.size() - offset) return ESP_ERR_INVALID_ARG;
        const auto* src = static_cast<const uint8_t*>(source);
        for (size_t i = 0; i < size; ++i) bytes[offset + i] &= src[i];
        return ESP_OK;
    }
    esp_err_t write(size_t offset, const void* src, size_t size) override { return write_raw(offset, src, size); }
    esp_err_t erase_range(size_t offset, size_t size) override {
        if (offset > bytes.size() || size > bytes.size() - offset) return ESP_ERR_INVALID_ARG;
        std::memset(bytes.data() + offset, 0xff, size);
        return ESP_OK;
    }
};

using Value = std::optional<std::vector<uint8_t>>;

struct Key {
    std::string ns;
    std::string name;
    nvs::ItemType type;
    std::vector<Value> allowed;
};

struct Record {
    uint32_t operation;
    uint32_t prefix;
    bool after;
    bool recovered;
    Image image;
    std::vector<Key> keys;
};

class Reader {
public:
    explicit Reader(std::vector<uint8_t> data) : data(std::move(data)) {}
    bool done() const { return at == data.size(); }
    uint8_t u8() { need(1); return data[at++]; }
    uint32_t u32() {
        need(4);
        uint32_t value = 0;
        for (int i = 0; i < 4; ++i) value |= uint32_t(data[at++]) << (8 * i);
        return value;
    }
    std::vector<uint8_t> bytes(size_t size) {
        need(size);
        std::vector<uint8_t> out(data.begin() + at, data.begin() + at + size);
        at += size;
        return out;
    }
    std::string str() {
        const auto raw = bytes(u8());
        return std::string(raw.begin(), raw.end());
    }

private:
    void need(size_t size) {
        if (size > data.size() - at) {
            std::fputs("truncated dump\n", stderr);
            std::exit(2);
        }
    }
    std::vector<uint8_t> data;
    size_t at = 0;
};

// What ESP-IDF's Storage reads for `key`: the value, absent, or an error.
static esp_err_t read_key(nvs::Storage& storage, const Key& key, Value& value) {
    value.reset();
    uint8_t ns = 0;
    auto err = storage.createOrOpenNamespace(key.ns.c_str(), false, ns);
    if (err == ESP_ERR_NVS_NOT_FOUND) return ESP_OK;
    if (err != ESP_OK) return err;
    size_t size = static_cast<uint8_t>(key.type) & 0x0f;
    if (key.type == nvs::ItemType::SZ || key.type == nvs::ItemType::BLOB) {
        err = storage.getItemDataSize(ns, key.type, key.name.c_str(), size);
        if (err == ESP_ERR_NVS_NOT_FOUND) return ESP_OK;
        if (err != ESP_OK) return err;
    }
    std::vector<uint8_t> data(size);
    err = storage.readItem(ns, key.type, key.name.c_str(), data.data(), size);
    if (err == ESP_ERR_NVS_NOT_FOUND) return ESP_OK;
    if (err != ESP_OK) return err;
    value = std::move(data);
    return ESP_OK;
}

static std::string describe(const Value& value) {
    if (!value) return "absent";
    std::string out = std::to_string(value->size()) + " bytes";
    if (value->size() <= 8) {
        out += ":";
        char hex[4];
        for (auto byte : *value) {
            std::snprintf(hex, sizeof(hex), " %02x", byte);
            out += hex;
        }
    }
    return out;
}

// Boots ESP-IDF on `partition` and fills `chosen` with the index of the
// allowed value it read for every key, or reports why it could not.
static bool check_boot(MemoryPartition& partition, const Record& record, std::vector<size_t>& chosen, const char* phase, std::string& why) {
    nvs::Storage storage(&partition);
    auto err = storage.init(0, page_count);
    if (err != ESP_OK) {
        why = std::string(phase) + ": Storage::init returned " + std::to_string(err);
        return false;
    }
    for (size_t k = 0; k < record.keys.size(); ++k) {
        const auto& key = record.keys[k];
        Value value;
        err = read_key(storage, key, value);
        if (err != ESP_OK) {
            why = std::string(phase) + ": " + key.ns + "/" + key.name + " read returned " + std::to_string(err);
            return false;
        }
        size_t match = key.allowed.size();
        for (size_t a = 0; a < key.allowed.size(); ++a) {
            if (key.allowed[a] == value) {
                match = a;
                break;
            }
        }
        if (match == key.allowed.size() || (chosen.size() > k && chosen[k] != match)) {
            why = std::string(phase) + ": " + key.ns + "/" + key.name + " read " + describe(value) + ", allowed";
            for (const auto& allowed : key.allowed) why += " [" + describe(allowed) + "]";
            if (match != key.allowed.size()) why += " (another choice than the first boot's)";
            return false;
        }
        if (chosen.size() <= k) chosen.push_back(match);
    }
    return true;
}

// The entry state of `index` on the page at `page`, as the bitmap holds it.
static unsigned entry_state(const uint8_t* page, size_t index) {
    return (page[32 + index / 4] >> (index % 4 * 2)) & 3;
}

// ESP-IDF's active-page load ends with a check that its last item is not a
// duplicate: `Page::mLoadEntryTable` (nvs_page.cpp:814-827) looks up the last
// item's namespace, type and key with `findItem` and erases an earlier match
// on the page. For a BLOB_DATA chunk, `findItem`'s default CHUNK_ANY matches
// any chunk of the key, so a chunk of the blob's other version is erased.
// ESP-IDF's own writer leaves this state: a reset between a rewrite's last
// chunk and its index, with an old chunk on the same page (state_fixture.cpp,
// idf_state_tail_chunk.bin). ESP-IDF then reads neither version. This store
// does not repeat that loss. Returns whether `image` is in that state for
// `key`: the active page's last item, as ESP-IDF finds it, is a BLOB_DATA of
// the key, and an earlier BLOB_DATA of it with another chunk index is there.
static bool idf_tail_chunk_loss(const Image& image, const Key& key) {
    if (key.type != nvs::ItemType::BLOB) return false;
    for (size_t p = 0; p < page_count; ++p) {
        const uint8_t* page = image.data() + p * nvs::Page::SEC_SIZE;
        uint32_t state;
        std::memcpy(&state, page, 4);
        if (state != 0xfffffffe) continue;
        // ESP-IDF's namespace entries: key = name, U8 value = index, ns 0.
        int ns = -1;
        std::vector<std::pair<size_t, nvs::Item>> items;
        size_t end = nvs::Page::ENTRY_COUNT;
        for (size_t i = 0; i < end; ++i) {
            if (entry_state(page, i) == 3) {
                end = i;
                break;
            }
        }
        for (size_t i = 0; i < end;) {
            nvs::Item item;
            std::memcpy(&item, page + 64 + i * 32, 32);
            if (entry_state(page, i) != 2 || !item.checkHeaderConsistency(i)) {
                ++i;
                continue;
            }
            items.emplace_back(i, item);
            const bool variable = item.datatype == nvs::ItemType::SZ || item.datatype == nvs::ItemType::BLOB ||
                                  item.datatype == nvs::ItemType::BLOB_DATA;
            i += variable ? item.span : 1;
        }
        for (size_t q = 0; q < page_count; ++q) {
            const uint8_t* other = image.data() + q * nvs::Page::SEC_SIZE;
            for (size_t i = 0; i < nvs::Page::ENTRY_COUNT; ++i) {
                nvs::Item item;
                std::memcpy(&item, other + 64 + i * 32, 32);
                if (entry_state(other, i) == 2 && item.nsIndex == 0 && item.datatype == nvs::ItemType::U8 &&
                    key.ns == item.key && item.checkHeaderConsistency(i)) ns = item.data[0];
            }
        }
        if (items.empty() || ns < 0) return false;
        const auto& last = items.back().second;
        if (last.datatype != nvs::ItemType::BLOB_DATA || last.nsIndex != ns || key.name != last.key) return false;
        for (size_t i = 0; i + 1 < items.size(); ++i) {
            const auto& item = items[i].second;
            if (item.datatype == nvs::ItemType::BLOB_DATA && item.nsIndex == ns && key.name == item.key &&
                item.chunkIndex != last.chunkIndex) return true;
        }
        return false;
    }
    return false;
}

static size_t tail_chunk_losses = 0;

static bool check_record(const Record& record, std::string& why) {
    MemoryPartition partition;
    partition.bytes = record.image;
    std::vector<size_t> chosen;
    if (!check_boot(partition, record, chosen, "first boot", why)) {
        // Only the known ESP-IDF loss, and only on a crashed image: then it
        // must read the key absent, and the rest as allowed, from then on.
        if (record.recovered) return false;
        Record lossy = record;
        bool known = false;
        for (auto& key : lossy.keys) {
            if (key.allowed.size() == 2 && idf_tail_chunk_loss(record.image, key)) {
                key.allowed = {Value()};
                known = true;
            }
        }
        if (!known) return false;
        std::string lossy_why;
        partition.bytes = record.image;
        chosen.clear();
        if (!check_boot(partition, lossy, chosen, "first boot (ESP-IDF tail chunk loss)", lossy_why) ||
            !check_boot(partition, lossy, chosen, "second boot (ESP-IDF tail chunk loss)", lossy_why)) {
            why += "; " + lossy_why;
            return false;
        }
        ++tail_chunk_losses;
        return true;
    }
    // ESP-IDF's load may have repaired the flash: its choice must hold.
    if (!check_boot(partition, record, chosen, "second boot", why)) return false;
    {
        nvs::Storage storage(&partition);
        if (storage.init(0, page_count) != ESP_OK) {
            why = "probe boot: Storage::init failed";
            return false;
        }
        uint8_t ns = 0;
        if (storage.createOrOpenNamespace("crosscheck", true, ns) != ESP_OK ||
            storage.writeItem(ns, "probe", uint32_t(0xdecafbad), nvs::Page::DEFAULT_PURGE_AFTER_ERASE) != ESP_OK) {
            why = "probe boot: writing a key failed";
            return false;
        }
    }
    return check_boot(partition, record, chosen, "after a write", why);
}

int main(int argc, char** argv) {
    if (argc != 2) {
        std::fputs("usage: crosscheck_idf <dump>\n", stderr);
        return 2;
    }
    auto* file = std::fopen(argv[1], "rb");
    if (file == nullptr) {
        std::perror(argv[1]);
        return 2;
    }
    std::vector<uint8_t> data;
    std::array<uint8_t, 1 << 16> chunk;
    size_t got;
    while ((got = std::fread(chunk.data(), 1, chunk.size(), file)) > 0) data.insert(data.end(), chunk.begin(), chunk.begin() + got);
    std::fclose(file);

    Reader in(std::move(data));
    size_t images[2] = {0, 0};
    size_t failures[2] = {0, 0};
    while (!in.done()) {
        Record record;
        const auto magic = in.bytes(4);
        if (std::memcmp(magic.data(), "NVSR", 4) != 0) {
            std::fputs("bad record magic\n", stderr);
            return 2;
        }
        record.operation = in.u32();
        record.prefix = in.u32();
        record.after = in.u8() != 0;
        record.recovered = in.u8() != 0;
        const auto image = in.bytes(image_size);
        std::copy(image.begin(), image.end(), record.image.begin());
        const size_t key_count = in.u8();
        for (size_t k = 0; k < key_count; ++k) {
            Key key;
            key.ns = in.str();
            key.name = in.str();
            key.type = static_cast<nvs::ItemType>(in.u8());
            const size_t alternatives = in.u8();
            for (size_t a = 0; a < alternatives; ++a) {
                const bool present = in.u8() != 0;
                auto bytes = in.bytes(in.u32());
                key.allowed.push_back(present ? Value(std::move(bytes)) : Value());
            }
            record.keys.push_back(std::move(key));
        }
        std::string why;
        ++images[record.recovered];
        if (!check_record(record, why)) {
            if (failures[0] + failures[1] < 20) {
                std::printf("FAIL %s image: operation=%u prefix=%u after=%d: %s\n",
                            record.recovered ? "recovered" : "crashed", record.operation, record.prefix, record.after, why.c_str());
            }
            ++failures[record.recovered];
        }
    }
    std::printf("ESP-IDF crosscheck: crashed images=%zu failures=%zu; recovered images=%zu failures=%zu; "
                "crashed images ESP-IDF reads with its tail chunk loss (accepted, not failures)=%zu\n",
                images[0], failures[0], images[1], failures[1], tail_chunk_losses);
    return failures[0] + failures[1] == 0 ? 0 : 1;
}
