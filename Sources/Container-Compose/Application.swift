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

import Foundation
import ArgumentParser

public struct Main: AsyncParsableCommand {
    private static let commandName: String = "container-compose"
    private static let version: String = "0.10.2"
    private static let gitCommit: String = "6a6a081"  // Updated during build
    public static var versionString: String {
        "\(commandName) version \(version) (git: \(gitCommit))"
    }
  public static let configuration: CommandConfiguration = .init(
    commandName: Self.commandName,
    abstract: "A tool to manage Docker Compose files using Apple Container. v0.10.2 includes: env: shorthand key support (alias for environment:), command string parsing, volume idempotency, --env and --publish flag mapping. Also supports: --user, --hostname, --workdir, --privileged, --read-only, --network, -i, -t, checkpointing, network sync, volume management, dnsSearch, multi-stage builds.",
    version: Self.versionString,
        subcommands: [
            ComposeUp.self,
            ComposeDown.self,
            CheckpointCommand.self,
            Version.self
        ])
    
    public init() {}
}
