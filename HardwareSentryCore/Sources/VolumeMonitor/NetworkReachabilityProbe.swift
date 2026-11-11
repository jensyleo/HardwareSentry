import Foundation
import Network

/// Asks whether a server is answering, without touching the volume it serves.
///
/// Asking the mounted volume itself — listing it, reading its free space — is exactly what
/// hangs when its server has gone: macOS keeps the share mounted and every call into it
/// waits. A connection to the server's own port has no such problem and gives up when told.
public protocol NetworkReachabilityProbe: Sendable {
    func isReachable(host: String, port: UInt16, timeout: Duration) async -> Bool
}

/// Whether a TCP connection to the server's port is accepted within the timeout.
public struct TCPReachabilityProbe: NetworkReachabilityProbe {
    public init() {}

    public func isReachable(host: String, port: UInt16, timeout: Duration) async -> Bool {
        guard let port = NWEndpoint.Port(rawValue: port) else { return false }
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let gate = OneShot(continuation)
            let connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp)
            gate.onFinish { connection.cancel() }

            connection.stateUpdateHandler = { state in
                switch state {
                // `waiting` is the system saying there is no way to the server right now —
                // no route, or the port refused — which for this question is the answer.
                case .ready: gate.finish(true)
                case .waiting, .failed, .cancelled: gate.finish(false)
                default: break
                }
            }
            connection.start(queue: .global(qos: .utility))

            let seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + seconds) { gate.finish(false) }
        }
    }
}

/// Resumes a continuation exactly once, whichever of the connection and the timer gets
/// there first, and runs a cleanup afterwards.
private final class OneShot: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?
    private var cleanup: (@Sendable () -> Void)?

    init(_ continuation: CheckedContinuation<Bool, Never>) {
        self.continuation = continuation
    }

    func onFinish(_ cleanup: @escaping @Sendable () -> Void) {
        lock.lock()
        let alreadyFinished = continuation == nil
        if !alreadyFinished { self.cleanup = cleanup }
        lock.unlock()
        if alreadyFinished { cleanup() }
    }

    func finish(_ value: Bool) {
        lock.lock()
        let pending = continuation
        continuation = nil
        let after = cleanup
        cleanup = nil
        lock.unlock()
        pending?.resume(returning: value)
        after?()
    }
}
