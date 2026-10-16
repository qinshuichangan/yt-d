import Foundation

/// 分块下载（每次请求一小段），比一次性下载更不容易被限速，也方便显示进度。
enum ChunkedDownloader {
    static let chunkSize: Int64 = 5 * 1024 * 1024

    enum Failure: LocalizedError {
        case http(Int)
        var errorDescription: String? {
            switch self {
            case .http(let code): return "服务器返回错误（HTTP \(code)）"
            }
        }
    }

    static func download(
        from url: URL,
        to destination: URL,
        progress: @escaping @Sendable (_ done: Int64, _ total: Int64?) -> Void
    ) async throws {
        let fm = FileManager.default
        try? fm.removeItem(at: destination)
        fm.createFile(atPath: destination.path, contents: nil)
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }

        var offset: Int64 = 0
        var total: Int64?

        while true {
            try Task.checkCancellation()

            var request = URLRequest(url: url)
            request.setValue("bytes=\(offset)-\(offset + chunkSize - 1)", forHTTPHeaderField: "Range")
            request.timeoutInterval = 60

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw URLError(.badServerResponse)
            }
            if http.statusCode == 416 { break }  // 已经到文件末尾
            guard http.statusCode == 200 || http.statusCode == 206 else {
                throw Failure.http(http.statusCode)
            }

            if total == nil,
               let range = http.value(forHTTPHeaderField: "Content-Range"),
               let last = range.split(separator: "/").last,
               let value = Int64(last) {
                total = value
            }

            try handle.write(contentsOf: data)
            offset += Int64(data.count)
            progress(offset, total)

            if http.statusCode == 200 { break }          // 服务器忽略了 Range，已拿到完整文件
            if Int64(data.count) < chunkSize { break }   // 最后一块
            if let total, offset >= total { break }
        }
    }
}
