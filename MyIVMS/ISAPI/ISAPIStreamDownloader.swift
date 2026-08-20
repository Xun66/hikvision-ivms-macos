import Foundation
import Network

final class ISAPIStreamDownloader {
    private let host: String
    private let port: Int
    private let credentials: Credentials
    private let queue = DispatchQueue(label: "my-ivms.isapi.stream-download")

    init(host: String, port: Int, credentials: Credentials) {
        self.host = host
        self.port = port
        self.credentials = credentials
    }

    func download(method: String,
                  path: String,
                  contentType: String?,
                  body: Data?,
                  destination: URL,
                  progress: ((Double?) -> Void)?) async throws {
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)

        let first = try await send(method: method,
                                   path: path,
                                   contentType: contentType,
                                   body: body,
                                   authorization: nil,
                                   destination: destination,
                                   progress: progress)
        if first.statusCode == 200 {
            progress?(1)
            return
        }

        guard first.statusCode == 401,
              let challenge = first.headers["www-authenticate"],
              var authenticator = HTTPAuthenticator(header: challenge,
                                                    username: credentials.username,
                                                    password: credentials.password) else {
            throw first.error
        }

        let authorization = authenticator.authorization(method: method, uri: path)
        let authorized = try await send(method: method,
                                        path: path,
                                        contentType: contentType,
                                        body: body,
                                        authorization: authorization,
                                        destination: destination,
                                        progress: progress)
        guard authorized.statusCode == 200 else {
            throw authorized.error
        }
        progress?(1)
    }

    private func send(method: String,
                      path: String,
                      contentType: String?,
                      body: Data?,
                      authorization: String?,
                      destination: URL,
                      progress: ((Double?) -> Void)?) async throws -> HTTPStreamResult {
        let request = HTTPStreamRequest()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let state = HTTPStreamState(destination: destination, progress: progress)
                let connection = NWConnection(host: NWEndpoint.Host(host),
                                              port: NWEndpoint.Port(rawValue: UInt16(port)) ?? 80,
                                              using: .tcp)
                request.attach(connection: connection, state: state, continuation: continuation)

                func receive() {
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
                        if let error {
                            request.finish(.failure(error))
                            return
                        }

                        if let data, !data.isEmpty {
                            do {
                                if let result = try state.consume(data) {
                                    request.finish(.success(result))
                                    return
                                }
                            } catch {
                                request.finish(.failure(error))
                                return
                            }
                        }

                        if isComplete {
                            do {
                                request.finish(.success(try state.complete()))
                            } catch {
                                request.finish(.failure(error))
                            }
                            return
                        }

                        receive()
                    }
                }

                let payload = Self.httpRequest(host: host,
                                               port: port,
                                               method: method,
                                               path: path,
                                               contentType: contentType,
                                               body: body,
                                               authorization: authorization)
                connection.stateUpdateHandler = { nwState in
                    switch nwState {
                    case .ready:
                        connection.send(content: payload, completion: .contentProcessed { error in
                            if let error {
                                request.finish(.failure(error))
                            } else {
                                receive()
                            }
                        })
                    case .failed(let error):
                        request.finish(.failure(error))
                    case .cancelled:
                        break
                    default:
                        break
                    }
                }
                connection.start(queue: queue)
            }
        } onCancel: {
            request.cancel()
        }
    }

    private static func httpRequest(host: String,
                                    port: Int,
                                    method: String,
                                    path: String,
                                    contentType: String?,
                                    body: Data?,
                                    authorization: String?) -> Data {
        let body = body ?? Data()
        var lines = [
            "\(method) \(path) HTTP/1.1",
            "Host: \(host):\(port)",
            "Connection: close",
            "Accept: */*",
            "Content-Length: \(body.count)"
        ]
        if let contentType {
            lines.append("Content-Type: \(contentType)")
        }
        if let authorization {
            lines.append("Authorization: \(authorization)")
        }

        var data = Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
        data.append(body)
        return data
    }
}

private final class HTTPStreamRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var connection: NWConnection?
    private var state: HTTPStreamState?
    private var continuation: CheckedContinuation<HTTPStreamResult, Error>?
    private var finished = false

    func attach(connection: NWConnection,
                state: HTTPStreamState,
                continuation: CheckedContinuation<HTTPStreamResult, Error>) {
        lock.lock()
        if finished {
            lock.unlock()
            connection.cancel()
            state.close()
            continuation.resume(throwing: CancellationError())
            return
        }
        self.connection = connection
        self.state = state
        self.continuation = continuation
        lock.unlock()
    }

    func finish(_ result: Result<HTTPStreamResult, Error>) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        let connection = connection
        let state = state
        let continuation = continuation
        self.connection = nil
        self.state = nil
        self.continuation = nil
        lock.unlock()

        connection?.cancel()
        state?.close()
        continuation?.resume(with: result)
    }

    func cancel() {
        finish(.failure(CancellationError()))
    }
}

private final class HTTPStreamState: @unchecked Sendable {
    private static let errorBodyLimit = 16 * 1024
    private static let headerLimit = 64 * 1024

