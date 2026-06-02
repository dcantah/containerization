//===----------------------------------------------------------------------===//
// Copyright © 2026 Apple Inc. and the Containerization project authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//   https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//===----------------------------------------------------------------------===//

#if os(Linux)

import ContainerizationError
import ContainerizationOS
import Foundation
import Logging
import Synchronization

/// Relays a process's standard streams to the host over vsock.
///
/// The guest binds a vsock listener per stream and the host dials in. The
/// listeners are kept open and accept is driven off the shared epoll loop, so
/// the host can reconnect (for example after the VM is saved and restored)
/// without spawning a thread per stream. The relay between a stream's pipe and
/// the vsock connection is rebuilt each time the host (re)connects.
///
/// The pre-exec handshake (stdio connected before the process starts) is
/// enforced on the host: it only starts the process once its dials succeed.
final class StandardIO: ManagedProcess.IO & Sendable {
    private struct State {
        // Pipes bridging the child process and the relays. The parent-side end
        // of each pipe persists across reconnections; the child-side end is
        // closed after exec.
        var stdinPipe: Pipe?
        var stdoutPipe: Pipe?
        var stderrPipe: Pipe?

        // Listeners stay open for the lifetime of the process so the host can
        // reconnect.
        var stdinListener: Socket?
        var stdoutListener: Socket?
        var stderrListener: Socket?

        // The relay for the currently connected host, replaced on reconnect.
        var stdin: IOPair?
        var stdout: IOPair?
        var stderr: IOPair?
    }

    private let log: Logger?
    private let hostStdio: HostStdio
    private let state: Mutex<State>

    init(
        stdio: HostStdio,
        log: Logger?
    ) {
        self.hostStdio = stdio
        self.log = log
        self.state = Mutex(State())
    }

    // NOP
    func attach(pid: Int32, fd: Int32) throws {}

    func start(process: inout Command) throws {
        try self.state.withLock {
            if let stdinPort = self.hostStdio.stdin {
                let inPipe = Pipe()
                process.stdin = inPipe.fileHandleForReading
                $0.stdinPipe = inPipe

                let listener = try VsockStdio.bind(port: stdinPort)
                $0.stdinListener = listener
                try self.registerStdinAccept(listener: listener, pipe: inPipe)
            }

            if let stdoutPort = self.hostStdio.stdout {
                let outPipe = Pipe()
                process.stdout = outPipe.fileHandleForWriting
                $0.stdoutPipe = outPipe

                let listener = try VsockStdio.bind(port: stdoutPort)
                $0.stdoutListener = listener
                try self.registerOutputAccept(
                    listener: listener,
                    pipe: outPipe,
                    reason: "StandardIO stdout",
                    store: { $0.stdout = $1 },
                    current: { $0.stdout }
                )
            }

            if let stderrPort = self.hostStdio.stderr {
                let errPipe = Pipe()
                process.stderr = errPipe.fileHandleForWriting
                $0.stderrPipe = errPipe

                let listener = try VsockStdio.bind(port: stderrPort)
                $0.stderrListener = listener
                try self.registerOutputAccept(
                    listener: listener,
                    pipe: errPipe,
                    reason: "StandardIO stderr",
                    store: { $0.stderr = $1 },
                    current: { $0.stderr }
                )
            }
        }
    }

    /// Register the stdin listener with the shared epoll loop. On each accepted
    /// connection the relay (vsock -> pipe write end) is rebuilt. The pipe end
    /// is unowned so tearing down the relay never closes the child's stdin.
    private func registerStdinAccept(listener: Socket, pipe: Pipe) throws {
        try ProcessSupervisor.default.registerFd(listener.fileDescriptor, mask: [.input]) { [weak self] _ in
            guard let self else { return }
            do {
                let conn = try listener.accept(closeOnDeinit: false)
                self.state.withLock { state in
                    state.stdin?.close()
                    let pair = IOPair(
                        readFrom: conn,
                        writeTo: UnownedIOCloser(pipe.fileHandleForWriting),
                        reason: "StandardIO stdin",
                        logger: self.log
                    )
                    state.stdin = pair
                    do {
                        try pair.relay()
                    } catch {
                        self.log?.error("failed to relay stdin: \(error)")
                    }
                }
            } catch {
                self.log?.error("failed to accept stdin connection: \(error)")
            }
        }
    }

    /// Register an output (stdout/stderr) listener with the shared epoll loop.
    /// On each accepted connection the relay (pipe read end -> vsock) is
    /// rebuilt. The pipe read end is unowned so tearing down the relay never
    /// closes the child's output pipe.
    private func registerOutputAccept(
        listener: Socket,
        pipe: Pipe,
        reason: String,
        store: @escaping @Sendable (inout State, IOPair?) -> Void,
        current: @escaping @Sendable (State) -> IOPair?
    ) throws {
        try ProcessSupervisor.default.registerFd(listener.fileDescriptor, mask: [.input]) { [weak self] _ in
            guard let self else { return }
            do {
                let conn = try listener.accept(closeOnDeinit: false)
                self.state.withLock { state in
                    current(state)?.close()
                    let pair = IOPair(
                        readFrom: UnownedIOCloser(pipe.fileHandleForReading),
                        writeTo: conn,
                        reason: reason,
                        logger: self.log
                    )
                    store(&state, pair)
                    do {
                        try pair.relay()
                    } catch {
                        self.log?.error("failed to relay \(reason): \(error)")
                    }
                }
            } catch {
                self.log?.error("failed to accept \(reason) connection: \(error)")
            }
        }
    }

    func resize(size: Terminal.Size) throws {
        throw ContainerizationError(.unsupported, message: "resize not supported")
    }

    func close() throws {
        self.state.withLock {
            // Tear down the active relays. Each closes its owned vsock
            // connection but leaves the unowned pipe end open.
            $0.stdin?.close()
            $0.stdin = nil
            $0.stdout?.close()
            $0.stdout = nil
            $0.stderr?.close()
            $0.stderr = nil

            // Stop accepting and close the listeners.
            Self.closeListener(&$0.stdinListener)
            Self.closeListener(&$0.stdoutListener)
            Self.closeListener(&$0.stderrListener)

            // Close the parent-side pipe ends the relays were using.
            try? $0.stdinPipe?.fileHandleForWriting.close()
            try? $0.stdoutPipe?.fileHandleForReading.close()
            try? $0.stderrPipe?.fileHandleForReading.close()
        }
    }

    func closeStdin() throws {
        self.state.withLock {
            $0.stdin?.close()
            $0.stdin = nil
            Self.closeListener(&$0.stdinListener)
            // Close the write end so the child sees EOF on stdin.
            try? $0.stdinPipe?.fileHandleForWriting.close()
        }
    }

    func closeAfterExec() throws {
        try self.state.withLock {
            if let stdin = $0.stdinPipe {
                try stdin.fileHandleForReading.close()
            }
            if let stdout = $0.stdoutPipe {
                try stdout.fileHandleForWriting.close()
            }
            if let stderr = $0.stderrPipe {
                try stderr.fileHandleForWriting.close()
            }
        }
    }

    private static func closeListener(_ listener: inout Socket?) {
        guard let l = listener else { return }
        try? ProcessSupervisor.default.unregisterFd(l.fileDescriptor)
        try? l.close()
        listener = nil
    }
}

#endif
