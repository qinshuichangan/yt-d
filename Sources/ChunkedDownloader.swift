import Foundation

/// 分段下载：按范围（Range）一段一段地请求，边收边写进文件，进度和速度能实时更新。
/// 线程数大于 1 时，会开几条独立的连接同时下载不同的段，适合抖音这种单条连接被限速的情况。
enum ChunkedDownloader {
    static let threadsKey = "downloadThreads"
    /// 旧版本的「多线程下载」开关（开着的话，升级后默认 4 线程）
    private static let oldMultiThreadKey = "multiThreadDownload"
    static let maxThreads = 64

    /// 设置里选的线程数（1～64）
    static var threadCount: Int {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: threadsKey) == nil {
            return defaults.bool(forKey: oldMultiThreadKey) ? 4 : 1
        }
        return min(max(defaults.integer(forKey: threadsKey), 1), maxThreads)
    }

    /// 单线程时每段的大小（YouTube 一次请求太大会被限速）
    static let chunkSize: Int64 = 5 * 1024 * 1024
    /// 多线程时每段最大、最小的大小（线程多时自动切小，让每条连接都有活干）
    static let parallelChunkSize: Int64 = 2 * 1024 * 1024
    static let minParallelChunkSize: Int64 = 256 * 1024
    /// 多线程时先下一小段，拿到文件总大小
    static let probeSize: Int64 = 512 * 1024
    /// 每一段失败后最多重试几次
    static let maxRetries = 3

    enum Failure: LocalizedError {
        case http(Int)
        case incomplete
        case noRangeSupport
        var errorDescription: String? {
            switch self {
            case .http(let code):
                switch code {
                case 403: return "网站拒绝了下载（HTTP 403），可能是链接过期了，重新解析再试"
                case 404: return "文件不存在（HTTP 404），重新解析再试"
                case 416: return "文件是空的（HTTP 416）"
                default: return "服务器返回错误（HTTP \(code)）"
                }
            case .incomplete: return "文件没有下载完整，请重试"
            case .noRangeSupport: return "服务器不支持分段下载，请关掉「多线程下载」再试"
            }
        }
    }

    static func download(
        from url: URL,
        to destination: URL,
        headers: [String: String] = [:],
        progress: @escaping @Sendable (_ done: Int64, _ total: Int64?) -> Void
    ) async throws {
        let fm = FileManager.default
        try? fm.removeItem(at: destination)
        fm.createFile(atPath: destination.path, contents: nil)
        let file = try SharedFile(url: destination)
        defer { file.close() }

        let counter = ProgressCounter(report: progress)
        let threads = threadCount
        let parallel = threads > 1
        // 每条连接各用一个独立的 URLSession，保证真的是几条不同的网络连接
        var connections = [Connection(headers: headers)]
        defer { connections.forEach { $0.close() } }

        // 第一段：顺便拿到文件总大小和跳转后的真实地址
        let firstLength = parallel ? probeSize : chunkSize
        let first = try await withRetry {
            try await connections[0].fetch(url, start: 0, end: firstLength - 1, allowFull: true,
                                           file: file, counter: counter)
        }

        switch first.status {
        case 206:
            break
        case 200:
            // 服务器忽略了 Range，这一次已经把整个文件下完了
            counter.flush()
            if let total = first.total, first.received < total { throw Failure.incomplete }
            return
        default:
            // 403 等：网站拒绝了这次下载（以前这里没报错，会留下一个空文件）
            throw Failure.http(first.status)
        }

        let current = first.finalURL ?? url

        guard let total = first.total else {
            // 不知道总大小：只能一段一段往下要，直到拿到的比要的少
            try await sequentialUnknownSize(connections[0], url: current, offset: first.received,
                                            lastLength: first.received, requested: firstLength,
                                            file: file, counter: counter)
            counter.flush()
            return
        }

        counter.setTotal(total)
        if first.received >= total {
            counter.flush()
            return
        }
        try file.reserve(total)

        // 剩下的部分切成若干段，几条连接各自领取
        let remaining = total - first.received
        let pieceSize = parallel
            ? min(parallelChunkSize, max(minParallelChunkSize, remaining / Int64(threads * 2)))
            : chunkSize
        var pieces: [(Int64, Int64)] = []
        var position = first.received
        while position < total {
            let end = min(position + pieceSize, total) - 1
            pieces.append((position, end))
            position = end + 1
        }
        let queue = PieceQueue(pieces)
        // 段数比线程少时，多开的连接也没活干
        let needed = min(threads, pieces.count)
        while connections.count < needed {
            connections.append(Connection(headers: headers))
        }
        let workers = connections

        try await withThrowingTaskGroup(of: Void.self) { group in
            for connection in workers {
                group.addTask {
                    while let piece = queue.next() {
                        try await downloadRange(connection, url: current, start: piece.0, end: piece.1,
                                                file: file, counter: counter)
                    }
                }
            }
            try await group.waitForAll()
        }

        counter.flush()
        if counter.done < total { throw Failure.incomplete }
    }

    // MARK: 下载一段（失败自动重试，断了就从断的地方接着下）

    private static func downloadRange(
        _ connection: Connection, url: URL, start: Int64, end: Int64,
        file: SharedFile, counter: ProgressCounter
    ) async throws {
        var position = start
        var failures = 0
        while position <= end {
            try Task.checkCancellation()
            do {
                let result = try await connection.fetch(url, start: position, end: end, allowFull: false,
                                                        file: file, counter: counter)
                if result.status == 200 { throw Failure.noRangeSupport }
                guard result.status == 206 else { throw Failure.http(result.status) }
                guard result.received > 0 else { throw Failure.incomplete }
                position += result.received
                failures = 0
            } catch let partial as PartialFailure {
                position += partial.received
                failures = partial.received > 0 ? 0 : failures + 1
                if failures > maxRetries { throw partial.underlying }
                try await Task.sleep(nanoseconds: 500_000_000)
            } catch {
                if error is CancellationError { throw error }
                if let failure = error as? Failure, case .noRangeSupport = failure { throw error }
                failures += 1
                if failures > maxRetries { throw error }
                try await Task.sleep(nanoseconds: UInt64(failures) * 700_000_000)
            }
        }
    }

    private static func sequentialUnknownSize(
        _ connection: Connection, url: URL, offset start: Int64, lastLength: Int64, requested: Int64,
        file: SharedFile, counter: ProgressCounter
    ) async throws {
        var offset = start
        var lastReceived = lastLength
        var lastRequested = requested
        while lastReceived >= lastRequested {
            try Task.checkCancellation()
            let from = offset
            let result = try await withRetry {
                try await connection.fetch(url, start: from, end: from + chunkSize - 1, allowFull: false,
                                           file: file, counter: counter)
            }
            if result.status == 416 { break }
            guard result.status == 206 else { throw Failure.http(result.status) }
            if result.received == 0 { break }
            offset += result.received
            lastReceived = result.received
            lastRequested = chunkSize
        }
    }

    /// 整个请求失败时重试（只用在第一段和总大小未知的情况）
    private static func withRetry(_ body: () async throws -> Connection.Result) async throws -> Connection.Result {
        var failures = 0
        while true {
            do {
                return try await body()
            } catch {
                if error is CancellationError { throw error }
                let underlying = (error as? PartialFailure)?.underlying ?? error
                // 已经收到一部分数据时不能简单重来，直接报错
                if let partial = error as? PartialFailure, partial.received > 0 { throw underlying }
                failures += 1
                if failures > maxRetries { throw underlying }
                try await Task.sleep(nanoseconds: UInt64(failures) * 700_000_000)
            }
        }
    }
}

