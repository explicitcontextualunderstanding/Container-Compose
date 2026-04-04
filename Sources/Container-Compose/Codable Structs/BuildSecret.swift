//===----------------------------------------------------------------------===//
// Copyright © 2025 Morris Richman and the Container-Compose project authors. All rights reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//===----------------------------------------------------------------------===//

//
// BuildSecret.swift
// container-compose-app
//
// Build-time secret configuration for Dockerfile builds.
// Maps to Apple Container CLI: --secret id=<key>[,env=<ENV_VAR>|,src=<local/path>]
//

/// Represents a build-time secret for Dockerfile builds.
/// Simplified compared to ServiceSecret (no uid/gid/mode/target fields).
public struct BuildSecret: Codable, Hashable {
    /// Unique identifier for the secret
    public let id: String
    
    /// Environment variable containing the secret value
    public let env: String?
    
    /// Path to a file containing the secret value
    public let src: String?
    
    enum CodingKeys: String, CodingKey {
        case id, env, src
    }
    
    /// Custom initializer to handle both YAML formats:
    /// - Object format: { id: my_secret, env: MY_ENV_VAR }
    /// - Required: id field
    /// - Optional: env or src (mutually exclusive in practice)
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.env = try container.decodeIfPresent(String.self, forKey: .env)
        self.src = try container.decodeIfPresent(String.self, forKey: .src)
    }
    
    /// Encode to YAML/JSON
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(env, forKey: .env)
        try container.encodeIfPresent(src, forKey: .src)
    }
    
    /// Manual initializer for programmatic creation
    public init(id: String, env: String? = nil, src: String? = nil) {
        self.id = id
        self.env = env
        self.src = src
    }
}
