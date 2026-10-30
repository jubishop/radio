import Foundation

/// Keeps every `.log` file in `directory` under about `limit` bytes. A log at
/// the limit is copied to its name plus `.0`, replacing the previous copy,
/// then emptied in place. launchd opens each agent's log for appending, and
/// `radio serve` holds its log open as long as it runs, so a renamed log
/// would keep growing; emptied in place, the next line lands at its start.
/// A line written while the log is being copied can be lost. Returns the
/// names of the logs rotated.
@discardableResult
public func rotateLogs(in directory: URL, limit: Int = 1_000_000) throws -> [String] {
    let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey]
    let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys))
    var rotated: [String] = []
    for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where file.pathExtension == "log" {
        let values = try file.resourceValues(forKeys: keys)
        guard values.isRegularFile == true, let size = values.fileSize, size >= limit else { continue }
        try Data(contentsOf: file).write(to: file.appendingPathExtension("0"), options: .atomic)
        guard truncate(file.path, 0) == 0 else {
            throw RadioError("Can't empty \(file.path): \(String(cString: strerror(errno)))")
        }
        rotated.append(file.lastPathComponent)
    }
    return rotated
}