// MARK: - 一条连接

/// 中途断开时，带上已经收到的字节数，方便接着下
private struct PartialFailure: Error {
    let received: Int64
    let underlying: Error
}

private final class Connection: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    struct Result {
        let status: Int
        let total: Int64?
        let finalURL: URL?
        let received: Int64
    }

    private final class Job {
        let start: Int64
        let limit: Int64?
        let allowFull: Bool
        let file: SharedFile
        let counter: ProgressCounter
        var continuation: CheckedContinuation<Result, Error>?
        var status = 0
        var total: Int64?
        var finalURL: URL?
        var received: Int64 = 0
        var inspected = false
        var rejected = false
        var finishedEarly = false
        var writeError: Error?

        init(start: Int64, limit: Int64?, allowFull: Bool, file: SharedFile, counter: ProgressCounter) {
            self.start = start
            self.limit = limit
            self.allowFull = allowFull
            self.file = file
            self.counter = counter
        }

        var result: Result { Result(status: status, total: total, finalURL: finalURL, received: received) }
    }

    private let headers: [String: String]
    private var session: URLSession!
    private let lock = NSLock()
    private var jobs: [Int: Job] = [:]

    init(headers: [String: String]) {
        self.headers = headers
        super.init()
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        session = URLSession(configuration: config, delegate: self, delegateQueue: queue)
    }

    func close() {
        session.invalidateAndCancel()
    }

    /// 请求 [start, end] 这一段，收到的数据直接写进文件对应的位置
    func fetch(
        _ url: URL, start: Int64, end: Int64?, allowFull: Bool,
        file: SharedFile, counter: ProgressCounter
    ) async throws -> Result {
        var request = URLRequest(url: url)
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        request.setValue("bytes=\(start)-\(end.map(String.init) ?? "")", forHTTPHeaderField: "Range")
        request.timeoutInterval = 30

        let task = session.dataTask(with: request)
        let job = Job(start: start, limit: end.map { $0 - start + 1 }, allowFull: allowFull,
                      file: file, counter: counter)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.lock.lock()
                job.continuation = continuation
                self.jobs[task.taskIdentifier] = job
                self.lock.unlock()
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    private func job(for task: URLSessionTask) -> Job? {
        lock.lock()
        defer { lock.unlock() }
        return jobs[task.taskIdentifier]
    }

    /// 看一下响应头：状态码、文件总大小、跳转后的地址
    private func inspect(_ job: Job, _ response: URLResponse?) {
        guard !job.inspected else { return }
        job.inspected = true
        let http = response as? HTTPURLResponse
        job.status = http?.statusCode ?? 0
        job.finalURL = http?.url
        if let range = http?.value(forHTTPHeaderField: "Content-Range"),
           let last = range.split(separator: "/").last,
           let value = Int64(last) {
            job.total = value
        } else if job.status == 200, let length = response?.expectedContentLength, length > 0 {
            job.total = length
        }

        let ok = job.status == 206 || (job.status == 200 && job.allowFull)
        if ok {
            if let total = job.total { job.counter.setTotal(total) }
        } else {
            // 错误页面、416 等：不写进文件，交给调用方看状态码处理
            job.rejected = true
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let job = job(for: dataTask), !job.finishedEarly, !job.rejected, job.writeError == nil else { return }
        inspect(job, dataTask.response)
        if job.rejected {
            dataTask.cancel()
            return
        }
        var piece = data
        if let limit = job.limit {
            let room = limit - job.received
            if room <= 0 {
                job.finishedEarly = true
                dataTask.cancel()
                return
            }
            if Int64(piece.count) > room { piece = piece.prefix(Int(room)) }
        }
        do {
            try job.file.write(piece, at: job.start + job.received)
        } catch {
            job.writeError = error
            dataTask.cancel()
            return
        }
        job.received += Int64(piece.count)
        job.counter.add(Int64(piece.count))
        if let limit = job.limit, job.received >= limit, Int64(data.count) > Int64(piece.count) {
            // 服务器给多了，要的已经够了
            job.finishedEarly = true
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let job = jobs.removeValue(forKey: task.taskIdentifier)
        lock.unlock()
        guard let job, let continuation = job.continuation else { return }
        if error == nil { inspect(job, task.response) }

        if let writeError = job.writeError {
            continuation.resume(throwing: writeError)
        } else if job.rejected || job.finishedEarly {
            continuation.resume(returning: job.result)
        } else if let error {
            if (error as? URLError)?.code == .cancelled {
                continuation.resume(throwing: CancellationError())
            } else {
                continuation.resume(throwing: PartialFailure(received: job.received, underlying: error))
            }
        } else {
            continuation.resume(returning: job.result)
        }
    }
}

// MARK: - 小工具

/// 几条连接同时往一个文件的不同位置写
private final class SharedFile: @unchecked Sendable {
    private let handle: FileHandle
    private let lock = NSLock()

    init(url: URL) throws {
        handle = try FileHandle(forWritingTo: url)
    }

    func write(_ data: Data, at offset: Int64) throws {
        lock.lock()
        defer { lock.unlock() }
        try handle.seek(toOffset: UInt64(offset))
        try handle.write(contentsOf: data)
    }

    /// 先把文件撑到完整大小
    func reserve(_ size: Int64) throws {
        lock.lock()
        defer { lock.unlock() }
        try handle.truncate(atOffset: UInt64(size))
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        try? handle.close()
    }
}

/// 汇总所有连接的进度，最多每 0.2 秒报告一次
private final class ProgressCounter: @unchecked Sendable {
    private let lock = NSLock()
    private let report: @Sendable (Int64, Int64?) -> Void
    private var bytes: Int64 = 0
    private var total: Int64?
    private var lastReport: TimeInterval = 0

    init(report: @escaping @Sendable (Int64, Int64?) -> Void) {
        self.report = report
    }

    var done: Int64 {
        lock.lock()
        defer { lock.unlock() }
        return bytes
    }

    func setTotal(_ value: Int64) {
        lock.lock()
        total = value
        lock.unlock()
    }

    func add(_ count: Int64) {
        lock.lock()
        bytes += count
        let now = ProcessInfo.processInfo.systemUptime
        let shouldReport = now - lastReport >= 0.2
        if shouldReport { lastReport = now }
        let snapshot = (bytes, total)
        lock.unlock()
        if shouldReport { report(snapshot.0, snapshot.1) }
    }

    func flush() {
        lock.lock()
        let snapshot = (bytes, total)
        lock.unlock()
        report(snapshot.0, snapshot.1)
    }
}

/// 待下载的段，几条连接轮流领取
private final class PieceQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var pieces: [(Int64, Int64)]

    init(_ pieces: [(Int64, Int64)]) {
        self.pieces = pieces.reversed()
    }

    func next() -> (Int64, Int64)? {
        lock.lock()
        defer { lock.unlock() }
        return pieces.popLast()
    }
}
