#!/usr/bin/env python3
"""Boot random foreign NVS partitions with ESP-IDF's own init and this store's.

Usage: python3 <absolute-script-path> <absolute-esp-idf-checkout>
           [--zig ZIG] [--seed N] [--count N] [--show N] [partition.bin ...]

Compiles init_diff_idf.cpp with unmodified ESP-IDF Page, PageManager and
Storage code, which writes --count (default 3000) four-page partitions from
--seed (default 1): blob chunks, blob indexes and version 1 blobs of three
keys, complete or not, some with a damaged payload, between other keys, and
in some a key whose newest item, the newest page's last, has older items;
on one to three pages in any physical order, one of them in some partitions
marked as being freed: the states other writers, damage and interrupted
writes leave. Given partition files instead (16384 bytes each), it boots
those.

Each partition is booted twice by ESP-IDF's Storage and twice by this store
(`zig build nvs-init-diff`, nvs_init_diff.zig), the second boot on what the
first left: init, then each key's blob read four times. Both are compared,
step by step, with a model of the rules in this file: the items each init
leaves, every read's status and bytes, and the items the reads leave. The
model follows ESP-IDF's code, with one switch for each deliberate difference
of this store that the port's README documents. A case where ESP-IDF or the
store departs from the model in any item or read is UNEXPLAINED; so is one
where the two differ and no switch was used. Every other case that is not
the same on both sides is counted under the switches it used.

Prints the count of each class and up to --show (default 3) examples of each
that is not the same; exits non-zero if any case is UNEXPLAINED. Needs a host
C++17 compiler; ESP-IDF is only read. The zig build test gate does not run
this script.
"""
import argparse
import collections
from pathlib import Path
import struct
import subprocess
import tempfile
import zlib

from generate_fixtures import compile_idf_program

PAGE = 4096
PAGES = 4
PARTITION = PAGES * PAGE
ENTRIES = 126
# The keys both halves read, by namespace index, and how often per boot.
KEYS = ((1, "legacy"), (1, "other"), (2, "legacy"))
ROUNDS = 4
# A read, as both halves write it: u8 status, u32 length, the buffer.
BUFFER = 256
READ = 5 + BUFFER
# A boot: u8 init status, the partition after init, the reads, the partition
# after them. A record is two boots.
BOOT = 1 + PARTITION + ROUNDS * len(KEYS) * READ + PARTITION
RECORD = 2 * BOOT
FOUND, NOT_FOUND, FAILED, TOO_LONG = 0, 1, 2, 4
STATUS = {FOUND: "read", NOT_FOUND: "not found", FAILED: "failed", 3: "type mismatch", TOO_LONG: "too long"}
FREEING, FULL, ACTIVE = 0xFFFFFFF8, 0xFFFFFFFC, 0xFFFFFFFE
BLOB_LEGACY, BLOB_DATA, BLOB_INDEX = 0x41, 0x42, 0x48
ANY = 0xFF

# This store's deliberate differences from ESP-IDF, as the README lists
# them: the model's switches, and the name each case is counted under.
CLASSES = {
    "same": "both leave the same bytes and read the same, at every step",
    "last index's version 1 blob": "a version 1 blob on an older page than a blob index of its "
                                   "key that is the newest page's last item: ESP-IDF's "
                                   "PageManager::load erases it, whether or not the index reads; "
                                   "here the next two rules decide",
    "version 1 blob erased": "a version 1 blob beside a blob index of its key that reads is "
                             "erased by init here; ESP-IDF keeps it. Both read the index",
    "index that does not read": "beside a version 1 blob, an index ESP-IDF's init counts "
                                "complete that does not read: init erases the key's indexes "
                                "here and the version 1 blob is read; ESP-IDF's first read "
                                "fails and erases them",
    "damaged index kept": "a key without a version 1 blob keeps its blob indexes here whatever "
                          "their state, and reads Corrupt from one that does not read; "
                          "ESP-IDF's init erases an incomplete one",
    "shared start": "blob indexes of a key with one first chunk number: ESP-IDF's init erases "
                    "the first index with the number of an incomplete one, which may be a "
                    "complete one; here the incomplete one is erased, and only beside a "
                    "version 1 blob",
    "unfinished reclaim": "a page being freed and the newest page active: the newest page is "
                          "taken for the reclaim's unfinished copy here, and what its last "
                          "item replaced on a third page is kept; ESP-IDF's "
                          "PageManager::load erases that",
    "reclaim destination": "a page being freed and the newest page active: the reclaim is "
                           "started again on the page it was copying to here; ESP-IDF erases "
                           "that page and copies to its first free page",
    "failed read erases": "an ESP-IDF read that fails erases what it could not read (a chunk or "
                          "a version 1 blob with a damaged payload; the indexes and chunks of a "
                          "blob with a missing or too long chunk) and may answer not found; a "
                          "read erases nothing here and answers Corrupt",
    "UNEXPLAINED": "ESP-IDF or the store departs from the model, or they differ without a "
                   "switch",
}


