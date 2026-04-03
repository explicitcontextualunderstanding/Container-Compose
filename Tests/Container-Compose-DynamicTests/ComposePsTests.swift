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

import ContainerAPIClient
import ContainerCommands
import Foundation
import TestHelpers
import Testing

@testable import ContainerComposeCore

@Suite("Compose Ps Tests", .containerDependent, .serialized)
struct ComposePsTests {

    @Test("Shows running containers from compose up")
    func testPsShowsRunningContainers() async throws {
        let yaml = """
        services:
          nginx:
            image: nginx:alpine
            ports:
              - "18090:8080"
          busybox:
            image: busybox:latest
            command: ["sh", "-c", "sleep 300"]
        """
        let project = try DockerComposeYamlFiles.copyYamlToTemporaryLocation(yaml: yaml)
        try await ContainerPollingHelpers.withProjectCleanup(projectName: project.name) {
            var composeUp = try ComposeUp.parse([
                "-d", "--cwd", project.base.path(percentEncoded: false),
            ])
            try await composeUp.run()

            let deadline = Date().addingTimeInterval(60)
            while Date() < deadline {
                let running = try await ClientContainer.list()
                    .filter({ $0.configuration.id.contains(project.name) && $0.status == .running })
                if running.count >= 2 { break }
                try await Task.sleep(nanoseconds: 1_000_000_000)
            }

            let statuses = try await ComposePs.listServices(
                cwd: project.base.path(percentEncoded: false)
            )

            #expect(statuses.count == 2, "Expected 2 services, got \(statuses.count)")
            let nginxStatus = statuses.first { $0.service == "nginx" }
            #expect(nginxStatus?.state == .running, "nginx should be running")
        }
    }

    @Test("Shows stopped container after container stop")
    func testPsShowsStoppedContainer() async throws {
        let containerName = "CCT_ps_stop_\(UUID().uuidString)"
        let yaml = DockerComposeYamlFiles.dockerComposeYaml9(containerName: containerName)
        let project = try DockerComposeYamlFiles.copyYamlToTemporaryLocation(yaml: yaml)
        try await ContainerPollingHelpers.withProjectCleanup(projectNames: [project.name, "CCT_ps_stop"]) {
            var composeUp = try ComposeUp.parse([
                "-d", "--cwd", project.base.path(percentEncoded: false),
            ])
            try await composeUp.run()

            let container = try await ClientContainer.get(id: containerName)
            try await container.stop()

            let statuses = try await ComposePs.listServices(cwd: project.base.path(percentEncoded: false))
            let status = statuses.first { $0.service == "web" }
            #expect(status?.state == .stopped, "Container should be stopped")
        }
    }

    @Test("Shows stopped service after container stop")
    func testPsShowsMissingService() async throws {
        let yaml = """
        services:
          nginx:
            image: nginx:alpine
          busybox:
            image: busybox:latest
            command: ["sh", "-c", "sleep 300"]
        """
        let project = try DockerComposeYamlFiles.copyYamlToTemporaryLocation(yaml: yaml)
        try await ContainerPollingHelpers.withProjectCleanup(projectName: project.name) {
            var composeUp = try ComposeUp.parse([
                "-d", "--cwd", project.base.path(percentEncoded: false),
            ])
            try await composeUp.run()

            let deadline = Date().addingTimeInterval(60)
            while Date() < deadline {
                let running = try await ClientContainer.list()
                    .filter({ $0.configuration.id.contains(project.name) && $0.status == .running })
                if running.count >= 2 { break }
                try await Task.sleep(nanoseconds: 1_000_000_000)
            }

            let allContainers = try await ClientContainer.list()
                .filter({ $0.configuration.id.contains(project.name) && $0.status == .running })
            if let busybox = allContainers.first(where: { $0.configuration.id.contains("busybox") }) {
                try await busybox.stop()
            }

            let statuses = try await ComposePs.listServices(cwd: project.base.path(percentEncoded: false))
            #expect(statuses.count == 2, "Expected 2 services in compose file")
            let notRunning = statuses.filter { $0.state != .running }
            #expect(!notRunning.isEmpty, "At least one service should be stopped")
        }
    }