    private let destination: URL
    private let progress: ((Double?) -> Void)?
    private let fileManager = FileManager.default
    private let partial: URL
    private var headerBuffer = Data()
    private var response: ParsedHTTPResponse?
    private var handle: FileHandle?
    private var expectedBodyBytes: Int64?
    private var writtenBodyBytes: Int64 = 0
    private var errorBody = Data()
    private var finished = false

    init(destination: URL, progress: ((Double?) -> Void)?) {
        self.destination = destination
        self.progress = progress
        self.partial = destination
            .deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).download")
    }

    func consume(_ data: Data) throws -> HTTPStreamResult? {
        guard let response else {
            headerBuffer.append(data)
            guard headerBuffer.count <= Self.headerLimit else {
                throw ISAPIError.httpStatusMessage(0, "HTTP response headers exceed 64 KB")
            }
            guard let headerEnd = headerBuffer.range(of: Data("\r\n\r\n".utf8)) else {
                return nil
            }

            let parsed = try Self.parse(headerBuffer[..<headerEnd.lowerBound])
            self.response = parsed
            let bodyStart = headerEnd.upperBound
            let body = headerBuffer[bodyStart...]
            headerBuffer.removeAll(keepingCapacity: false)

            if parsed.statusCode == 200 {
                try openPartialFile()
                try writeBody(Data(body))
                return try completionIfDownloadFinished()
            }

            captureErrorBody(Data(body))
            if parsed.statusCode == 401 || errorBody.count >= Self.errorBodyLimit {
                return HTTPStreamResult(response: parsed, errorBody: errorMessage)
            }
            return nil
        }

        if response.statusCode == 200 {
            try writeBody(data)
            return try completionIfDownloadFinished()
        }

        captureErrorBody(data)
        if errorBody.count >= Self.errorBodyLimit {
            return HTTPStreamResult(response: response, errorBody: errorMessage)
        }
        return nil
    }

    func complete() throws -> HTTPStreamResult {
        guard let response else { throw ISAPIError.noResponse }
        if response.statusCode == 200 {
            try finishFile()
        }
        return HTTPStreamResult(response: response, errorBody: errorMessage)
    }

    func close() {
        try? handle?.close()
        handle = nil
        if !finished {
            try? fileManager.removeItem(at: partial)
        }
    }

    private func openPartialFile() throws {
        guard handle == nil else { return }
        guard fileManager.createFile(atPath: partial.path, contents: nil) else {
            throw ISAPIError.cannotCreateFile(partial.path)
        }
        handle = try FileHandle(forWritingTo: partial)
        expectedBodyBytes = response?.contentLength
        progress?(expectedBodyBytes == nil ? nil : 0)
    }

    private func writeBody(_ data: Data) throws {
        guard !data.isEmpty else { return }
        try handle?.write(contentsOf: data)
        writtenBodyBytes += Int64(data.count)
        if let expectedBodyBytes, expectedBodyBytes > 0 {
            progress?(min(1, Double(writtenBodyBytes) / Double(expectedBodyBytes)))
        } else {
            progress?(nil)
        }
    }

    private func completionIfDownloadFinished() throws -> HTTPStreamResult? {
        guard let response else { throw ISAPIError.noResponse }
        guard let expectedBodyBytes, expectedBodyBytes > 0,
              writtenBodyBytes >= expectedBodyBytes else {
            return nil
        }
        try finishFile()
        return HTTPStreamResult(response: response, errorBody: "")
    }

    private func finishFile() throws {
        guard !finished else { return }
        try handle?.synchronize()
        try handle?.close()
        handle = nil
        try fileManager.moveItem(at: partial, to: destination)
        finished = true
        progress?(1)
    }

    private func captureErrorBody(_ data: Data) {
        guard !data.isEmpty, errorBody.count < Self.errorBodyLimit else { return }
        let available = Self.errorBodyLimit - errorBody.count
        errorBody.append(data.prefix(available))
    }

    private var errorMessage: String {
        String(data: errorBody, encoding: .utf8) ?? ""
    }

    private static func parse(_ headerData: Data.SubSequence) throws -> ParsedHTTPResponse {
        let text = String(decoding: headerData, as: UTF8.self)
        var lines = text.split(separator: "\r\n").map(String.init)
        guard !lines.isEmpty else { throw ISAPIError.noResponse }

        let statusLine = lines.removeFirst()
        let statusCode = Int(statusLine.split(separator: " ").dropFirst().first ?? "") ?? 0
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[String(key)] = value
        }
        return ParsedHTTPResponse(statusCode: statusCode, headers: headers)
    }
}

private struct ParsedHTTPResponse {
    var statusCode: Int
    var headers: [String: String]

    var contentLength: Int64? {
        guard let value = headers["content-length"],
              let count = Int64(value), count >= 0 else {
            return nil
        }
        return count
    }
}

private struct HTTPStreamResult {
    let response: ParsedHTTPResponse
    let errorBody: String

    var statusCode: Int { response.statusCode }
    var headers: [String: String] { response.headers }

    var error: ISAPIError {
        errorBody.isEmpty ? .httpStatus(statusCode) : .httpStatusMessage(statusCode, errorBody)
    }
}
