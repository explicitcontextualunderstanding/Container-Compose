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
    private static let version: String = "0.11.0"
 private static let gitCommit: String = "BUILD_GIT_COMMIT" // Injected by build-sign-install.sh
    public static var versionString: String {
        "\(commandName) version \(version) (git: \(gitCommit))"
    }
 public static let configuration: CommandConfiguration = .init(
 commandName: Self.commandName,
 abstract: "A tool to manage Docker Compose files using Apple Container.",
  discussion: """
  VERSION 0.11.0 FEATURES:
 • env: shorthand (alias for environment:) with ${VAR} interpolation
 • Pre-decode ${VAR} / ${VAR:-default} / ${VAR:?error} substitution in all YAML values
 • $$ escaping for literal $ in shell commands
 • __SERVICE_HOST__ / __SERVICE_PORT__ runtime service discovery
 • service_healthy condition for depends_on with automatic healthcheck polling
 • Service-level volume mapping (-v flags for bind mounts and named volumes)
 • Restart stopped containers on compose up
 • --force-recreate and --no-recreate for idempotent orchestration
 • -f flag for alternate compose file paths
 • --user, --hostname, --workdir, --privileged, --read-only, --network, -i, -t
 • dnsSearch support for custom DNS domains
 • Multi-stage Docker build target support
 • Checkpoint subcommand for container commit/export
 • Network and volume synchronization
 • --recover mode for crash recovery (skip running, start stopped, create missing)
 • service_completed_successfully dependency condition
 • container-compose health command (table/JSON/watch)
 • container-compose ps command (table/JSON, service filter, exit codes)
 • container-compose down --timeout-seconds with graceful→force escalation
 • Virtiofs database path warnings

 NOTE: Keep PROJECT-SERVICE names under 64 characters (macOS Virtualization.framework limit)
 """,
        version: Self.versionString,
subcommands: [
        ComposeUp.self,
        ComposeDown.self,
        ComposePs.self,
        CheckpointCommand.self,
        HealthCommand.self,
        SystemReset.self,
        Version.self
    ])
    
    public init() {}
}
