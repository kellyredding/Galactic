import Foundation

/// A corpus as one contiguous block of bytes, however it was obtained.
///
/// This is the type that makes "the in-memory representation is the on-disk
/// representation" literally true rather than aspirational. A walk builds an
/// image; writing it out is `write(2)` of exactly these bytes; reading it back
/// is `mmap(2)` of exactly these bytes. There is no serialiser, no parse step,
/// and no second layout that could disagree with the first.
///
/// Two consequences worth stating, because they are the reasons for the shape:
///
/// - **Loading is free.** Mapping a 27 MB corpus measured at 0.27 ms, against
///   75 ms to materialise the same paths out of SQLite.
/// - **Two applications cost one copy.** macOS's unified buffer cache keys
///   pages by vnode, so Assist Ant and Galaxy mapping the same file share the
///   same physical pages.
public final class FileCorpusImage: @unchecked Sendable {

    /// Sections start on a 16 KB boundary.
    ///
    /// Not 4096. Apple Silicon pages are 16 KB, and a 4 KB-blocked format
    /// faults in four times what it needs on every touch. 16384 is a multiple
    /// of both, so an image written here is still correctly aligned on a 4 KB
    /// machine.
    static let sectionAlignment = 16 * 1024

    static let magic: UInt32 = 0x4746_5349  // "GFSI"
    static let version: UInt32 = 1

    /// Fixed-size prefix, before the first aligned section.
    struct Header {
        var magic: UInt32
        var version: UInt32
        var entryCount: UInt32
        var restartCount: UInt32
        var maxEntryLength: UInt32
        var rootByteCount: UInt32
        var blobByteCount: UInt64
        var blobOffset: UInt64
        var restartsOffset: UInt64
        var bagsOffset: UInt64
        var modifiedOffset: UInt64
        var directoryBitsOffset: UInt64
        var rootOffset: UInt64
        var totalBytes: UInt64
    }

    /// How the bytes are held, which is the only thing that differs between an
    /// image a walk produced and one a file supplied.
    enum Backing {
        case owned(UnsafeMutableRawPointer)
        case mapped(UnsafeMutableRawPointer)
    }

    let base: UnsafeRawPointer
    let byteCount: Int
    private let backing: Backing

    init(backing: Backing, byteCount: Int) {
        self.backing = backing
        self.byteCount = byteCount
        switch backing {
        case .owned(let pointer), .mapped(let pointer):
            base = UnsafeRawPointer(pointer)
        }
    }

    deinit {
        switch backing {
        case .owned(let pointer):
            pointer.deallocate()
        case .mapped(let pointer):
            munmap(pointer, byteCount)
        }
    }

    var header: Header {
        base.loadUnaligned(fromByteOffset: 0, as: Header.self)
    }

    var isValid: Bool {
        byteCount >= MemoryLayout<Header>.size
            && header.magic == Self.magic
            && header.version == Self.version
            && Int(header.totalBytes) == byteCount
    }

    /// Advise the kernel how these pages will be used.
    ///
    /// A filename index is random access by nature, so read-ahead clustering
    /// is work spent on pages the next keystroke will not want. The header and
    /// the restart table *are* wanted immediately, and macOS has no
    /// `MAP_POPULATE` — `MADV_WILLNEED` is the equivalent.
    func adviseUsagePattern() {
        guard case .mapped(let pointer) = backing else { return }
        madvise(pointer, byteCount, MADV_RANDOM)
        let warm = min(byteCount, Int(header.bagsOffset))
        if warm > 0 { madvise(pointer, warm, MADV_WILLNEED) }
    }

    // MARK: - Building

