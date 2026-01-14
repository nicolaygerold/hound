# hound

Fast text search library with trigram indexing, inspired by [Google Code Search](https://github.com/google/codesearch) and [Zoekt](https://github.com/sourcegraph/zoekt).

## Features

- **Trigram indexing** - Fast substring search using 3-character n-grams
- **Segment-based architecture** - Immutable segments for true incremental updates without full index rebuilds
- **Positional trigrams** - Store byte/rune offsets where each trigram appears, enabling proximity queries
- **Regex search** - Filter candidates by extracting trigrams from regex patterns, then verify with full regex match
- **Parallel search** - Multi-threaded file verification for faster search on multi-core systems
- **Ranked results** - Files ranked by how many query trigrams match (BM25 scoring)
- **Context snippets** - Search results include matching lines with surrounding context, line numbers, and match positions
- **File watching** - Incremental updates via inotify (Linux) / kqueue (macOS)
- **Atomic commits** - Crash-safe index updates via meta.json atomic writes
- **XDG-compliant storage** - Indexes stored in standard cache directories
- **C API** - Use from Swift, Objective-C, or any C-compatible language

## Installation

```bash
zig build -Doptimize=ReleaseFast
```

Outputs:
- `zig-out/lib/libhound.a` - Zig library
- `zig-out/lib/libhound_c.a` - C API static library
- `zig-out/lib/libhound_c.dylib` - C API dynamic library
- `zig-out/include/hound.h` - C header

## Usage

### Zig

```zig
const hound = @import("hound");

// Create index
var writer = try hound.index.IndexWriter.init(allocator, "index.hound");
try writer.addFile("main.zig", file_content);
try writer.finish();
writer.deinit();

// Search
var reader = try hound.reader.IndexReader.open(allocator, "index.hound");
defer reader.close();

var searcher = try hound.search.Searcher.init(allocator, &reader);
defer searcher.deinit();

// Substring search
const results = try searcher.search("handleRequest", 10);
defer searcher.freeResults(results);

for (results) |r| {
    std.debug.print("{s}: {d} matches\n", .{ r.name, r.match_count });
    for (r.snippets) |snippet| {
        std.debug.print("  L{d}: {s}\n", .{ snippet.line_number, snippet.line_content });
    }
}

// Regex search
const regex_results = try searcher.searchRegex("handle[A-Z][a-z]+", 10);
defer searcher.freeResults(regex_results);

for (regex_results) |r| {
    std.debug.print("{s}: {d} regex matches\n", .{ r.name, r.match_count });
}

// Configure thread count for parallel search
var parallel_searcher = try hound.search.Searcher.initWithOptions(allocator, &reader, .{
    .thread_count = 8,  // 0 = auto-detect CPU count
    .context_lines = 2,
    .max_snippets_per_file = 10,
});
defer parallel_searcher.deinit();
```

#### Positional Index with Proximity Search

```zig
const hound = @import("hound");

// Create positional index
var writer = try hound.positional_index.PositionalIndexWriter.init(allocator, "index.hound");
try writer.addFile("main.zig", file_content);
try writer.finish();
writer.deinit();

// Open and search
var reader = try hound.positional_reader.PositionalIndexReader.open(allocator, "index.hound");
defer reader.close();

// Proximity search: find files where "abc" and "def" appear within 10 runes of each other
const tri_abc = hound.trigram.fromBytes('a', 'b', 'c');
const tri_def = hound.trigram.fromBytes('d', 'e', 'f');

const results = try hound.positional_reader.proximitySearch(
    allocator,
    &reader,
    tri_abc,
    tri_def,
    10,  // max distance in runes
);
defer allocator.free(results);

for (results) |file_id| {
    std.debug.print("Match in file: {s}\n", .{reader.getName(file_id).?});
}
```

### Segment-Based Incremental Indexing

The segment-based index allows true incremental updates without rebuilding the entire index:

```zig
const hound = @import("hound");

// Create or open segment-based index
var writer = try hound.segment_index.SegmentIndexWriter.init(allocator, "index_dir");
defer writer.deinit();

// Add files - each commit creates a new immutable segment
try writer.addFile("src/main.zig", file_content);
try writer.addFile("src/utils.zig", other_content);
try writer.commit();  // Creates segment 1

// Add more files later
try writer.addFile("src/new_feature.zig", new_content);
try writer.commit();  // Creates segment 2 (segment 1 unchanged)

// Update existing files - old version marked as deleted, new version in new segment
try writer.addFile("src/main.zig", updated_content);
try writer.commit();

// Delete files
try writer.deleteFile("src/old_file.zig");
try writer.commit();

// Search across all segments
var reader = try hound.segment_index.SegmentIndexReader.open(allocator, "index_dir");
defer reader.close();

const tri = hound.trigram.fromBytes('h', 'e', 'l');
var iter = reader.lookupTrigram(tri);
const file_ids = try iter.collect(allocator);
defer allocator.free(file_ids);

for (file_ids) |global_id| {
    const name = reader.getName(global_id).?;
    std.debug.print("Found: {s}\n", .{name});
}
```

### Legacy Incremental Indexing with File Watching

```zig
const hound = @import("hound");

var indexer = try hound.incremental.IncrementalIndexer.init(allocator, .{
    .index_path = "index.hound",
    .batch_window_ms = 1000,  // Wait 1s before processing changes
    .enable_watcher = true,   // Enable inotify/kqueue
});
defer indexer.deinit();

try indexer.addDirectory("/path/to/code");

// Initial scan and index
_ = try indexer.scan();
try indexer.rebuildIndex();

// Watch loop
var daemon = hound.incremental.Daemon.init(&indexer, 100);
while (try daemon.runOnce()) {
    // Index rebuilt after detecting changes
}
```

### XDG Paths

```zig
const hound = @import("hound");

var xdg = try hound.paths.XdgPaths.init(allocator);
defer xdg.deinit();

const project = try hound.paths.projectNameFromPath(allocator, "/path/to/myproject");
defer allocator.free(project);

const index_path = try xdg.getIndexPath(project);
defer allocator.free(index_path);
// Linux:  ~/.cache/hound/myproject-a1b2c3d4/index.hound
// macOS:  ~/Library/Caches/hound/myproject-a1b2c3d4/index.hound
```

### C API

```c
#include <hound.h>

// Create index
HoundIndexWriter* writer = hound_index_writer_create("index.hound");
hound_index_writer_add_file(writer, "main.c", content, strlen(content));
hound_index_writer_finish(writer);
hound_index_writer_destroy(writer);

// Search
HoundIndexReader* reader = hound_index_reader_open("index.hound");
HoundSearcher* searcher = hound_searcher_create(reader);

HoundSearchResults* results = hound_search(searcher, "malloc", 10);
for (size_t i = 0; i < results->count; i++) {
    printf("%s: %u matches\n", results->results[i].name, results->results[i].match_count);
}

hound_search_results_free(results);
hound_searcher_destroy(searcher);
hound_index_reader_close(reader);
```

### Swift

See [examples/swift/](examples/swift/) for a complete Swift wrapper.

```swift
import Hound

// Create index
let writer = Hound.IndexWriter(path: "index.hound")!
writer.addFile(name: "main.swift", content: "func hello() {}")
writer.finish()

// Search
let reader = Hound.IndexReader(path: "index.hound")!
let searcher = Hound.Searcher(reader: reader)!

let results = searcher.search("hello", maxResults: 10)
for r in results {
    print("\(r.name): \(r.matchCount) matches")
}
```

## Configuration

### IncrementalIndexer Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `index_path` | `[]const u8` | required | Path to the index file |
| `batch_window_ms` | `u32` | `1000` | Milliseconds to wait before processing batched file changes |
| `enable_watcher` | `bool` | `true` | Enable file system watching (inotify/kqueue) |

### SearchOptions

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `max_results` | `usize` | `100` | Maximum number of results to return |
| `context_lines` | `u32` | `2` | Number of context lines around matches |
| `max_snippets_per_file` | `u32` | `10` | Maximum snippets per file |
| `thread_count` | `u32` | `0` | Number of threads for parallel verification (0 = auto-detect CPU count, capped at 16) |

### Storage Locations

Hound follows the [XDG Base Directory Specification](https://specifications.freedesktop.org/basedir-spec/basedir-spec-latest.html):

| Data Type | Linux | macOS |
|-----------|-------|-------|
| Index (cache) | `~/.cache/hound/<project>/` | `~/Library/Caches/hound/<project>/` |
| State (data) | `~/.local/share/hound/<project>/` | `~/Library/Application Support/hound/<project>/` |
| Config | `~/.config/hound/` | `~/Library/Application Support/hound/` |

Override with environment variables: `XDG_CACHE_HOME`, `XDG_DATA_HOME`, `XDG_CONFIG_HOME`.

### Trigram Extractor Limits

Defined in [src/trigram.zig](src/trigram.zig):

| Limit | Value | Description |
|-------|-------|-------------|
| `max_file_len` | 1 GB | Maximum file size to index |
| `max_line_len` | 2000 chars | Lines longer than this are skipped |
| `max_trigrams` | 20000 | Maximum unique trigrams per file |

Files with NUL bytes or invalid UTF-8 are skipped.

## Index Format

### Segment-Based Index (v3)

The segment-based architecture stores the index as multiple immutable segments:

```
index_dir/
├── meta.json                 ← Atomic commit log, tracks active segments
└── segments/
    ├── <segment_id>.seg      ← Individual segment file (v1 format)
    ├── <segment_id>.del      ← Deletion bitmap (optional)
    └── ...
```

**meta.json structure:**
```json
{
  "version": 1,
  "opstamp": 42,
  "segments": [
    {
      "id": "e9f92d57...",
      "num_docs": 1000,
      "num_deleted_docs": 10,
      "has_deletions": true,
      "del_gen": 2
    }
  ]
}
```

Key design principles (inspired by [tantivy](https://github.com/quickwit-oss/tantivy)):
- **Immutable segments**: Once written, segment files never change
- **Atomic commits**: Write new segments → fsync → atomic rename meta.json
- **Deletions via bitmaps**: Files marked as deleted, not removed from segments
- **Concurrent reads**: Readers snapshot meta.json at open time

### Standard Index (v1)

Binary format inspired by Google Code Search:

```
┌─────────────────────────────────┐
│ Magic Header ("hound idx 1\n")  │
├─────────────────────────────────┤
│ Name List                       │  ← file paths, varint-length prefixed
├─────────────────────────────────┤
│ Posting Lists                   │  ← delta+1 encoded file IDs per trigram
├─────────────────────────────────┤
│ Posting Index                   │  ← trigram → (count, offset) lookup
├─────────────────────────────────┤
│ Trailer (32 bytes + magic)      │  ← section offsets
└─────────────────────────────────┘
```

### Positional Index (v2)

Extended format with position data for proximity queries:

```
┌─────────────────────────────────┐
│ Magic Header ("hound idx 2\n")  │
├─────────────────────────────────┤
│ Name List                       │  ← file paths, varint-length prefixed
├─────────────────────────────────┤
│ Positional Posting Lists        │  ← per file: (file_id, position_count, 
│                                 │     [(byte_offset, rune_offset)...])
├─────────────────────────────────┤
│ Posting Index                   │  ← trigram → (file_count, pos_count, offset)
├─────────────────────────────────┤
│ Rune Offset Maps                │  ← per file: sampled byte offsets every 100 runes
│                                 │     for efficient rune→byte conversion
├─────────────────────────────────┤
│ Trailer (48 bytes + magic)      │  ← section offsets
└─────────────────────────────────┘
```

Position encoding uses delta compression:
- File IDs: delta+1 encoded (0 = end marker)
- Byte/rune offsets: delta from previous position within each file
- Rune sampling: every 100 runes, inspired by Zoekt's design

The index is opened with `mmap()` for zero-copy access.

## Development

```bash
# Run tests
zig build test

# Build release
zig build -Doptimize=ReleaseFast

# Format code
zig fmt src/
```

## License

MIT
