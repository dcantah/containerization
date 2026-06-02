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

import ContainerizationOS
import Foundation
import LCShim
import Logging
import Synchronization

/// Relays a process's controlling terminal to the host over vsock.
///
/// Like `StandardIO`, the guest binds vsock listeners and the host dials in,
/// with the listeners kept open for reconnection (e.g. after save/restore).
/// The terminal fd only becomes available once the process has started, so an
/// accepted connection and the terminal are wired together by whichever
/// arrives second; later reconnections rewire directly.
final class TerminalIO: ManagedProcess.IO & Sendable {
    private struct State {
        var stdinListener: Socket?
        var stdoutListener: Socket?

        // Connections accepted before the terminal is available, awaiting wiring.
        var pendingStdinConn: Socket?
        var pendingStdoutConn: Socket?

        var stdin: IOPair?
        var stdout: IOPair?
        var parent: Terminal?
    }

    private let log: Logger?
    private let hostStdio: HostStdio
    private let state: Mutex<State>

    init(
        stdio: HostStdio,
        log: Logger?
    ) throws {
        self.hostStdio = stdio
        self.log = log
        self.state = Mutex(State())
    }

    func resize(size: Terminal.Size) throws {
        try self.state.withLock {
            if let parent = $0.parent {
                try parent.resize(size: size)
            }
        }
    }

    func start(process: inout Command) throws {
        try self.state.withLock {
            process.stdin = nil
            process.stdout = nil
            process.stderr = nil

            if let stdinPort = self.hostStdio.stdin {
                let listener = try VsockStdio.bind(port: stdinPort)
                $0.stdinListener = listener
                try self.registerStdinAccept(listener: listener)
            }

            if let stdoutPort = self.hostStdio.stdout {
                let listener = try VsockStdio.bind(port: stdoutPort)
                $0.stdoutListener = listener
                try self.registerStdoutAccept(listener: listener)
            }
        }
    }

    func attach(pid: Int32, fd: Int32) throws {
        try self.state.withLock {
            let containerFd = CZ_pidfd_open(pid, 0)
            guard containerFd != -1 else {
                throw POSIXError.fromErrno()
            }
            defer { Foundation.close(Int32(containerFd)) }

            let hostFd = CZ_pidfd_getfd(containerFd, fd, 0)
            guard hostFd != -1 else {
                throw POSIXError.fromErrno()
            }

            let term = try Terminal(descriptor: Int32(hostFd), setInitState: false)
            $0.parent = term

            // Wire up any connections that were accepted before the terminal
            // existed.
            if let conn = $0.pendingStdinConn {
                $0.pendingStdinConn = nil
                self.wireStdin(&$0, conn: conn, terminal: term)
            }
            if let conn = $0.pendingStdoutConn {
                $0.pendingStdoutConn = nil
                self.wireStdout(&$0, conn: conn, terminal: term)
            }
        }
    }

    private func registerStdinAccept(listener: Socket) throws {
        try ProcessSupervisor.default.registerFd(listener.fileDescriptor, mask: [.input]) { [weak self] _ in
            guard let self else { return }
            do {
                let conn = try listener.accept(closeOnDeinit: false)
                self.state.withLock { state in
                    state.stdin?.close()
                    state.stdin = nil
                    if let prev = state.pendingStdinConn {
                        try? prev.close()
                        state.pendingStdinConn = nil
                    }
                    if let term = state.parent {
                        self.wireStdin(&state, conn: conn, terminal: term)
                    } else {
                        state.pendingStdinConn = conn
                    }
                }
            } catch {
                self.log?.error("failed to accept terminal stdin connection: \(error)")
            }
        }
    }

    private func registerStdoutAccept(listener: Socket) throws {
        try ProcessSupervisor.default.registerFd(listener.fileDescriptor, mask: [.input]) { [weak self] _ in
            guard let self else { return }
            do {
                let conn = try listener.accept(closeOnDeinit: false)
                self.state.withLock { state in
                    state.stdout?.close()
                    state.stdout = nil
                    if let prev = state.pendingStdoutConn {
                        try? prev.close()
                        state.pendingStdoutConn = nil
                    }
                    if let term = state.parent {
                        self.wireStdout(&state, conn: conn, terminal: term)
                    } else {
                        state.pendingStdoutConn = conn
                    }
                }
            } catch {
                self.log?.error("failed to accept terminal stdout connection: \(error)")
            }
        }
    }

    // The terminal fd is unowned by both relays; it belongs to the process and
    // is closed in close(). Only the stdout relay registers it with epoll (as
    // its read source), so it must be torn down before the terminal is closed.
    private func wireStdin(_ state: inout State, conn: Socket, terminal: Terminal) {
        let pair = IOPair(
            readFrom: conn,
            writeTo: UnownedIOCloser(terminal),
            reason: "TerminalIO stdin",
            logger: log
        )
        do {
            try pair.relay(ignoreHup: true)
            state.stdin = pair
        } catch {
            self.log?.error("failed to relay terminal stdin: \(error)")
            try? conn.close()
        }
    }

    private func wireStdout(_ state: inout State, conn: Socket, terminal: Terminal) {
        let pair = IOPair(
            readFrom: UnownedIOCloser(terminal),
            writeTo: conn,
            reason: "TerminalIO stdout",
            logger: log
        )
        do {
            try pair.relay(ignoreHup: true)
            state.stdout = pair
        } catch {
            self.log?.error("failed to relay terminal stdout: \(error)")
            try? conn.close()
        }
    }

    func close() throws {
        self.state.withLock {
            // stdout must close before stdin because the stdout relay registered
            // the terminal fd with epoll and needs to unregister it while the fd
            // is still valid.
            $0.stdout?.close()
            $0.stdout = nil
            $0.stdin?.close()
            $0.stdin = nil

            Self.closeListener(&$0.stdinListener)
            Self.closeListener(&$0.stdoutListener)

            if let conn = $0.pendingStdinConn {
                try? conn.close()
                $0.pendingStdinConn = nil
            }
            if let conn = $0.pendingStdoutConn {
                try? conn.close()
                $0.pendingStdoutConn = nil
            }

            $0.parent = nil
        }
    }

    // NOP
    func closeAfterExec() throws {}

    func closeStdin() throws {
        self.state.withLock {
            $0.stdin?.close()
            $0.stdin = nil
            Self.closeListener(&$0.stdinListener)
            if let conn = $0.pendingStdinConn {
                try? conn.close()
                $0.pendingStdinConn = nil
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
