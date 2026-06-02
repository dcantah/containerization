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

import ContainerizationError
import Foundation

/// The metadata persisted alongside a saved virtual machine state file.
///
/// This captures exactly what `LinuxContainer.restore(from:...)` needs to
/// rebuild the container and a virtual machine configuration byte-for-byte
/// identical to the saved one (Virtualization.framework only restores state
/// against a matching configuration). It deliberately omits configuration that
/// only influences guest-side setup performed during `create()` (process args,
/// DNS, hosts, sysctls), since restore reconnects to the already-running guest
/// rather than recreating it.
public struct ContainerSnapshot: Codable, Sendable {
    /// A `major.minor` schema version, encoded as the string "major.minor".
    public struct Version: Codable, Sendable, Comparable, Equatable, CustomStringConvertible {
        public let major: Int
        public let minor: Int

        public init(_ major: Int, _ minor: Int) {
            self.major = major
            self.minor = minor
        }

        public var description: String { "\(major).\(minor)" }

        public static func < (lhs: Version, rhs: Version) -> Bool {
            (lhs.major, lhs.minor) < (rhs.major, rhs.minor)
        }

        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            let parts = raw.split(separator: ".", maxSplits: 1)
            guard parts.count == 2, let major = Int(parts[0]), let minor = Int(parts[1]) else {
                throw DecodingError.dataCorrupted(
                    .init(
                        codingPath: decoder.codingPath,
                        debugDescription: "invalid snapshot version '\(raw)', expected major.minor"
                    ))
            }
            self.major = major
            self.minor = minor
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(self.description)
        }
    }

    /// The version this build writes. Bump the minor on additive changes and
    /// the major on breaking ones (removing/renaming a field or changing its
    /// meaning). Additive, optional fields need not change the version.
    public static let currentVersion = Version(0, 1)

    /// The oldest version this build can still decode (directly or by
    /// migration). Raise this to drop support for formats too old to migrate.
    public static let minimumSupportedVersion = Version(0, 1)

    /// Per-process stdio state needed to re-dial the guest after restore.
    public struct ProcessSnapshot: Codable, Sendable {
        public var id: String
        public var pid: Int32
        public var stdinPort: UInt32?
        public var stdoutPort: UInt32?
        public var stderrPort: UInt32?

        public init(
            id: String,
            pid: Int32,
            stdinPort: UInt32?,
            stdoutPort: UInt32?,
            stderrPort: UInt32?
        ) {
            self.id = id
            self.pid = pid
            self.stdinPort = stdinPort
            self.stdoutPort = stdoutPort
            self.stderrPort = stderrPort
        }
    }

    /// A unix socket relay's functional configuration plus its vsock port, so
    /// the host side can be re-established on restore. The guest side persists
    /// in the saved VM memory, so only these host-side inputs are needed.
    public struct SocketRelaySnapshot: Codable, Sendable {
        public enum Direction: String, Codable, Sendable {
            case into
            case outOf
        }

        public var id: String
        public var source: URL
        public var destination: URL
        public var permissions: UInt32?
        public var direction: Direction
        public var port: UInt32

        public init(
            id: String,
            source: URL,
            destination: URL,
            permissions: UInt32?,
            direction: Direction,
            port: UInt32
        ) {
            self.id = id
            self.source = source
            self.destination = destination
            self.permissions = permissions
            self.direction = direction
            self.port = port
        }
    }

    public var version: Version
    public var id: String

    // Container-level inputs that shape the VM configuration. The kernel,
    // initial filesystem, and rosetta toggle are owned by the virtual machine
    // manager the caller supplies to `restore`, so they are not persisted here.
    public var rootfs: Mount
    public var writableLayer: Mount?
    public var mounts: [Mount]
    public var socketRelays: [SocketRelaySnapshot]
    public var cpus: Int
    public var memoryInBytes: UInt64
    public var cpuOverhead: Int
    public var memoryOverhead: UInt64
    public var nestedVirtualization: Bool

    // Runtime state that cannot be reconstructed from configuration.
    public var hostVsockPortCursor: UInt32
    public var guestVsockPortCursor: UInt32
    public var process: ProcessSnapshot
    /// Additional exec processes vended into the container.
    public var vendedProcesses: [ProcessSnapshot]

    public init(
        version: Version = ContainerSnapshot.currentVersion,
        id: String,
        rootfs: Mount,
        writableLayer: Mount?,
        mounts: [Mount],
        socketRelays: [SocketRelaySnapshot] = [],
        cpus: Int,
        memoryInBytes: UInt64,
        cpuOverhead: Int,
        memoryOverhead: UInt64,
        nestedVirtualization: Bool,
        hostVsockPortCursor: UInt32,
        guestVsockPortCursor: UInt32,
        process: ProcessSnapshot,
        vendedProcesses: [ProcessSnapshot] = []
    ) {
        self.version = version
        self.id = id
        self.rootfs = rootfs
        self.writableLayer = writableLayer
        self.mounts = mounts
        self.socketRelays = socketRelays
        self.cpus = cpus
        self.memoryInBytes = memoryInBytes
        self.cpuOverhead = cpuOverhead
        self.memoryOverhead = memoryOverhead
        self.nestedVirtualization = nestedVirtualization
        self.hostVsockPortCursor = hostVsockPortCursor
        self.guestVsockPortCursor = guestVsockPortCursor
        self.process = process
        self.vendedProcesses = vendedProcesses
    }
}

extension ContainerSnapshot {
    /// The minimal header decoded before the body so the version is readable
    /// even if the rest of the schema changed across versions.
    private struct Header: Codable {
        var version: Version
    }

    /// Encode this snapshot to bundle data.
    public func encoded() throws -> Data {
        try JSONEncoder().encode(self)
    }

    /// Decode a snapshot from bundle data, validating the version is within the
    /// supported range and migrating older formats forward as needed.
    public static func decode(from data: Data) throws -> ContainerSnapshot {
        let decoder = JSONDecoder()

        let version: Version
        do {
            version = try decoder.decode(Header.self, from: data).version
        } catch {
            throw ContainerizationError(
                .invalidArgument,
                message: "container snapshot is missing or has an unreadable version",
                cause: error
            )
        }

        guard version <= currentVersion else {
            throw ContainerizationError(
                .unsupported,
                message:
                    "container snapshot version \(version) was written by a newer release; this build supports up to \(currentVersion)"
            )
        }
        guard version >= minimumSupportedVersion else {
            throw ContainerizationError(
                .unsupported,
                message:
                    "container snapshot version \(version) is too old to restore; minimum supported is \(minimumSupportedVersion)"
            )
        }

        if version == currentVersion {
            return try decoder.decode(ContainerSnapshot.self, from: data)
        }

        // Older but still-supported versions are migrated here: decode the
        // legacy body type for `version` and map it to the current shape. While
        // only \(currentVersion) exists, the current decoder applies.
        return try decoder.decode(ContainerSnapshot.self, from: data)
    }
}

