import CHound
import Foundation

/// Swift wrapper for the Hound search library
public class Hound {
    
    /// Library version
    public static var version: String {
        String(cString: hound_version())
    }
    
    // MARK: - Index Writer
    
    public class IndexWriter {
        private var handle: OpaquePointer?
        
        public init?(path: String) {
            handle = hound_index_writer_create(path)
            if handle == nil { return nil }
        }
        
        deinit {
            if let handle = handle {
                hound_index_writer_destroy(handle)
            }
        }
        
        public func addFile(name: String, content: Data) -> Bool {
            guard let handle = handle else { return false }
            return content.withUnsafeBytes { buffer in
                guard let ptr = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                    return false
                }
                return hound_index_writer_add_file(handle, name, ptr, buffer.count)
            }
        }
        
        public func addFile(name: String, content: String) -> Bool {
            addFile(name: name, content: Data(content.utf8))
        }
        
        public func finish() -> Bool {
            guard let handle = handle else { return false }
            return hound_index_writer_finish(handle)
        }
    }
    
    // MARK: - Index Reader
    
    public class IndexReader {
        fileprivate var handle: OpaquePointer?
        
        public init?(path: String) {
            handle = hound_index_reader_open(path)
            if handle == nil { return nil }
        }
        
        deinit {
            if let handle = handle {
                hound_index_reader_close(handle)
            }
        }
        
        public var fileCount: UInt64 {
            guard let handle = handle else { return 0 }
            return hound_index_reader_file_count(handle)
        }
        
        public var trigramCount: Int {
            guard let handle = handle else { return 0 }
            return hound_index_reader_trigram_count(handle)
        }
    }
    
    // MARK: - Search Result
    
    public struct SearchResult {
        public let fileId: UInt32
        public let matchCount: UInt32
        public let name: String
    }
    
    // MARK: - Searcher
    
    public class Searcher {
        private var handle: OpaquePointer?
        private let reader: IndexReader
        
        public init?(reader: IndexReader) {
            guard let readerHandle = reader.handle else { return nil }
            handle = hound_searcher_create(readerHandle)
            if handle == nil { return nil }
            self.reader = reader
        }
        
        deinit {
            if let handle = handle {
                hound_searcher_destroy(handle)
            }
        }
        
        public func search(_ query: String, maxResults: Int = 100) -> [SearchResult] {
            guard let handle = handle else { return [] }
            
            guard let results = hound_search(handle, query, maxResults) else {
                return []
            }
            defer { hound_search_results_free(results) }
            
            var output: [SearchResult] = []
            for i in 0..<results.pointee.count {
                let r = results.pointee.results[i]
                let name = String(cString: r.name)
                output.append(SearchResult(
                    fileId: r.file_id,
                    matchCount: r.match_count,
                    name: name
                ))
            }
            return output
        }
    }
    
    // MARK: - Incremental Indexer
    
    public class IncrementalIndexer {
        private var handle: OpaquePointer?
        
        public init?(indexPath: String, batchWindowMs: UInt32 = 1000, enableWatcher: Bool = true) {
            handle = hound_incremental_indexer_create(indexPath, batchWindowMs, enableWatcher)
            if handle == nil { return nil }
        }
        
        deinit {
            if let handle = handle {
                hound_incremental_indexer_destroy(handle)
            }
        }
        
        public func addDirectory(_ path: String) -> Bool {
            guard let handle = handle else { return false }
            return hound_incremental_indexer_add_directory(handle, path)
        }
        
        public func scan() -> Int {
            guard let handle = handle else { return 0 }
            return hound_incremental_indexer_scan(handle)
        }
        
        public func rebuild() -> Bool {
            guard let handle = handle else { return false }
            return hound_incremental_indexer_rebuild(handle)
        }
        
        public func pollEvents() -> Bool {
            guard let handle = handle else { return false }
            return hound_incremental_indexer_poll_events(handle)
        }
        
        public var hasPendingChanges: Bool {
            guard let handle = handle else { return false }
            return hound_incremental_indexer_has_pending_changes(handle)
        }
    }
}
