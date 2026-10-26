import Foundation
import Darwin

/// Search consumes ordinary file bytes, never resource forks or extended
/// attributes. Keep those extra Foundation lookups off the whole-library scan.
enum SlotSearchFileIO {
    static func read(_ path: String) -> Data? {
        let descriptor = open(path, O_RDONLY | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size >= 0, info.st_size < Int.max else { return nil }
        var data = Data(count: Int(info.st_size))
        let complete = data.withUnsafeMutableBytes { buffer -> Bool in
            var offset = 0
            while offset < buffer.count {
                guard let base = buffer.baseAddress else { return false }
                let count = Darwin.read(descriptor, base.advanced(by: offset), buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { return false }
                offset += count
            }
            return true
        }
        return complete ? data : nil
    }

    static func names(_ path: String) -> [String]? {
        guard let directory = opendir(path) else { return nil }
        defer { closedir(directory) }
        var names: [String] = []
        while true {
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
