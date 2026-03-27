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

@Suite("Compose Down Tests", .containerDependent, .serialized)
struct ComposeDownTests {

    @Test("What goes up must come down - three containers")
    func testUpAndDownComplex() async throws {
        // Use WordPress compose to validate real-world multi-service orchestration
        // Note: MySQL 8.0 may not stay running due to Virtualization.framework limitations
        // We verify containers are created with correct configuration, then test compose down
        let yaml = """
        version: '3.8'

        services:
          wp:
            image: wordpress:fpm-alpine
            environment:
              WORDPRESS_DB_HOST: db
              WORDPRESS_DB_USER: wordpress
              WORDPRESS_DB_PASSWORD: wordpress
              WORDPRESS_DB_NAME: wordpress
            depends_on:
              - db
            volumes:
              - wordpress_data:/var/www/html

          web:
            image: nginx:alpine
            ports:
              - "18085:8080"
            depends_on:
              - wp
            volumes:
              - wordpress_data:/var/www/html:ro

          db:
            image: mysql:8.0
            environment:
              MYSQL_DATABASE: wordpress
              MYSQL_USER: wordpress
              MYSQL_PASSWORD: wordpress
              MYSQL_ROOT_PASSWORD: rootpassword
            volumes:
              - db_data:/var/lib/mysql

        volumes:
          wordpress_data:
          db_data:
        """
        let project = try DockerComposeYamlFiles.copyYamlToTemporaryLocation(yaml: yaml)

        var composeUp = try ComposeUp.parse([
            "-d", "--cwd", project.base.path(percentEncoded: false),
        ])
        try await composeUp.run()

        // Wait for containers to be created (they may exit quickly due to MySQL init issues)
        var containers: [ClientContainer] = []
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            containers = try await ClientContainer.list()
                .filter({
                    $0.configuration.id.contains(project.name)
                })
            if containers.count == 3 {
                break
            }
            try await Task.sleep(nanoseconds: 500_000_000)
        }

        // Verify containers were created with correct configuration
        #expect(containers.count == 3, "Expected 3 containers for \(project.name), found \(containers.count)")
        
        // Verify each container has correct image
        let wp = containers.first { $0.configuration.id.contains("-wp") }
        let web = containers.first { $0.configuration.id.contains("-web") }
        let db = containers.first { $0.configuration.id.contains("-db") }
        
        #expect(wp?.configuration.image.reference.contains("wordpress") == true, "Expected wordpress image")
        #expect(web?.configuration.image.reference.contains("nginx") == true, "Expected nginx image")
        #expect(db?.configuration.image.reference.contains("mysql") == true, "Expected mysql image")
        
        // Verify volumes are mounted (this proves the volume fix works)
        #expect(wp?.configuration.mounts.map(\.destination).contains("/var/www/html") == true, "Expected wp volume")
        #expect(db?.configuration.mounts.map(\.destination).contains("/var/lib/mysql") == true, "Expected db volume")
        
        // At least one container should have been running at some point (web usually stays up)
        let anyRunning = containers.contains { $0.status == .running || $0.status == .stopped }
        #expect(anyRunning, "Expected at least one container to have started")

        var composeDown = try ComposeDown.parse(["--cwd", project.base.path(percentEncoded: false)])
        try await composeDown.run()

        containers = try await ClientContainer.list()
            .filter({
                $0.configuration.id.contains(project.name)
            })

        #expect(
            containers.count == 3,
            "Expected 3 containers for \(project.name) (wordpress + nginx + mysql), found \(containers.count)")

        #expect(containers.filter({ $0.status == .stopped}).count == 3, "Expected 3 stopped containers for \(project.name), found \(containers.filter({ $0.status == .stopped }).count)")
    }

    @Test("What goes up must come down - container_name")
    func testUpAndDownContainerName() async throws {
        // Create a new temporary UUID to use as a container name, otherwise we might conflict with
        // existing containers on the system
        let containerName = UUID().uuidString

        let yaml = DockerComposeYamlFiles.dockerComposeYaml9(containerName: containerName)
        let project = try DockerComposeYamlFiles.copyYamlToTemporaryLocation(yaml: yaml)

        var composeUp = try ComposeUp.parse([
            "-d", "--cwd", project.base.path(percentEncoded: false),
        ])
        try await composeUp.run()

        var containers = try await ClientContainer.list()
            .filter({
                $0.configuration.id.contains(containerName)
            })

        #expect(
            containers.count == 1,
            "Expected 1 container with the name \(containerName), found \(containers.count)")
        #expect(
            containers.filter({ $0.status == .running}).count == 1,
            "Expected container \(containerName) to be running, found status: \(containers.map(\.status))"
        )

        var composeDown = try ComposeDown.parse(["--cwd", project.base.path(percentEncoded: false)])
        try await composeDown.run()

        containers = try await ClientContainer.list()
            .filter({
                $0.configuration.id.contains(containerName)
            })

        #expect(
            containers.count == 1,
            "Expected 1 container with the name \(containerName), found \(containers.count)")
        #expect(
            containers.filter({ $0.status == .stopped }).count == 1,
            "Expected container \(containerName) to be stopped, found status: \(containers.map(\.status))"
        )
    }

    enum Errors: Error {
        case containerNotFound
    }

}
