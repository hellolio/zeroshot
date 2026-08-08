import Foundation

/// 统一日志（写文件 + stderr，便于诊断）
func ZSLog(_ message: String) {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss.SSS"
    let line = "[zeroshot \(formatter.string(from: Date()))] \(message)\n"
    FileHandle.standardError.write(line.data(using: .utf8)!)

    guard let data = line.data(using: .utf8) else { return }
    let url = URL(fileURLWithPath: "/tmp/zeroshot.log")
    if let handle = try? FileHandle(forWritingTo: url) {
        handle.seekToEndOfFile()
        handle.write(data)
        try? handle.close()
    } else {
        try? data.write(to: url, options: .atomic)
    }
}