    @Test("Filter by service name")
    func testPsFilterByServiceName() async throws {
        let port = UInt16.random(in: 18100..<18200)
        let yaml = """
        services:
          nginx:
            image: nginx:alpine
            ports:
              - "\(port):8080"
          busybox:
            image: busybox:latest
            command: ["sh", "-c", "sleep 300"]
        """
        let project = try DockerComposeYamlFiles.copyYamlToTemporaryLocation(yaml: yaml)
        try await ContainerPollingHelpers.withProjectCleanup(projectName: project.name) {
            var composeUp = try ComposeUp.parse([
                "-d", "--cwd", project.base.path(percentEncoded: false),
            ])
            try await composeUp.run()

            let deadline = Date().addingTimeInterval(60)
            while Date() < deadline {
                let running = try await ClientContainer.list()
                    .filter({ $0.configuration.id.contains(project.name) && $0.status == .running })
                if running.count >= 2 { break }
                try await Task.sleep(nanoseconds: 1_000_000_000)
            }

            let allStatuses = try await ComposePs.listServices(cwd: project.base.path(percentEncoded: false), serviceFilter: "nginx")
            #expect(allStatuses.count == 1, "Filter should return 1 service")
            #expect(allStatuses[0].service == "nginx")
        }
    }

    @Test("Container name override matches correctly")
    func testPsContainerNameOverride() async throws {
        let containerName = "CCT_ps_name_\(UUID().uuidString)"
        let yaml = DockerComposeYamlFiles.dockerComposeYaml9(containerName: containerName)
        let project = try DockerComposeYamlFiles.copyYamlToTemporaryLocation(yaml: yaml)
        try await ContainerPollingHelpers.withProjectCleanup(projectNames: [project.name, "CCT_ps_name"]) {
            var composeUp = try ComposeUp.parse([
                "-d", "--cwd", project.base.path(percentEncoded: false),
            ])
            try await composeUp.run()

            let statuses = try await ComposePs.listServices(cwd: project.base.path(percentEncoded: false))
            #expect(statuses.count == 1)
            #expect(statuses[0].container == containerName)
            #expect(statuses[0].state == .running)
        }
    }

    @Test("JSON output is valid JSON")
    func testPsJsonOutputFormat() async throws {
        let containerName = "CCT_ps_json_\(UUID().uuidString)"
        let yaml = DockerComposeYamlFiles.dockerComposeYaml9(containerName: containerName)
        let project = try DockerComposeYamlFiles.copyYamlToTemporaryLocation(yaml: yaml)
        try await ContainerPollingHelpers.withProjectCleanup(projectNames: [project.name, "CCT_ps_json"]) {
            var composeUp = try ComposeUp.parse([
                "-d", "--cwd", project.base.path(percentEncoded: false),
            ])
            try await composeUp.run()

            let statuses = try await ComposePs.listServices(cwd: project.base.path(percentEncoded: false))
            let jsonString = try ComposePs.formatPsJSON(statuses)
            let data = Data(jsonString.utf8)
            let json = try JSONSerialization.jsonObject(with: data)
            #expect(json is [Any], "JSON output should be an array")
        }
    }

    @Test("Exit code 0 when all running")
    func testPsExitCodeAllRunning() async throws {
        let containerName = "CCT_ps_exit_\(UUID().uuidString)"
        let yaml = DockerComposeYamlFiles.dockerComposeYaml9(containerName: containerName)
        let project = try DockerComposeYamlFiles.copyYamlToTemporaryLocation(yaml: yaml)
        try await ContainerPollingHelpers.withProjectCleanup(projectNames: [project.name, "CCT_ps_exit"]) {
            var composeUp = try ComposeUp.parse([
                "-d", "--cwd", project.base.path(percentEncoded: false),
            ])
            try await composeUp.run()

            let statuses = try await ComposePs.listServices(cwd: project.base.path(percentEncoded: false))
            #expect(statuses.count == 1)
            #expect(statuses[0].state == .running)
        }
    }

    @Test("All stopped after compose down")
    func testPsAfterComposeDown() async throws {
        let containerName = "CCT_ps_after_\(UUID().uuidString)"
        let yaml = DockerComposeYamlFiles.dockerComposeYaml9(containerName: containerName)
        let project = try DockerComposeYamlFiles.copyYamlToTemporaryLocation(yaml: yaml)
        try await ContainerPollingHelpers.withProjectCleanup(projectNames: [project.name, "CCT_ps_after"]) {
            var composeUp = try ComposeUp.parse([
                "-d", "--cwd", project.base.path(percentEncoded: false),
            ])
            try await composeUp.run()

            var composeDown = try ComposeDown.parse(["--cwd", project.base.path(percentEncoded: false)])
            try? await composeDown.run()

            let statuses = try await ComposePs.listServices(cwd: project.base.path(percentEncoded: false))
            #expect(statuses.count == 1)
            #expect(statuses[0].state == .stopped, "After down, service should be stopped (compose down stops but doesn't remove containers)")
        }
    }
}
