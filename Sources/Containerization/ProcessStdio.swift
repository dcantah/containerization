//===----------------------------------------------------------------------===//
// Copyright © 2025-2026 Apple Inc. and the Containerization project authors.
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

import Foundation

/// The host-side standard IO for a process, supplied when restoring a
/// container so each restored process can reconnect its streams.
public struct ProcessStdio: Sendable {
    public var stdin: ReaderStream?
    public var stdout: Writer?
    public var stderr: Writer?

    public init(
        stdin: ReaderStream? = nil,
        stdout: Writer? = nil,
        stderr: Writer? = nil
    ) {
        self.stdin = stdin
        self.stdout = stdout
        self.stderr = stderr
    }
}

/// A `Writer` that drops everything written to it. Used on restore to drain a
/// stream the guest is producing but the caller did not ask to receive, so the
/// restored process does not block writing to a port nobody is reading.
struct DiscardWriter: Writer {
    func write(_ data: Data) throws {}
    func close() throws {}
}

/// A `ReaderStream` that immediately ends. Used on restore for a stdin stream
/// the caller did not supply, so the restored process simply observes EOF.
struct EmptyReader: ReaderStream {
    func stream() -> AsyncStream<Data> {
        AsyncStream { $0.finish() }
    }
}
