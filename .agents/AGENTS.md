# Hound - Fast Text Search Library

## Reference Implementations

### Trigram-Based Indexing (Primary Approach)

| Project | Language | GitHub | Key Files |
|---------|----------|--------|-----------|
| **Zoekt** | Go | https://github.com/sourcegraph/zoekt | [doc/design.md](https://github.com/sourcegraph/zoekt/blob/main/doc/design.md), [index/shard_builder.go](https://github.com/sourcegraph/zoekt/blob/main/index/shard_builder.go) |
| **Google Code Search** | Go | https://github.com/google/codesearch | [index/write.go](https://github.com/google/codesearch/blob/master/index/write.go), [index/read.go](https://github.com/google/codesearch/blob/master/index/read.go), [index/regexp.go](https://github.com/google/codesearch/blob/master/index/regexp.go) |

### Inverted Index (Full-Text Search)

| Project | Language | GitHub | Key Files |
|---------|----------|--------|-----------|
| **Tantivy** | Rust | https://github.com/quickwit-oss/tantivy | [ARCHITECTURE.md](https://github.com/quickwit-oss/tantivy/blob/main/ARCHITECTURE.md) |
| **Bleve** | Go | https://github.com/blevesearch/bleve | Scorch segment implementation |

### Search Engines (No Index)

| Project | Language | GitHub | Why Study |
|---------|----------|--------|-----------|
| **Ripgrep** | Rust | https://github.com/BurntSushi/ripgrep | mmap vs buffer, parallel search, regex optimization, gitignore handling |
| **The Silver Searcher (ag)** | C | https://github.com/ggreer/the_silver_searcher | Boyer-Moore, pthreads parallelization, mmap |
| **Livegrep** | C++ | https://github.com/livegrep/livegrep | Real-time indexing, [src/codesearch.h](https://github.com/livegrep/livegrep/blob/main/src/codesearch.h) |

## Architecture Strategy

### Recommended: Zoekt + Tantivy Hybrid

1. **Trigram indexing** (from Zoekt/Code Search) - best for substring search
2. **Segment-based storage** (from Tantivy) - immutable segments + atomic commits
3. **mmap the index** - critical for performance
4. **Delta-encoded varint posting lists** - space efficiency
5. **UTF-8 rune offset sampling** - every 100 runes for multibyte text

### Trigram Index Structure

```
"ban": [offset0, offset1, ...]
"ana": [offset0, offset1, offset2, ...]
"nan": [offset0, ...]
```

- Extract trigrams from query
- Lookup posting lists (mmap'd)
- Intersect file candidates
- Verify matches in content
- Rank and return with context

### Incremental Updates

- Track file mtime/size fingerprint
- Batch changes before commit
- Re-scan paths, merge into existing index
- Atomic segment commit

### File Watching

- Integrate with OS-specific APIs (inotify, FSEvents, kqueue)
- Batch file changes (1 second window)
- Re-index changed files incrementally

## Ranking Signals

- Number of query terms matched
- Match proximity (distance between terms)
- Word boundary quality (whole word matches)
- File recency
- Optional: BM25 scoring

## Performance Techniques

| Technique | Purpose |
|-----------|---------|
| Parallel search | Multi-core utilization |
| Literal optimization | Fast path for literal strings |
| Boyer-Moore | O(n/m) substring search |
| SIMD | CPU acceleration for scanning |
| Lazy evaluation | Only load necessary posting lists |
| mmap | Avoid copying, let OS handle paging |

## Build & Test

```bash
zig build        # Build
zig build run    # Run CLI
zig build test   # Run tests
```
