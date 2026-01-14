import Foundation

print("Hound Swift Example")
print("Version: \(Hound.version)\n")

let indexPath = "/tmp/hound_swift_test.idx"
let testDir = "/tmp/hound_swift_test_files"

// Create test files
let fm = FileManager.default
try? fm.removeItem(atPath: testDir)
try! fm.createDirectory(atPath: testDir, withIntermediateDirectories: true)
try! "hello world".write(toFile: "\(testDir)/hello.txt", atomically: true, encoding: .utf8)
try! "foo bar baz".write(toFile: "\(testDir)/foo.txt", atomically: true, encoding: .utf8)
try! "hello foo world".write(toFile: "\(testDir)/mixed.txt", atomically: true, encoding: .utf8)

// Test 1: Create index
print("=== Test 1: Index Writer ===")
guard let writer = Hound.IndexWriter(path: indexPath) else {
    fatalError("Could not create index writer")
}

_ = writer.addFile(name: "hello.txt", content: "hello world")
_ = writer.addFile(name: "foo.txt", content: "foo bar baz")
_ = writer.addFile(name: "mixed.txt", content: "hello foo world")

guard writer.finish() else {
    fatalError("Could not finish index")
}
print("Created index with 3 files\n")

// Test 2: Open and search
print("=== Test 2: Search ===")
guard let reader = Hound.IndexReader(path: indexPath) else {
    fatalError("Could not open index")
}
print("File count: \(reader.fileCount)")
print("Trigram count: \(reader.trigramCount)")

guard let searcher = Hound.Searcher(reader: reader) else {
    fatalError("Could not create searcher")
}

let results = searcher.search("hello", maxResults: 10)
print("\nSearch for 'hello' returned \(results.count) results:")
for (i, r) in results.enumerated() {
    print("  [\(i)] \(r.name) (match_count: \(r.matchCount))")
}

let fooResults = searcher.search("foo")
print("\nSearch for 'foo' returned \(fooResults.count) results")

let emptyResults = searcher.search("xyz123")
print("Search for 'xyz123' returned \(emptyResults.count) results\n")

// Test 3: Incremental indexer
print("=== Test 3: Incremental Indexer ===")
let incrIndexPath = "/tmp/hound_swift_incr_test.idx"
guard let indexer = Hound.IncrementalIndexer(indexPath: incrIndexPath, batchWindowMs: 100, enableWatcher: false) else {
    fatalError("Could not create incremental indexer")
}

_ = indexer.addDirectory(testDir)
let changes = indexer.scan()
print("Scan found \(changes) changes")

guard indexer.rebuild() else {
    fatalError("Could not rebuild index")
}
print("Rebuilt index")

// Cleanup
try? fm.removeItem(atPath: testDir)
try? fm.removeItem(atPath: indexPath)
try? fm.removeItem(atPath: incrIndexPath)

print("\n=== ALL TESTS PASSED ===")
