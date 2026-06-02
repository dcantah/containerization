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

import ContainerizationExtras

/// A network interface.
public protocol Interface: Sendable {
    /// The interface IPv4 address and subnet prefix length, as a CIDR address.
    /// Example: `192.168.64.3/24`
    var ipv4Address: CIDRv4 { get }

    /// The IP address for the default route, or nil for no default route.
    var ipv4Gateway: IPv4Address? { get }

    /// The interface MAC address, or nil to auto-configure the address.
    var macAddress: MACAddress? { get }

    /// The interface MTU (Maximum Transmission Unit).
    var mtu: UInt32 { get }

    /// Returns a copy of the interface with its MAC address set to `macAddress`
    /// if, and only if, the interface does not already specify one.
    ///
    /// The container uses this to guarantee every interface has a stable MAC.
    /// A MAC must be fixed so that a saved virtual machine can be restored
    /// against a byte-for-byte identical configuration; otherwise
    /// Virtualization.framework assigns a fresh random MAC on each build and
    /// the saved state no longer matches. Conformers that can carry a MAC
    /// should implement this; the default returns the interface unchanged.
    func resolvingMACAddress(_ macAddress: MACAddress) -> any Interface
}

extension Interface {
    public var mtu: UInt32 { 1500 }

    public func resolvingMACAddress(_ macAddress: MACAddress) -> any Interface {
        self
    }
}