class Item:
    def __init__(self, page, index, entries):
        entry = entries[index * 32:(index + 1) * 32]
        self.page, self.index, self.raw = page, index, entry
        self.ns, self.type, self.chunk = entry[0], entry[1], entry[3]
        self.span = entry[2] if self.type in (0x21, BLOB_LEGACY, BLOB_DATA) else 1
        self.key = entry[8:24].split(b"\0")[0].decode("latin1")
        data = entry[24:32]
        # A blob index's size, chunk count and first chunk number.
        self.size, self.count, self.start = struct.unpack("<I", data[:4])[0], data[4], data[5]
        # A chunk's or a version 1 blob's payload.
        self.length = struct.unpack("<H", data[:2])[0]
        self.payload = entries[(index + 1) * 32:(index + 1) * 32 + self.length]
        self.intact = zlib.crc32(self.payload, 0xFFFFFFFF) == struct.unpack("<I", data[4:])[0]

    @property
    def id(self):
        return (self.ns, self.key)

    def ident(self):
        return (self.page.number, self.index, self.raw)

    def __repr__(self):
        where = "p%d[%d]" % (self.page.number, self.index)
        name = "%s/%d" % (self.key, self.ns)
        damaged = "" if self.intact else " damaged"
        if self.type == BLOB_INDEX:
            return "%s index %s %dB %d chunks from %#x" % (where, name, self.size, self.count, self.start)
        if self.type == BLOB_DATA:
            return "%s chunk %s %#x %dB%s" % (where, name, self.chunk, self.length, damaged)
        if self.type == BLOB_LEGACY:
            return "%s v1 %s %dB%s" % (where, name, self.length, damaged)
        return "%s type %#x %s" % (where, self.type, name)


