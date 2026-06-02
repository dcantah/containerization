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

struct HostStdio: Sendable {
    let stdin: UInt32?
    let stdout: UInt32?
    let stderr: UInt32?
    let terminal: Bool
}

/// Helpers for establishing process stdio over vsock.
///
/// The guest listens and the host dials. Listening in the guest, and keeping
/// the listener open, is what lets the stdio connections be re-established
/// after the VM is saved and restored: the host simply re-dials.
enum VsockStdio {
    /// Bind a vsock listener on the given port, ready for the host to dial.
    /// The listener is left open so the host can reconnect after a restore.
    static func bind(port: UInt32) throws -> Socket {
        let type = VsockType(port: port, cid: VsockType.anyCID)
        let listener = try Socket(type: type, closeOnDeinit: false)
        try listener.listen()
        return listener
    }
}

#endif
