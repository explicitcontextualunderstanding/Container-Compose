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

import Testing
import Foundation
import ContainerCommands
import ContainerAPIClient
import TestHelpers
@testable import ContainerComposeCore

@Suite("Compose Up Tests - Real-World Compose Files", .containerDependent, .serialized)
struct ComposeUpTests {
    
    @Test("Test WordPress with MySQL compose file")
    func testWordPressCompose() async throws {
        let yaml = DockerComposeYamlFiles.dockerComposeYaml1
        
        let tempLocation = URL.temporaryDirectory.appending(path: "Container-Compose_Tests_\(UUID().uuidString)/docker-compose.yaml")
        try? FileManager.default.createDirectory(at: tempLocation.deletingLastPathComponent(), withIntermediateDirectories: true)
        try yaml.write(to: tempLocation, atomically: false, encoding: .utf8)
        let folderName = tempLocation.deletingLastPathComponent().lastPathComponent
        
        var composeUp = try ComposeUp.parse(["-d", "--cwd", tempLocation.deletingLastPathComponent().path(percentEncoded: false)])
        try await composeUp.run()
        
        // Get these containers
        let containers = try await ClientContainer.list()
            .filter({
                $0.configuration.id.contains(tempLocation.deletingLastPathComponent().lastPathComponent)
            })
        
        // Assert correct container information (wordpress + nginx + mysql setup)
        guard let wordpressContainer = containers.first(where: { $0.configuration.id == "\(folderName)-wordpress" }),
              let webContainer = containers.first(where: { $0.configuration.id == "\(folderName)-web" }),
              let dbContainer = containers.first(where: { $0.configuration.id == "\(folderName)-db" })
        else {
            throw Errors.containerNotFound
        }

        // Check WordPress container (php-fpm, no exposed ports internally)
        #expect(wordpressContainer.configuration.image.reference == "docker.io/library/wordpress:php8.2-fpm")

        // Check Environment
        let wpEnv = parseEnvToDict(wordpressContainer.configuration.initProcess.environment)
        #expect(wpEnv["WORDPRESS_DB_HOST"] == dbContainer.networks.first?.ipv4Gateway.description)
        #expect(wpEnv["WORDPRESS_DB_USER"] == "wordpress")
        #expect(wpEnv["WORDPRESS_DB_PASSWORD"] == "wordpress")
        #expect(wpEnv["WORDPRESS_DB_NAME"] == "wordpress")

        // Check Volume
        #expect(wordpressContainer.configuration.mounts.map(\.destination).contains("/var/www/html"))

        // Check Web container (nginx, handles external port mapping)
        #expect(webContainer.configuration.publishedPorts.count == 1)
        #expect(webContainer.configuration.publishedPorts.first?.containerPort == 80)
        #expect(webContainer.configuration.image.reference == "docker.io/library/nginx:alpine")

        // Assert correct db container information
        // Check Image
        #expect(dbContainer.configuration.image.reference == "docker.io/library/mysql:8.0")
        
        // Check Environment
        let dbEnv = parseEnvToDict(dbContainer.configuration.initProcess.environment)
        #expect(dbEnv["MYSQL_ROOT_PASSWORD"] == "rootpassword")
        #expect(dbEnv["MYSQL_DATABASE"] == "wordpress")
        #expect(dbEnv["MYSQL_USER"] == "wordpress")
        #expect(dbEnv["MYSQL_PASSWORD"] == "wordpress")
        
        // Check Volume
        #expect(dbContainer.configuration.mounts.map(\.destination) == ["/var/lib/"])
        print("")
    }
    
