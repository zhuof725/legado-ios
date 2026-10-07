import Foundation
import Network

/// Test-only wire observer. No URLProtocol, cookie storage, or header injection.
/// All listener/connection callbacks run on a dedicated queue, never the thread
/// blocked by the synchronous JavaScript HTTP bridge. Only synthetic fixtures.
final class CookieLoopbackServer: @unchecked Sendable {
    enum Failure: String, Error {
        case startup, startupTimeout, acceptTimeout, listener, readTimeout
        case read, malformedRequest, oversizedRequest, unexpectedRequest, write
    }

    private final class Client {
        let connection: NWConnection
        var bytes = Data()
        var deadline: DispatchWorkItem?
        init(_ connection: NWConnection) { self.connection = connection }
    }

    private let queue = DispatchQueue(label: "SourceTest.CookieLoopbackServer")
    private let ready = DispatchSemaphore(value: 0)
    // Every mutable property below is confined to queue.
    private var listener: NWListener?
    private var clients: [UUID: Client] = [:]
    private var observations: [String: Bool] = [:]
    private var firstFailure: Failure?
    private var port: UInt16?
    private var stopped = false
    private var lifetime: DispatchWorkItem?

    /// Bounded startup; binds only IPv4 loopback with an OS-assigned port.
    /// The 20-second total listener deadline bounds idle accept as well as the
    /// complete three-request fixture. Each connection has a 4-second deadline
    /// covering header receive AND response send (not reset by partial reads).
    func start() throws -> String {
        do {
            try queue.sync {
                // Cancellation can stop the fixture before this queue block runs.
                // Never create a listener after the teardown barrier has passed.
                guard !stopped, listener == nil else { throw Failure.startup }
                let parameters = NWParameters.tcp
                parameters.requiredLocalEndpoint = .hostPort(
                    host: NWEndpoint.Host("127.0.0.1"), port: .any)
                let server = try NWListener(using: parameters)
                listener = server
                server.stateUpdateHandler = { [weak self] state in
                    guard let self = self, !self.stopped else { return }
                    switch state {
                    case .ready:
                        self.port = server.port?.rawValue
                        self.ready.signal()
                    case .failed:
                        self.fail(.listener)
                        self.ready.signal()
                    default: break
                    }
                }
                server.newConnectionHandler = { [weak self] connection in
                    guard let self = self, !self.stopped else {
                        connection.cancel()
                        return
                    }
                    self.accept(connection)
                }
                let deadline = DispatchWorkItem { [weak self] in
                    guard let self = self, !self.stopped else { return }
                    self.fail(.acceptTimeout)
                    self.stopOnQueue()
                }
                lifetime = deadline
                queue.asyncAfter(deadline: .now() + 20, execute: deadline)
                server.start(queue: queue)
            }
        } catch {
            stop()
            throw Failure.startup
        }
        guard ready.wait(timeout: .now() + 3) == .success else {
            stop()
            throw Failure.startupTimeout
        }
        let selected: UInt16? = queue.sync {
            guard firstFailure == nil, !stopped else { return nil }
            return port
        }
        guard let selected = selected, selected != 0 else {
            stop()
            throw Failure.startup
        }
        return "http://127.0.0.1:\(selected)"
    }

    /// Boolean wire evidence only; absent observation is NOT an absent cookie.
    func received(_ phase: String) -> Bool? {
        queue.sync { observations[phase] }
    }

    var failure: Failure? { queue.sync { firstFailure } }

    /// Idempotent synchronous teardown barrier. Safe from a cancellation handler;
    /// callbacks never invoke this public method from their own queue.
    func stop() { queue.sync { stopOnQueue() } }

    private func stopOnQueue() {
        guard !stopped else { return }
        stopped = true
        // Release a concurrent startup waiter immediately on cancellation.
        // start() rechecks stopped on this queue before returning an origin.
        ready.signal()
        lifetime?.cancel()
        lifetime = nil
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
        for id in Array(clients.keys) { close(id) }
    }

    private func fail(_ failure: Failure) {
        if firstFailure == nil { firstFailure = failure }
    }

    private func close(_ id: UUID) {
        guard let client = clients.removeValue(forKey: id) else { return }
        client.deadline?.cancel()
        client.deadline = nil
        client.connection.stateUpdateHandler = nil
        client.connection.cancel()
        client.bytes.removeAll(keepingCapacity: false)
    }

    private func accept(_ connection: NWConnection) {
        // Bound memory and reject unrelated or excess loopback connections.
        guard clients.count < 3 else {
            fail(.unexpectedRequest)
            connection.cancel()
            return
        }
        let id = UUID()
        let client = Client(connection)
        clients[id] = client
        let deadline = DispatchWorkItem { [weak self] in
            guard let self = self, self.clients[id] != nil else { return }
            self.fail(.readTimeout)
            self.close(id)
        }
        client.deadline = deadline
        queue.asyncAfter(deadline: .now() + 4, execute: deadline)
        connection.stateUpdateHandler = { [weak self] state in
            guard let self = self, self.clients[id] != nil else { return }
            if case .failed = state {
                self.fail(.read)
                self.close(id)
            }
        }
        connection.start(queue: queue)
        receive(id)
    }

    private func receive(_ id: UUID) {
        guard let client = clients[id], !stopped else { return }
        client.connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) {
            [weak self] data, _, complete, error in
            guard let self = self, let client = self.clients[id], !self.stopped else { return }
            if let data = data { client.bytes.append(data) }
            guard client.bytes.count <= 16384 else {
                self.fail(.oversizedRequest)
                self.close(id)
                return
            }
            if let end = client.bytes.range(of: Data([13, 10, 13, 10])) {
                self.respond(id, header: Data(client.bytes[..<end.lowerBound]))
            } else if error != nil || complete {
                self.fail(.read)
                self.close(id)
            } else {
                self.receive(id)
            }
        }
    }

    private func respond(_ id: UUID, header: Data) {
        guard let client = clients[id],
              let text = String(data: header, encoding: .utf8) else {
            fail(.malformedRequest)
            close(id)
            return
        }
        let lines = text.components(separatedBy: "\r\n")
        let request = (lines.first ?? "").split(separator: " ")
        guard request.count == 3, request[0] == "GET",
              ["/write", "/isolated", "/removed"].contains(String(request[1])),
              request[2] == "HTTP/1.1" else {
            fail(.unexpectedRequest)
            close(id)
            return
        }
        let phase = String(request[1])
        guard observations[phase] == nil else {
            fail(.unexpectedRequest)
            close(id)
            return
        }
        // Parse independently of SourceCookieStore: inspect actual HTTP bytes,
        // tolerate header-name casing and pair order; never return/log raw data.
        var matched = false
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else {
                fail(.malformedRequest)
                close(id)
                return
            }
            guard line[..<colon].lowercased() == "cookie" else { continue }
            for pair in line[line.index(after: colon)...].split(separator: ";") {
                let fields = pair.split(separator: "=", maxSplits: 1,
                                        omittingEmptySubsequences: false)
                if fields.count == 2,
                   fields[0].trimmingCharacters(in: .whitespaces) == "transport",
                   fields[1].trimmingCharacters(in: .whitespaces) == "fixture" {
                    matched = true
                }
            }
        }
        observations[phase] = matched
        client.bytes.removeAll(keepingCapacity: false)
        let body = matched ? "matched" : "absent"
        let response = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: \(body.utf8.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n\(body)"
        client.connection.send(content: Data(response.utf8), completion: .contentProcessed {
            [weak self] error in
            guard let self = self, self.clients[id] != nil else { return }
            if error != nil { self.fail(.write) }
            self.close(id)
        })
    }
}
