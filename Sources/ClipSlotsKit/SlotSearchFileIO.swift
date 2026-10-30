import Foundation
import Darwin

/// Search consumes ordinary file bytes, never resource forks or extended
/// attributes. Keep those extra Foundation lookups off the whole-library scan.
enum SlotSearchFileIO {
    static func read(_ path: String, isCancelled: () -> Bool = { false },
                     onFailure: () -> Void = {}) -> Data? {
        guard !isCancelled() else { onFailure(); return nil }
        let descriptor = open(path, O_RDONLY | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else {
            if errno != ENOENT { onFailure() }
            return nil
        }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size >= 0, info.st_size <= ResourceBudget.shared.totalBytes else {
            onFailure(); return nil
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: min(256 * 1024, max(1, Int(info.st_size))))
        while data.count < info.st_size {
            guard !isCancelled() else { onFailure(); return nil }
            let remaining = Int(info.st_size) - data.count
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress, min(remaining, $0.count))
            }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { onFailure(); return nil }
            data.append(contentsOf: buffer.prefix(count))
        }
        var after = stat()
        var current = stat()
        func identity(_ value: stat) -> [Int64] {
            [Int64(value.st_dev), Int64(value.st_ino), Int64(value.st_mode), value.st_size,
             Int64(value.st_mtimespec.tv_sec), Int64(value.st_mtimespec.tv_nsec),
             Int64(value.st_ctimespec.tv_sec), Int64(value.st_ctimespec.tv_nsec)]
        }
        guard !isCancelled(), fstat(descriptor, &after) == 0, stat(path, &current) == 0,
              identity(info) == identity(after), identity(info) == identity(current) else {
            onFailure(); return nil
        }
        return data
    }

    static func names(_ path: String, isCancelled: () -> Bool = { false }) -> [String]? {
        guard !isCancelled() else { return nil }
        guard let directory = opendir(path) else { return nil }
        defer { closedir(directory) }
        var names: [String] = []
        while true {
            guard !isCancelled() else { return nil }
            errno = 0
            guard let entry = readdir(directory) else { return errno == 0 ? names : nil }
            let capacity = Int(entry.pointee.d_namlen) + 1
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: capacity) { String(cString: $0) }
            }
            if name != "." && name != ".." { names.append(name) }
        }
    }
}