    // TODO: Reenable
//    @Test("Test three-tier web application with multiple networks")
//    func testThreeTierWebAppWithNetworks() async throws {
//        let yaml = DockerComposeYamlFiles.dockerComposeYaml2
//        
//        let tempLocation = URL.temporaryDirectory.appending(path: "Container-Compose_Tests_\(UUID().uuidString)/docker-compose.yaml")
//        try? FileManager.default.createDirectory(at: tempLocation.deletingLastPathComponent(), withIntermediateDirectories: true)
//        try yaml.write(to: tempLocation, atomically: false, encoding: .utf8)
//        let folderName = tempLocation.deletingLastPathComponent().lastPathComponent
//        
//        var composeUp = try ComposeUp.parse(["-d", "--cwd", tempLocation.deletingLastPathComponent().path(percentEncoded: false)])
//        try await composeUp.run()
//        
//        // Get the containers created by this compose file
//        let containers = try await ClientContainer.list()
//            .filter({
//                $0.configuration.id.contains(folderName)
//            })
//        
//        guard let nginxContainer = containers.first(where: { $0.configuration.id == "\(folderName)-nginx" }),
//              let appContainer = containers.first(where: { $0.configuration.id == "\(folderName)-app" }),
//              let dbContainer = containers.first(where: { $0.configuration.id == "\(folderName)-db" }),
//              let redisContainer = containers.first(where: { $0.configuration.id == "\(folderName)-redis" })
//        else {
//            throw Errors.containerNotFound
//        }
//        
//        // --- NGINX Container ---
//        #expect(nginxContainer.configuration.image.reference == "docker.io/library/nginx:alpine")
//        #expect(nginxContainer.configuration.publishedPorts.map({ "\($0.hostAddress):\($0.hostPort):\($0.containerPort)" }) == ["0.0.0.0:80:80"])
//        #expect(nginxContainer.networks.map(\.hostname).contains("frontend"))
//        
//        // --- APP Container ---
//        #expect(appContainer.configuration.image.reference == "docker.io/library/node:18-alpine")
//        
//        let appEnv = parseEnvToDict(appContainer.configuration.initProcess.environment)
//        #expect(appEnv["NODE_ENV"] == "production")
//        #expect(appEnv["DATABASE_URL"] == "postgres://\(dbContainer.networks.first!.address.split(separator: "/")[0]):5432/myapp")
//        
//        #expect(appContainer.networks.map(\.hostname).sorted() == ["backend", "frontend"])
//        
//        // --- DB Container ---
//        #expect(dbContainer.configuration.image.reference == "docker.io/library/postgres:14-alpine")
//        let dbEnv = parseEnvToDict(dbContainer.configuration.initProcess.environment)
//        #expect(dbEnv["POSTGRES_DB"] == "myapp")
//        #expect(dbEnv["POSTGRES_USER"] == "user")
//        #expect(dbEnv["POSTGRES_PASSWORD"] == "password")
//        
//        // Verify volume mount
//        #expect(dbContainer.configuration.mounts.map(\.destination) == ["/var/lib/postgresql/"])
//        #expect(dbContainer.networks.map(\.hostname) == ["backend"])
//        
//        // --- Redis Container ---
//        #expect(redisContainer.configuration.image.reference == "docker.io/library/redis:alpine")
//        #expect(redisContainer.networks.map(\.hostname) == ["backend"])
//    }
    
//    @Test("Parse development environment with build")
//    func parseDevelopmentEnvironment() throws {
//        let yaml = DockerComposeYamlFiles.dockerComposeYaml4
//        
//        let decoder = YAMLDecoder()
//        let compose = try decoder.decode(DockerCompose.self, from: yaml)
//        
//        #expect(compose.services["app"]??.build != nil)
//        #expect(compose.services["app"]??.build?.context == ".")
//        #expect(compose.services["app"]??.volumes?.count == 2)
//    }
    
//    @Test("Parse compose with secrets and configs")
//    func parseComposeWithSecretsAndConfigs() throws {
//        let yaml = DockerComposeYamlFiles.dockerComposeYaml5
//        
//        let decoder = YAMLDecoder()
//        let compose = try decoder.decode(DockerCompose.self, from: yaml)
//        
//        #expect(compose.configs != nil)
//        #expect(compose.secrets != nil)
//    }
    
//    @Test("Parse compose with healthchecks and restart policies")
//    func parseComposeWithHealthchecksAndRestart() async throws {
//        let yaml = DockerComposeYamlFiles.dockerComposeYaml6
//        
//        let tempLocation = URL.temporaryDirectory.appending(path: "Container-Compose_Tests_\(UUID().uuidString)/docker-compose.yaml")
//        try? FileManager.default.createDirectory(at: tempLocation.deletingLastPathComponent(), withIntermediateDirectories: true)
//        try yaml.write(to: tempLocation, atomically: false, encoding: .utf8)
//        let folderName = tempLocation.deletingLastPathComponent().lastPathComponent
//        
//        var composeUp = try ComposeUp.parse(["-d", "--cwd", tempLocation.deletingLastPathComponent().path(percentEncoded: false)])
//        try await composeUp.run()
//        
//        // Get the containers created by this compose file
//        let containers = try await ClientContainer.list()
//            .filter({
//                $0.configuration.id.contains(folderName)
//            })
//        dump(containers)
//    }
    