class Page:
    """A used page: its items marked written, in entry order; on an active
    page only those before its first entry marked empty, where ESP-IDF's
    `Page::findItem` stops (`mNextFreeEntry`)."""

    def __init__(self, number, bytes_):
        self.number = number
        state, self.seq = struct.unpack_from("<II", bytes_, 0)
        self.state = {FREEING: "freeing", FULL: "full", ACTIVE: "active"}.get(state)
        self.items = []
        self.end = ENTRIES
        index = 0
        while self.state and index < ENTRIES:
            entry_state = (bytes_[32 + index // 4] >> (index % 4 * 2)) & 3
            if self.state == "active" and entry_state == 3:
                self.end = index
                break
            if entry_state != 2:
                index += 1
                continue
            item = Item(self, index, bytes_[64:])
            self.items.append(item)
            index += item.span


def parse(image):
    """The used pages of a partition, oldest first: ESP-IDF's page list."""
    pages = [Page(number, image[number * PAGE:(number + 1) * PAGE]) for number in range(PARTITION // PAGE)]
    return sorted((page for page in pages if page.state), key=lambda page: page.seq)


def idents(pages):
    return {item.ident() for page in pages for item in page.items}


def placed(image):
    """The used pages' states, entry states and entries, wherever each page
    lies and whatever its sequence number."""
    pages = (image[at:at + PAGE] for at in range(0, PARTITION, PAGE))
    return sorted(page[:4] + page[32:] for page in pages if page.count(0xFF) != PAGE)


def show(pages):
    return "; ".join(repr(item) for page in pages for item in page.items) or "nothing"


def show_read(result):
    status, data = result
    return STATUS.get(status, str(status)) + (" %dB" % len(data) if status == FOUND else "")


class Model:
    """A boot of a partition, item by item: ESP-IDF's, or with `store` this
    store's. `used` collects the switches that changed what it did."""

    def __init__(self, image, store, used):
        self.pages, self.store, self.used = parse(image), store, used

    def all(self, kind):
        """The items of a type in ESP-IDF's list order."""
        return [item for page in self.pages for item in page.items if item.type == kind]

    def erase(self, item):
        item.page.items.remove(item)

    def page_find(self, page, ns, kind, key, chunk=ANY, start=None):
        """`Page::findItem`, with the hash list: the search starts at the
        page's first item with the namespace, key and chunk index. None for
        both ESP_ERR_NVS_NOT_FOUND and ESP_ERR_NVS_TYPE_MISMATCH."""
        same = [item for item in page.items if item.id == (ns, key)]
        if kind == BLOB_DATA and chunk == ANY:
            return next((item for item in same if item.type == BLOB_DATA), None)
        first = next((item for item in same if item.chunk == chunk), None)
        if first is None:
            return None
        for item in same[same.index(first):]:
            if kind == BLOB_DATA and item.chunk != chunk:
                continue
            if chunk == ANY and kind == BLOB_LEGACY and item.type == BLOB_INDEX:
                return None
            if chunk == ANY and kind == BLOB_LEGACY and item.type == BLOB_DATA:
                continue
            if kind == BLOB_INDEX and item.chunk != ANY:
                continue
            # Compared for an item of any type.
            if kind == BLOB_INDEX and start is not None and item.start != start:
                continue
            return item if item.type == kind else None
        return None

    def find(self, ns, kind, key, chunk=ANY):
        """`Storage::findItem`."""
        for page in self.pages:
            item = self.page_find(page, ns, kind, key, chunk)
            if item is not None:
                return item
        return None

    # ----- init -----

    def init(self):
        self.tail_chunk_keys = set()
        for page in self.pages:
            if page.state == "active":
                self.load_active(page)
        self.erase_replaced()
        self.reclaim()
        if self.store:
            self.store_blobs()
        else:
            self.idf_blobs()

    def load_active(self, page):
        """`Page::mLoadEntryTable`: an item erases the page's earlier item
        with its namespace, key and chunk index. Then ESP-IDF's check of the
        page's last entry, if an item holds it: `Page::findItem` for its
        type and key from the start of the page, with any chunk index."""
        for item in list(page.items):
            twin = next(i for i in page.items if (i.id, i.chunk) == (item.id, item.chunk))
            if twin is not item:
                self.erase(twin)
        if not page.items:
            return
        last = page.items[-1]
        if last.index + last.span != page.end:
            return
        if last.type == BLOB_DATA:
            self.tail_chunk_keys.add(last.id)
        found = self.page_find(page, last.ns, last.type, last.key)
        if found is not None and found is not last:
            self.erase(found)

    def erase_replaced(self):
        """`PageManager::load`: the newest page's last item erases the first
        item it replaced on an older page that is not being freed; ESP-IDF,
        for a blob index that replaced none, the first version 1 blob of
        its key. Not here while a page is being freed and the newest page
        is active."""
        if not self.pages or not self.pages[-1].items:
            return
        last = self.pages[-1].items[-1]
        older = [page for page in self.pages[:-1] if page.state != "freeing"]
        unfinished = self.pages[-1].state == "active" and len(older) + 1 < len(self.pages)
        for kind in [last.type] + ([BLOB_LEGACY] if last.type == BLOB_INDEX else []):
            for page in older:
                found = self.page_find(page, last.ns, kind, last.key, last.chunk)
                if found is None:
                    continue
                if kind != last.type and self.store:
                    self.used.add("last index's version 1 blob")
                elif unfinished and self.store:
                    self.used.add("unfinished reclaim")
                else:
                    self.erase(found)
                return

    def reclaim(self):
        """The interrupted reclaim of `PageManager::load`: an active newest
        page is erased, and the first page being freed is copied, item by
        item, to a free page that becomes the newest: ESP-IDF's first free
        page, the one just erased being its last; here the one just erased
        if there is one."""
        freeing = next((page for page in self.pages if page.state == "freeing"), None)
        if freeing is None:
            return
        free = [n for n in range(PAGES) if all(page.number != n for page in self.pages)]
        if self.pages[-1].state == "active":
            erased = self.pages.pop().number
            if not free:
                free = [erased]
            elif self.store:
                self.used.add("reclaim destination")
                free = [erased]
        self.pages.remove(freeing)
        freeing.number, freeing.state, freeing.end = free[0], "active", 0
        for item in freeing.items:
            item.index = freeing.end
            freeing.end += item.span
        self.pages.append(freeing)

    def complete(self, indexes):
        """`Storage::eraseMismatchedBlobIndexes`: each chunk counts for the
        first index of its key, in list order, whose range holds its number.
        Whether each index is complete by that count."""
        credit = [[0, 0] for _ in indexes]
        for chunk in self.all(BLOB_DATA):
            for n, index in enumerate(indexes):
                if index.id == chunk.id and index.start <= chunk.chunk < (0x80 if index.start == 0 else ANY):
                    credit[n][0] += 1
                    credit[n][1] += chunk.length
                    break
        return [credit[n] == [index.count, index.size] for n, index in enumerate(indexes)]

    def erase_orphans(self, indexes):
        """`Storage::eraseOrphanDataBlobs`."""
        for chunk in self.all(BLOB_DATA):
            if not any(i.id == chunk.id and i.start <= chunk.chunk < i.start + i.count for i in indexes):
                self.erase(chunk)

    def idf_blobs(self):
        """`Storage::init`, on the list of indexes it makes first."""
        nodes = self.all(BLOB_INDEX)
        kept = []
        for node, complete in zip(nodes, self.complete(nodes)):
            if complete:
                kept.append(node)
                continue
            # Erased by key and first chunk number, on the first page where
            # that finds an index.
            for page in self.pages:
                found = self.page_find(page, node.ns, BLOB_INDEX, node.key, ANY, node.start)
                if found is not None:
                    if node.id not in self.tail_chunk_keys and not any(i.id == node.id for i in self.all(BLOB_LEGACY)):
                        self.used.add("damaged index kept")
                    if found is not node:
                        self.used.add("shared start")
                    self.erase(found)
                    break
        self.erase_orphans(kept)

    def store_blobs(self):
        """`erase_stale_blobs` in nvs.zig."""
        legacies = self.all(BLOB_LEGACY)
        # The last index first: each is judged with all those before it.
        indexes = self.all(BLOB_INDEX)
        for n in reversed(range(len(indexes))):
            if (indexes[n].id in self.tail_chunk_keys or any(i.id == indexes[n].id for i in legacies)) and not self.complete(indexes[:n + 1])[n]:
                self.erase(indexes[n])
        for legacy in legacies:
            indexes = [i for i in self.all(BLOB_INDEX) if i.id == legacy.id]
            if not indexes:
                continue
            if self.store_chunks(indexes[0]) is not None:
                self.erase(legacy)
                self.used.add("version 1 blob erased")
            else:
                for index in indexes:
                    self.erase(index)
                self.used.add("index that does not read")
        self.erase_orphans(self.all(BLOB_INDEX))

    # ----- reads -----

    def read(self, ns, key):
        """A read as both halves do it: (status, bytes)."""
        return self.store_read(ns, key) if self.store else self.idf_read(ns, key)

    def store_chunks(self, index):
        """`read_chunks` in nvs.zig: the blob, or None for Corrupt."""
        data = b""
        for number in range(index.start, index.start + index.count):
            chunk = next((c for c in self.all(BLOB_DATA) if c.id == index.id and c.chunk == number), None)
            if chunk is None or not chunk.intact or len(data) + chunk.length > index.size:
                return None
            data += chunk.payload
        return data if len(data) == index.size else None

    def store_read(self, ns, key):
        """`find_blob`, `blob_len` and `get_blob` in nvs.zig."""
        legacy = None
        for page in self.pages:
            first = next((item for item in page.items if item.id == (ns, key) and item.type != BLOB_DATA), None)
            if first is None:
                continue
            if first.type == BLOB_INDEX:
                if first.size > BUFFER:
                    return TOO_LONG, b""
                data = self.store_chunks(first)
                return (FAILED, b"") if data is None else (FOUND, data)
            legacy = legacy or first
        if legacy is None:
            return NOT_FOUND, b""
        return (FOUND, legacy.payload) if legacy.intact else (FAILED, b"")

    def idf_read(self, ns, key):
        """`nvs_get_blob`: `Storage::getItemDataSize`, then
        `Storage::readItem` with that size into a zeroed buffer."""
        index = self.find(ns, BLOB_INDEX, key)
        legacy = self.find(ns, BLOB_LEGACY, key)
        if index is None and legacy is None:
            return NOT_FOUND, b""
        size = index.size if index is not None else legacy.length
        if size > BUFFER:
            return TOO_LONG, b""
        buffer = bytearray(size)
        if index is not None:
            status = self.idf_chunks(index, buffer)
            if status != NOT_FOUND:
                return status, bytes(buffer) if status == FOUND else b""
            # Not found: a version 1 blob is read, with the index's size.
            self.used.add("failed read erases")
            legacy = self.find(ns, BLOB_LEGACY, key)
            if legacy is None:
                return NOT_FOUND, b""
        if size < legacy.length:
            return FAILED, b""
        buffer[:legacy.length] = legacy.payload
        if not legacy.intact:
            self.erase(legacy)
            self.used.add("failed read erases")
            return NOT_FOUND, b""
        return FOUND, bytes(buffer)

    def idf_chunks(self, index, buffer):
        """`Storage::readMultiPageBlob`."""
        ns, key = index.id
        offset = 0
        status = FOUND
        for number in range(index.start, index.start + index.count):
            chunk = self.find(ns, BLOB_DATA, key, number)
            if chunk is None:
                status = NOT_FOUND
                break
            if chunk.length > len(buffer) - offset:
                status = FAILED
                break
            buffer[offset:offset + chunk.length] = chunk.payload
            if not chunk.intact:
                self.erase(chunk)
                return NOT_FOUND
            offset += chunk.length
        if status != FOUND:
            # `Storage::eraseMultiPageBlob`: two indexes of the key, and all
            # its chunks.
            self.used.add("failed read erases")
            self.erase(index)
            second = self.find(ns, BLOB_INDEX, key)
            if second is not None:
                self.erase(second)
            for chunk in self.all(BLOB_DATA):
                if chunk.id == index.id:
                    self.erase(chunk)
        return status if offset == len(buffer) else FAILED


class Boot:
    """A boot as a half recorded it."""

    def __init__(self, record):
        self.failed = record[0] != 0
        self.loaded = record[1:1 + PARTITION]
        self.reads = []
        at = 1 + PARTITION
        for _ in range(ROUNDS * len(KEYS)):
            length = struct.unpack_from("<I", record, at + 1)[0]
            self.reads.append((record[at], bytes(record[at + 5:at + 5 + length])))
            at += READ
        self.left = record[at:at + PARTITION]


def check(name, before, boot, store, used):
    """What a recorded boot of the partition `before` does that the model
    does not, as (what, detail) pairs."""
    if boot.failed:
        return [(name, "init failed")]
    model = Model(before, store, used)
    if any(index.start + index.count > ANY for index in model.all(BLOB_INDEX)):
        return [(name, "the model does not cover an index whose chunk numbers pass 254")]
    if len(model.pages) == PAGES and model.pages[-1].state != "active":
        return [(name, "the model does not cover an init without a free page")]
    model.init()
    if idents(model.pages) != idents(parse(boot.loaded)):
        return [(name + ", init", "the model leaves " + show(model.pages))]
    departures = []
    for n, result in enumerate(boot.reads):
        ns, key = KEYS[n % len(KEYS)]
        expected = model.read(ns, key)
        if result != expected:
            departures.append(("%s, read %d of %s/%d" % (name, n // len(KEYS) + 1, key, ns),
                               "%s, the model %s" % (show_read(result), show_read(expected))))
    if idents(model.pages) != idents(parse(boot.left)):
        departures.append((name + ", reads", "the model leaves " + show(model.pages)))
    if store and boot.left != boot.loaded:
        departures.append((name + ", reads", "a read changed the partition"))
    return departures


def classify(raw, idf, store):
    """The classes of a case, and what makes it UNEXPLAINED."""
    used = set()
    unexplained = []
    before_idf = before_store = raw
    same = True
    for n, name in enumerate(("first", "second")):
        idf_boot = Boot(idf[n * BOOT:(n + 1) * BOOT])
        store_boot = Boot(store[n * BOOT:(n + 1) * BOOT])
        unexplained += check("ESP-IDF's %s boot" % name, before_idf, idf_boot, False, used)
        unexplained += check("the store's %s boot" % name, before_store, store_boot, True, used)
        for what, ours, theirs in (("init", store_boot.loaded, idf_boot.loaded), ("reads", store_boot.left, idf_boot.left)):
            if ours != theirs:
                same = False
                # A reclaim written to another page leaves the same pages
                # at other places.
                moved = "reclaim destination" in used and placed(ours) == placed(theirs)
                if idents(parse(ours)) == idents(parse(theirs)) and not moved:
                    unexplained.append(("%s boot, %s" % (name, what), "the same items, other bytes"))
        same = same and idf_boot.reads == store_boot.reads
        before_idf, before_store = idf_boot.left, store_boot.left
    if not same and not used and not unexplained:
        unexplained.append(("difference", "no switch of the model was used"))
    if unexplained:
        return {"UNEXPLAINED"} | used, unexplained
    return ({"same"} if same else used), []


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("idf", type=Path)
    parser.add_argument("partitions", nargs="*", type=Path)
    parser.add_argument("--zig", default="zig")
    parser.add_argument("--seed", type=int, default=1)
    parser.add_argument("--count", type=int, default=3000)
    parser.add_argument("--show", type=int, default=3)
    args = parser.parse_args()
    idf = args.idf.resolve(strict=True)
    here = Path(__file__).resolve().parent
    port = here.parents[2]
    cache = port / ".zig-cache"
    cache.mkdir(exist_ok=True)
    counts = collections.Counter()
    shown = collections.Counter()
    with tempfile.TemporaryDirectory(prefix="idf-init-diff-", dir=cache) as temp:
        work = Path(temp)
        exe = compile_idf_program(idf, work, here / "init_diff_idf.cpp", True, ["NO_DEBUG_STORAGE"])
        partitions = work / "partitions.bin"
        if args.partitions:
            if any(path.stat().st_size != PARTITION for path in args.partitions):
                raise SystemExit("each partition file must hold %d bytes" % PARTITION)
            partitions.write_bytes(b"".join(path.read_bytes() for path in args.partitions))
            names = [str(path) for path in args.partitions]
        else:
            subprocess.run([str(exe), "generate", str(partitions), str(args.seed), str(args.count)], check=True)
            names = ["seed %d case %d" % (args.seed, n) for n in range(args.count)]
        subprocess.run([str(exe), "load", str(partitions), str(work / "idf.bin")], check=True)
        subprocess.run([args.zig, "build", "nvs-init-diff", "-Dnvs-init-diff=" + str(work)], cwd=port, check=True)
        if [(work / name).stat().st_size for name in ("idf.bin", "store.bin")] != [len(names) * RECORD] * 2:
            raise SystemExit("a record is missing")
        with open(partitions, "rb") as raw_file, open(work / "idf.bin", "rb") as idf_file, open(work / "store.bin", "rb") as store_file:
            for name in names:
                image, idf_record, store_record = raw_file.read(PARTITION), idf_file.read(RECORD), store_file.read(RECORD)
                classes, unexplained = classify(image, idf_record, store_record)
                counts.update(classes)
                label = " + ".join(sorted(classes))
                if classes == {"same"} or not (args.partitions or shown[label] < args.show):
                    continue
                shown[label] += 1
                print("--- %s: %s" % (name, label))
                print("  partition:", show(parse(image)))
                for half, record in (("ESP-IDF", idf_record), ("store", store_record)):
                    for n in range(2):
                        boot = Boot(record[n * BOOT:(n + 1) * BOOT])
                        reads = ["/".join(show_read(r) for r in boot.reads[k::len(KEYS)]) for k in range(len(KEYS))]
                        print("  %-7s boot %d: %s | reads %s | then %s" % (
                            half, n + 1, show(parse(boot.loaded)), ", ".join(reads),
                            "the same" if boot.left == boot.loaded else show(parse(boot.left))))
                for what, detail in unexplained:
                    print("  UNEXPLAINED %s: %s" % (what, detail))
    print("%d partitions; cases per class (a case can be in several):" % len(names))
    for name, text in CLASSES.items():
        print("%7d  %-28s %s" % (counts[name], name, text))
    raise SystemExit(1 if counts["UNEXPLAINED"] else 0)


if __name__ == "__main__":
    main()