    /// Assemble an image from the parts a walk produced.
    static func build(
        blob: [UInt8],
        restarts: [UInt32],
        bags: [UInt64],
        modifiedDays: [UInt16],
        directoryBits: [UInt64],
        maxEntryLength: Int,
        entryCount: Int,
        root: String
    ) -> FileCorpusImage {
        let rootBytes = Array(root.utf8)
        func align(_ value: Int) -> Int {
            let alignment = sectionAlignment
            return (value + alignment - 1) / alignment * alignment
        }

        var cursor = align(MemoryLayout<Header>.size)
        let blobOffset = cursor
        cursor = align(cursor + blob.count)
        let restartsOffset = cursor
        cursor = align(cursor + restarts.count * 4)
        let bagsOffset = cursor
        cursor = align(cursor + bags.count * 8)
        let modifiedOffset = cursor
        cursor = align(cursor + modifiedDays.count * 2)
        let directoryBitsOffset = cursor
        cursor = align(cursor + directoryBits.count * 8)
        let rootOffset = cursor
        cursor = align(cursor + rootBytes.count)
        let total = max(cursor, sectionAlignment)

        let memory = UnsafeMutableRawPointer.allocate(
            byteCount: total, alignment: sectionAlignment
        )
        memory.initializeMemory(as: UInt8.self, repeating: 0, count: total)

        var header = Header(
            magic: magic, version: version,
            entryCount: UInt32(entryCount),
            restartCount: UInt32(restarts.count),
            maxEntryLength: UInt32(maxEntryLength),
            rootByteCount: UInt32(rootBytes.count),
            blobByteCount: UInt64(blob.count),
            blobOffset: UInt64(blobOffset),
            restartsOffset: UInt64(restartsOffset),
            bagsOffset: UInt64(bagsOffset),
            modifiedOffset: UInt64(modifiedOffset),
            directoryBitsOffset: UInt64(directoryBitsOffset),
            rootOffset: UInt64(rootOffset),
            totalBytes: UInt64(total)
        )
        Swift.withUnsafeBytes(of: &header) { bytes in
            memory.copyMemory(from: bytes.baseAddress!, byteCount: bytes.count)
        }
        blob.withUnsafeBytes {
            if $0.count > 0 {
                (memory + blobOffset).copyMemory(
                    from: $0.baseAddress!, byteCount: $0.count
                )
            }
        }
        restarts.withUnsafeBytes {
            if $0.count > 0 {
                (memory + restartsOffset).copyMemory(
                    from: $0.baseAddress!, byteCount: $0.count
                )
            }
        }
        bags.withUnsafeBytes {
            if $0.count > 0 {
                (memory + bagsOffset).copyMemory(
                    from: $0.baseAddress!, byteCount: $0.count
                )
            }
        }
        modifiedDays.withUnsafeBytes {
            if $0.count > 0 {
                (memory + modifiedOffset).copyMemory(
                    from: $0.baseAddress!, byteCount: $0.count
                )
            }
        }
        directoryBits.withUnsafeBytes {
            if $0.count > 0 {
                (memory + directoryBitsOffset).copyMemory(
                    from: $0.baseAddress!, byteCount: $0.count
                )
            }
        }
        rootBytes.withUnsafeBytes {
            if $0.count > 0 {
                (memory + rootOffset).copyMemory(
                    from: $0.baseAddress!, byteCount: $0.count
                )
            }
        }

        return FileCorpusImage(backing: .owned(memory), byteCount: total)
    }

    /// Map an image previously written to disk.
    ///
    /// `MAP_SHARED | PROT_READ`, so several processes mapping the same file
    /// share one set of physical pages, and nothing here can dirty the file.
    static func map(_ url: URL) -> FileCorpusImage? {
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }

        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_size > 0 else { return nil }
        let size = Int(info.st_size)

        guard
            let pointer = mmap(
                nil, size, PROT_READ, MAP_SHARED, descriptor, 0
            ), pointer != MAP_FAILED
        else { return nil }

        let image = FileCorpusImage(
            backing: .mapped(pointer), byteCount: size
        )
        guard image.isValid else { return nil }
        image.adviseUsagePattern()
        return image
    }

    /// The bytes, for a writer.
    func withUnsafeBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R)
        rethrows -> R
    {
        try body(UnsafeRawBufferPointer(start: base, count: byteCount))
    }
}
