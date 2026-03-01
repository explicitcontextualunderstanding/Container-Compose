//===----------------------------------------------------------------------===//
// Copyright © 2025 Morris Richman and the Container-Compose project authors. All rights reserved.
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

//
//  Network.swift
//  container-compose-app
//
//  Created by Morris Richman on 6/17/25.
//


/// Represents a top-level network definition.
public struct Network: Codable {
    /// Network driver (e.g., 'bridge', 'overlay')
    public let driver: String?
    /// Driver-specific options
    public let driver_opts: [String: String]?
    /// Allow standalone containers to attach to this network
    public let attachable: Bool?
    /// Enable IPv6 networking
    public let enable_ipv6: Bool?
    /// RENAMED: from `internal` to `isInternal` to avoid keyword clash
    public let isInternal: Bool?
    /// Labels for the network
    public let labels: [String: String]?
    /// IPAM configuration
    public let ipam: IPAM?
    /// Explicit name for the network
    public let name: String?
    /// Indicates if the network is external (pre-existing)
    public let external: ExternalNetwork?

    /// Updated CodingKeys to map 'internal' from YAML to 'isInternal' Swift property
    enum CodingKeys: String, CodingKey {
        case driver, driver_opts, attachable, enable_ipv6, isInternal = "internal", labels, ipam, name, external
    }

    /// Custom initializer to handle `external: true` (boolean) or `external: { name: "my_net" }` (object).
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        driver = try container.decodeIfPresent(String.self, forKey: .driver)
        driver_opts = try container.decodeIfPresent([String: String].self, forKey: .driver_opts)
        attachable = try container.decodeIfPresent(Bool.self, forKey: .attachable)
        enable_ipv6 = try container.decodeIfPresent(Bool.self, forKey: .enable_ipv6)
        isInternal = try container.decodeIfPresent(Bool.self, forKey: .isInternal) // Use isInternal here
        labels = try container.decodeIfPresent([String: String].self, forKey: .labels)
        ipam = try container.decodeIfPresent(IPAM.self, forKey: .ipam)
        name = try container.decodeIfPresent(String.self, forKey: .name)

        if let externalBool = try? container.decodeBoolIfPresent(forKey: .external) {
            external = ExternalNetwork(isExternal: externalBool, name: nil)
        } else if let externalDict = try? container.decodeIfPresent([String: String].self, forKey: .external) {
            external = ExternalNetwork(isExternal: true, name: externalDict["name"])
        } else {
            external = nil
        }
    }
}

/// Represents IPAM configuration for a network.
public struct IPAM: Codable {
    /// IPAM configuration blocks
    public let config: [IPAMConfig]?
}

/// Represents an individual IPAM configuration block.
public struct IPAMConfig: Codable {
    /// Subnet for the network
    public let subnet: String?
    /// Gateway for the network
    public let gateway: String?
}

extension KeyedDecodingContainer {
    func decodeBoolIfPresent(forKey key: K) throws -> Bool? {
        if let boolValue = try? decodeIfPresent(Bool.self, forKey: key) {
            return boolValue
        }
        if let stringValue = try? decodeIfPresent(String.self, forKey: key) {
            return stringValue.lowercased() == "true"
        }
        return nil
    }
}
