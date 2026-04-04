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
//  Healthcheck.swift
//  container-compose-app
//
//  Created by Morris Richman on 6/17/25.
//


/// Healthcheck configuration for a service.
public struct Healthcheck: Codable, Hashable {
    /// Command to run to check health
    public let test: [String]?
    /// Grace period for the container to start
    public let start_period: String?
    /// How often to run the check
    public let interval: String?
    /// Number of consecutive failures to consider unhealthy
    public let retries: Int?
    /// Timeout for each check
    public let timeout: String?

    public init(
        test: [String]? = nil,
        start_period: String? = nil,
        interval: String? = nil,
        retries: Int? = nil,
        timeout: String? = nil
    ) {
        self.test = test
        self.start_period = start_period
        self.interval = interval
        self.retries = retries
        self.timeout = timeout
    }

    private enum CodingKeys: String, CodingKey {
        case test
        case start_period
        case interval
        case retries
        case timeout
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        // Decode test - handle both string and array forms
        if let testArray = try? container.decode([String].self, forKey: .test) {
            self.test = testArray
        } else if let testString = try? container.decode(String.self, forKey: .test) {
            self.test = [testString]
        } else if container.contains(.test) {
            throw DecodingError.typeMismatch(
                [String].self,
                DecodingError.Context(
                    codingPath: [CodingKeys.test],
                    debugDescription: "test must be either a string or an array of strings"
                )
            )
        } else {
            self.test = nil
        }

        self.start_period = try container.decodeIfPresent(String.self, forKey: .start_period)
        self.interval = try container.decodeIfPresent(String.self, forKey: .interval)
        self.retries = try container.decodeIfPresent(Int.self, forKey: .retries)
        self.timeout = try container.decodeIfPresent(String.self, forKey: .timeout)
    }
}
