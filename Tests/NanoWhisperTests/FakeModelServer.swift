import Foundation
import Network
import os

/// A minimal HTTP server on 127.0.0.1 that answers like the model server, for download tests.
/// No test reaches the real server.
final class FakeModelServer: Sendable {
    struct Request: Sendable {
        let method: String
        let path: String
        /// Header names in lower case.
        let headers: [String: String]
    }

    struct Response: Sendable {
        var headers: [String: String] = [:]
        var body = Data()

        static func json(_ object: Any) -> Response {
            Response(
                headers: ["Content-Type": "application/json"],
                body: (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
            )
        }
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "FakeModelServer")
    private let log = OSAllocatedUnfairLock(initialState: [Request]())
    private let respond: @Sendable (Request) -> Response

    var requests: [Request] { log.withLock { $0 } }

    var address: String { "http://127.0.0.1:\(listener.port?.rawValue ?? 0)" }

    /// - Parameter respond: called once per request.
    init(respond: @escaping @Sendable (Request) -> Response) async throws {
        self.respond = respond
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] in self?.serve($0) }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let pending = OSAllocatedUnfairLock(initialState: Optional(continuation))
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: pending.withLock { $0.take() }?.resume()
                case .failed(let error): pending.withLock { $0.take() }?.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    deinit { listener.cancel() }

    func stop() { listener.cancel() }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return connection.cancel() }
            let buffer = buffer + (data ?? Data())
            // Requests have no body.
            guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if isComplete || error != nil { connection.cancel() } else { self.receive(on: connection, buffer: buffer) }
                return
            }
            guard let request = Self.parse(buffer[..<end.lowerBound]) else { return connection.cancel() }
            self.log.withLock { $0.append(request) }
            let response = self.respond(request)
            var head = "HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Length: \(response.body.count)\r\n"
            for (name, value) in response.headers { head += "\(name): \(value)\r\n" }
            let body = request.method == "HEAD" ? Data() : response.body
            connection.send(content: Data((head + "\r\n").utf8) + body, completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }

    private static func parse(_ head: Data) -> Request? {
        let lines = String(decoding: head, as: UTF8.self).components(separatedBy: "\r\n")
        let start = lines[0].split(separator: " ")
        guard start.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        return Request(method: String(start[0]), path: String(start[1]), headers: headers)
    }
}