    @Test("Test stopped container is restarted on compose up")
  func testStoppedContainerRestart() async throws {
    let yaml = """
      services:
        app:
          image: nginx:alpine
          ports:
            - "8085:80"
      """

    let tempLocation = URL.temporaryDirectory.appending(path: "Container-Compose_Tests_\(UUID().uuidString)/docker-compose.yaml")
    try? FileManager.default.createDirectory(at: tempLocation.deletingLastPathComponent(), withIntermediateDirectories: true)
    try yaml.write(to: tempLocation, atomically: false, encoding: .utf8)
    let folderName = tempLocation.deletingLastPathComponent().lastPathComponent

    // First, start the container
    var composeUp = try ComposeUp.parse(["-d", "--cwd", tempLocation.deletingLastPathComponent().path(percentEncoded: false)])
    try await composeUp.run()

    // Verify container is running
    let containersAfterFirstUp = try await ClientContainer.list()
      .filter { $0.configuration.id.contains(folderName) }
    guard let container = containersAfterFirstUp.first(where: { $0.configuration.id == "\(folderName)-app" }) else {
      throw Errors.containerNotFound
    }
    #expect(container.status == .running)

    // Stop the container using container CLI
    var stopCommand = try Application.ContainerStop.parse([container.configuration.id])
    try await stopCommand.run()

    // Verify container is stopped
    let stoppedContainers = try await ClientContainer.list()
      .filter { $0.configuration.id == "\(folderName)-app" }
    guard let stoppedContainer = stoppedContainers.first else {
      throw Errors.containerNotFound
    }
    #expect(stoppedContainer.status == .stopped)

    // Now run compose up again - it should restart the stopped container
    composeUp = try ComposeUp.parse(["-d", "--cwd", tempLocation.deletingLastPathComponent().path(percentEncoded: false)])
    try await composeUp.run()

    // Verify container is running again
    let containersAfterSecondUp = try await ClientContainer.list()
      .filter { $0.configuration.id == "\(folderName)-app" }
    guard let restartedContainer = containersAfterSecondUp.first else {
      throw Errors.containerNotFound
    }
    #expect(restartedContainer.status == .running)
  }

