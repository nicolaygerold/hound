/**
 * Hound - Fast text search library with trigram indexing
 *
 * C API for integration with Swift, Objective-C, and other languages.
 */

#ifndef HOUND_H
#define HOUND_H

#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ============================================================================
 * Opaque Types
 * ============================================================================ */

typedef struct HoundIndexWriter HoundIndexWriter;
typedef struct HoundIndexReader HoundIndexReader;
typedef struct HoundSearcher HoundSearcher;
typedef struct HoundIncrementalIndexer HoundIncrementalIndexer;

/* ============================================================================
 * Search Result Types
 * ============================================================================ */

typedef struct {
    uint32_t file_id;
    uint32_t match_count;
    const char* name;
    size_t name_len;
} HoundSearchResult;

typedef struct {
    HoundSearchResult* results;
    size_t count;
} HoundSearchResults;

/* ============================================================================
 * Index Writer API
 *
 * Create a new index from files.
 * ============================================================================ */

/**
 * Create a new index writer.
 *
 * @param path Path where the index file will be written (null-terminated).
 * @return Writer handle, or NULL on failure.
 */
HoundIndexWriter* hound_index_writer_create(const char* path);

/**
 * Add a file to the index.
 *
 * @param writer Writer handle.
 * @param name File name/path to store in the index (null-terminated).
 * @param content File content bytes.
 * @param content_len Length of content in bytes.
 * @return true on success, false on failure.
 */
bool hound_index_writer_add_file(
    HoundIndexWriter* writer,
    const char* name,
    const uint8_t* content,
    size_t content_len
);

/**
 * Finish writing and finalize the index.
 *
 * @param writer Writer handle.
 * @return true on success, false on failure.
 */
bool hound_index_writer_finish(HoundIndexWriter* writer);

/**
 * Destroy the writer and free resources.
 *
 * @param writer Writer handle.
 */
void hound_index_writer_destroy(HoundIndexWriter* writer);

/* ============================================================================
 * Index Reader API
 *
 * Open and query an existing index.
 * ============================================================================ */

/**
 * Open an existing index file.
 *
 * @param path Path to the index file (null-terminated).
 * @return Reader handle, or NULL on failure.
 */
HoundIndexReader* hound_index_reader_open(const char* path);

/**
 * Close the index reader and free resources.
 *
 * @param reader Reader handle.
 */
void hound_index_reader_close(HoundIndexReader* reader);

/**
 * Get the number of files in the index.
 *
 * @param reader Reader handle.
 * @return Number of indexed files.
 */
uint64_t hound_index_reader_file_count(HoundIndexReader* reader);

/**
 * Get the number of unique trigrams in the index.
 *
 * @param reader Reader handle.
 * @return Number of trigrams.
 */
size_t hound_index_reader_trigram_count(HoundIndexReader* reader);

/* ============================================================================
 * Searcher API
 *
 * Search the index with ranked results.
 * ============================================================================ */

/**
 * Create a searcher for an open index.
 *
 * @param reader Reader handle (must remain open while searcher is in use).
 * @return Searcher handle, or NULL on failure.
 */
HoundSearcher* hound_searcher_create(HoundIndexReader* reader);

/**
 * Destroy the searcher and free resources.
 *
 * @param searcher Searcher handle.
 */
void hound_searcher_destroy(HoundSearcher* searcher);

/**
 * Search the index for a query string.
 *
 * Results are ranked by how many query trigrams match each file.
 *
 * @param searcher Searcher handle.
 * @param query Search query string (null-terminated).
 * @param max_results Maximum number of results to return.
 * @return Search results, or NULL on failure. Must be freed with hound_search_results_free().
 */
HoundSearchResults* hound_search(
    HoundSearcher* searcher,
    const char* query,
    size_t max_results
);

/**
 * Free search results.
 *
 * @param results Results from hound_search().
 */
void hound_search_results_free(HoundSearchResults* results);

/* ============================================================================
 * Incremental Indexer API
 *
 * Watch directories and incrementally update the index.
 * ============================================================================ */

/**
 * Create an incremental indexer with file watching.
 *
 * @param index_path Path where the index file will be written (null-terminated).
 * @param batch_window_ms Milliseconds to wait before processing batched changes.
 * @param enable_watcher Enable file system watching (inotify/kqueue).
 * @return Indexer handle, or NULL on failure.
 */
HoundIncrementalIndexer* hound_incremental_indexer_create(
    const char* index_path,
    uint32_t batch_window_ms,
    bool enable_watcher
);

/**
 * Destroy the incremental indexer and free resources.
 *
 * @param indexer Indexer handle.
 */
void hound_incremental_indexer_destroy(HoundIncrementalIndexer* indexer);

/**
 * Add a directory to watch and index.
 *
 * @param indexer Indexer handle.
 * @param path Directory path (null-terminated).
 * @return true on success, false on failure.
 */
bool hound_incremental_indexer_add_directory(
    HoundIncrementalIndexer* indexer,
    const char* path
);

/**
 * Scan all watched directories for changes.
 *
 * @param indexer Indexer handle.
 * @return Number of changed files detected.
 */
size_t hound_incremental_indexer_scan(HoundIncrementalIndexer* indexer);

/**
 * Rebuild the index with all current files.
 *
 * @param indexer Indexer handle.
 * @return true on success, false on failure.
 */
bool hound_incremental_indexer_rebuild(HoundIncrementalIndexer* indexer);

/**
 * Poll for file system events (non-blocking).
 *
 * @param indexer Indexer handle.
 * @return true if events were received, false otherwise.
 */
bool hound_incremental_indexer_poll_events(HoundIncrementalIndexer* indexer);

/**
 * Check if there are pending changes to process.
 *
 * @param indexer Indexer handle.
 * @return true if there are pending changes.
 */
bool hound_incremental_indexer_has_pending_changes(HoundIncrementalIndexer* indexer);

/* ============================================================================
 * Utility API
 * ============================================================================ */

/**
 * Get the library version string.
 *
 * @return Version string (e.g., "0.1.0").
 */
const char* hound_version(void);

#ifdef __cplusplus
}
#endif

#endif /* HOUND_H */
