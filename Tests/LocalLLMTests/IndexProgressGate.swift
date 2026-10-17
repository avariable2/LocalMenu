import Foundation

final class IndexProgressGate: @unchecked Sendable {
    private let condition = NSCondition()
    private let ready: AsyncStream<Void>.Continuation
    private var released = false
    private var entered = false

    init(ready: AsyncStream<Void>.Continuation) { self.ready = ready }

    func blockOnText(_ message: String) {
        guard message.contains(" · texte") else { return }
        condition.lock()
        defer { condition.unlock() }
        guard !entered else { return }
        entered = true
        ready.yield(())
        while !released { condition.wait() }
    }

    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }
}