  @Test("Test compose with complex dependency chain")
    func TestComplexDependencyChain() async throws {
        let yaml = DockerComposeYamlFiles.dockerComposeYaml8
        
        let tempLocation = URL.temporaryDirectory.appending(path: "Container-Compose_Tests_\(UUID().uuidString)/docker-compose.yaml")
        try? FileManager.default.createDirectory(at: tempLocation.deletingLastPathComponent(), withIntermediateDirectories: true)
        try yaml.write(to: tempLocation, atomically: false, encoding: .utf8)
        let folderName = tempLocation.deletingLastPathComponent().lastPathComponent
        
        var composeUp = try ComposeUp.parse(["-d", "--cwd", tempLocation.deletingLastPathComponent().path(percentEncoded: false)])
        try await composeUp.run()
        
        // Get the containers created by this compose file
        let containers = try await ClientContainer.list()
            .filter {
                $0.configuration.id.contains(folderName)
            }
        
        guard let webContainer = containers.first(where: { $0.configuration.id == "\(folderName)-web" }),
              let appContainer = containers.first(where: { $0.configuration.id == "\(folderName)-app" }),
              let dbContainer = containers.first(where: { $0.configuration.id == "\(folderName)-db" })
        else {
            throw Errors.containerNotFound
        }
        
        // --- WEB Container ---
        #expect(webContainer.configuration.image.reference == "docker.io/library/nginx:alpine")
        // Check that port mapping exists (host port is configurable via TEST_PORT_WEB2 env var)
#expect(webContainer.configuration.publishedPorts.count == 1)
#expect(webContainer.configuration.publishedPorts.first?.containerPort == 80)
        
    // --- APP Container ---
    #expect(appContainer.configuration.image.reference == "docker.io/library/python:3.12-alpine")
    let appEnv = parseEnvToDict(appContainer.configuration.initProcess.environment)
    #expect(appEnv["DATABASE_URL"] == "postgres://postgres:postgres@db:5432/appdb")
    // After fixing command parsing, executable is just "python" (args are separate)
    #expect(appContainer.configuration.initProcess.executable == "python")
        #expect(appContainer.configuration.platform.architecture == "arm64")
        #expect(appContainer.configuration.platform.os == "linux")
        
        // --- DB Container ---
        #expect(dbContainer.configuration.image.reference == "docker.io/library/postgres:14")
        let dbEnv = parseEnvToDict(dbContainer.configuration.initProcess.environment)
        #expect(dbEnv["POSTGRES_DB"] == "appdb")
        #expect(dbEnv["POSTGRES_USER"] == "postgres")
        #expect(dbEnv["POSTGRES_PASSWORD"] == "postgres")
        
        // --- Dependency Verification ---
        // The dependency chain should reflect: web → app → db
        // i.e., app depends on db, web depends on app
        // We can verify indirectly by container states and environment linkage.
        // App isn't set to run long term
        #expect(webContainer.status == .running)
        #expect(dbContainer.status == .running)
    }

        @Test("Test container created with non-default CPU and memory limits")
        func testCpuAndMemoryLimits() async throws {
                let yaml = """
                version: "3.8"
                services:
                    app:
                        image: nginx:alpine
                        deploy:
                            resources:
                                limits:
                                    cpus: "1"
                                    memory: "512MB"
                """

                let tempLocation = URL.temporaryDirectory.appending(path: "Container-Compose_Tests_\(UUID().uuidString)/docker-compose.yaml")
                try? FileManager.default.createDirectory(at: tempLocation.deletingLastPathComponent(), withIntermediateDirectories: true)
                try yaml.write(to: tempLocation, atomically: false, encoding: .utf8)
                let folderName = tempLocation.deletingLastPathComponent().lastPathComponent

                var composeUp = try ComposeUp.parse(["-d", "--cwd", tempLocation.deletingLastPathComponent().path(percentEncoded: false)])
                try await composeUp.run()

                let containers = try await ClientContainer.list()
                        .filter { $0.configuration.id.contains(folderName) }

                guard let appContainer = containers.first(where: { $0.configuration.id == "\(folderName)-app" }) else {
                        throw Errors.containerNotFound
                }

                #expect(appContainer.configuration.resources.cpus == 1)
                #expect(appContainer.configuration.resources.memoryInBytes == 512.mib())
        }
    
    enum Errors: Error {
        case containerNotFound
    }
    
    private func parseEnvToDict(_ envArray: [String]) -> [String: String] {
        let array = envArray.map({ (String($0.split(separator: "=")[0]), String($0.split(separator: "=")[1])) })
        let dict = Dictionary(uniqueKeysWithValues: array)
        
        return dict
    }
}

struct ContainerDependentTrait: TestScoping, TestTrait, SuiteTrait {
    func provideScope(for test: Test, testCase: Test.Case?, performing function: () async throws -> Void) async throws {
        // Start Server
        try await Application.SystemStart.parse(["--enable-kernel-install"]).run()
        
        // Run Test
        try await function()
    }
}

extension Trait where Self == ContainerDependentTrait {
    static var containerDependent: ContainerDependentTrait { .init() }
}
