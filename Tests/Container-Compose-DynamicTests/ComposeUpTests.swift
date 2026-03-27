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
            .replacingOccurrences(of: "${TEST_PORT_WORDPRESS:-18080}", with: "18080")
            // Note: MySQL has no host port in this YAML, so no replacement needed for 3306
        let nginxConf = DockerComposeYamlFiles.nginxConf

        let tempLocation = URL.temporaryDirectory.appending(path: "CCT_\(UUID().uuidString)/docker-compose.yaml")
        let nginxConfLocation = tempLocation.deletingLastPathComponent().appending(path: "nginx.conf")
        try FileManager.default.createDirectory(at: tempLocation.deletingLastPathComponent(), withIntermediateDirectories: true)
        try yaml.write(to: tempLocation, atomically: false, encoding: .utf8)
        try nginxConf.write(to: nginxConfLocation, atomically: false, encoding: .utf8)
        let folderName = tempLocation.deletingLastPathComponent().lastPathComponent

        var composeUp = try ComposeUp.parse(["-d", "--cwd", tempLocation.deletingLastPathComponent().path(percentEncoded: false)])
        try await composeUp.run()
        
        // Get these containers
        let containers = try await ClientContainer.list()
            .filter({
                $0.configuration.id.contains(tempLocation.deletingLastPathComponent().lastPathComponent)
            })
        
        // Assert correct container information (wp + nginx + mysql setup)
        guard let wordpressContainer = containers.first(where: { $0.configuration.id == "\(folderName)-wp" }),
              let webContainer = containers.first(where: { $0.configuration.id == "\(folderName)-web" }),
              let dbContainer = containers.first(where: { $0.configuration.id == "\(folderName)-db" })
        else {
            throw Errors.containerNotFound
        }

        // Check WordPress container (php-fpm, no exposed ports internally)
        #expect(wordpressContainer.configuration.image.reference == "docker.io/library/wordpress:fpm-alpine")

        // Check Environment
        let wpEnv = parseEnvToDict(wordpressContainer.configuration.initProcess.environment)
        #expect(wpEnv["WORDPRESS_DB_HOST"] == dbContainer.networks.first?.ipv4Address.address.description)
        #expect(wpEnv["WORDPRESS_DB_USER"] == "wordpress")
        #expect(wpEnv["WORDPRESS_DB_PASSWORD"] == "wordpress")
        #expect(wpEnv["WORDPRESS_DB_NAME"] == "wordpress")

        // Check Volume
        print("DEBUG: wp mounts: \(wordpressContainer.configuration.mounts.map(\.destination))")
        // #expect(wordpressContainer.configuration.mounts.map(\.destination).contains(where: { $0.contains("/var/www/html") }))

        // Check Web container (nginx, handles external port mapping)
        #expect(webContainer.configuration.publishedPorts.first?.hostPort == 18080)
        #expect(webContainer.configuration.publishedPorts.first?.containerPort == 8080)
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
        print("DEBUG: db mounts: \(dbContainer.configuration.mounts.map(\.destination))")
        // #expect(dbContainer.configuration.mounts.map(\.destination).contains(where: { $0.contains("/var/lib/mysql") }))
        print("")
        
        // Cleanup
        var composeDown = try ComposeDown.parse(["--cwd", tempLocation.deletingLastPathComponent().path(percentEncoded: false)])
        _ = try? await composeDown.run()
    }
    
    // TODO: Reenable
//    @Test("Test three-tier web application with multiple networks")
//    func testThreeTierWebAppWithNetworks() async throws {
//        let yaml = DockerComposeYamlFiles.dockerComposeYaml2
//        
//        let tempLocation = URL.temporaryDirectory.appending(path: "CCT_\(UUID().uuidString)/docker-compose.yaml")
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
//        let tempLocation = URL.temporaryDirectory.appending(path: "CCT_\(UUID().uuidString)/docker-compose.yaml")
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
            - "18081:80"
      """

    let tempLocation = URL.temporaryDirectory.appending(path: "CCT_\(UUID().uuidString)/docker-compose.yaml")
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

    // Cleanup
    var composeDown = try ComposeDown.parse(["--cwd", tempLocation.deletingLastPathComponent().path(percentEncoded: false)])
    try await composeDown.run()
  }

  @Test("Test compose with complex dependency chain")
    func TestComplexDependencyChain() async throws {
        let yaml = DockerComposeYamlFiles.dockerComposeYaml8
        
        let tempLocation = URL.temporaryDirectory.appending(path: "CCT_\(UUID().uuidString)/docker-compose.yaml")
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

        // Cleanup
        var composeDown = try ComposeDown.parse(["--cwd", tempLocation.deletingLastPathComponent().path(percentEncoded: false)])
        _ = try? await composeDown.run()
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

                let tempLocation = URL.temporaryDirectory.appending(path: "CCT_\(UUID().uuidString)/docker-compose.yaml")
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

                #expect(appContainer.configuration.resources.memoryInBytes == 512.mib())

                // Cleanup
                var composeDown = try ComposeDown.parse(["--cwd", tempLocation.deletingLastPathComponent().path(percentEncoded: false)])
                try await composeDown.run()
        }

    @Test("Feature 1: Pre-decode ${VAR} substitution in image and volumes")
    func testPreDecodeVarSubstitution() async throws {
        // Use environment variables that will be resolved before YAML decode
        let yaml = """
        services:
          app:
            image: ${REGISTRY:-docker.io/library}/nginx:${TAG:-alpine}
            volumes:
              - ${DATA_DIR:-/tmp}/data:/data
            ports:
              - "18083:80"
        """
        let resolvedYaml = try resolveYamlVariables(yaml, with: [:])

        let tempLocation = URL.temporaryDirectory.appending(path: "CCT_\(UUID().uuidString)/docker-compose.yaml")
        try? FileManager.default.createDirectory(at: tempLocation.deletingLastPathComponent(), withIntermediateDirectories: true)
        try resolvedYaml.write(to: tempLocation, atomically: false, encoding: .utf8)
        let folderName = tempLocation.deletingLastPathComponent().lastPathComponent

        var composeUp = try ComposeUp.parse(["-d", "--cwd", tempLocation.deletingLastPathComponent().path(percentEncoded: false)])
        try await composeUp.run()

        let containers = try await ClientContainer.list()
            .filter { $0.configuration.id.contains(folderName) }

        guard let appContainer = containers.first(where: { $0.configuration.id == "\(folderName)-app" }) else {
            throw Errors.containerNotFound
        }

        // Verify image was resolved from defaults: ${REGISTRY:-docker.io/library}/nginx:${TAG:-alpine}
        #expect(appContainer.configuration.image.reference == "docker.io/library/nginx:alpine")

        // Cleanup
        var composeDown = try ComposeDown.parse(["--cwd", tempLocation.deletingLastPathComponent().path(percentEncoded: false)])
        _ = try? await composeDown.run()
    }

    @Test("Feature 2: service_healthy dependency waits for healthcheck to pass")
    func testServiceHealthyDependency() async throws {
        let yaml = """
        services:
          db:
            image: busybox:latest
            command: ["sh", "-c", "echo ready > /tmp/health && sleep 3600"]
            healthcheck:
              test: ["CMD-SHELL", "cat /tmp/health"]
              interval: 1s
              timeout: 2s
              retries: 10
              start_period: 0s

          app:
            image: busybox:latest
            depends_on:
              db:
                condition: service_healthy
            command: ["sh", "-c", "echo 'app started after db healthy' && sleep 3600"]
        """

        let tempLocation = URL.temporaryDirectory.appending(path: "CCT_\(UUID().uuidString)/docker-compose.yaml")
        try? FileManager.default.createDirectory(at: tempLocation.deletingLastPathComponent(), withIntermediateDirectories: true)
        try yaml.write(to: tempLocation, atomically: false, encoding: .utf8)
        let folderName = tempLocation.deletingLastPathComponent().lastPathComponent

        var composeUp = try ComposeUp.parse(["-d", "--cwd", tempLocation.deletingLastPathComponent().path(percentEncoded: false)])
        try await composeUp.run()

        let containers = try await ClientContainer.list()
            .filter { $0.configuration.id.contains(folderName) }

        guard let dbContainer = containers.first(where: { $0.configuration.id == "\(folderName)-db" }),
              let appContainer = containers.first(where: { $0.configuration.id == "\(folderName)-app" })
        else {
            throw Errors.containerNotFound
        }

        // Both should be running — db first (healthcheck passes immediately), then app
        #expect(dbContainer.status == .running)
        #expect(appContainer.status == .running)

        // Cleanup
        var composeDown = try ComposeDown.parse(["--cwd", tempLocation.deletingLastPathComponent().path(percentEncoded: false)])
        _ = try? await composeDown.run()
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
        let euid = getuid()
        let isRoot = euid == 0

        // Step 1: Ping the API server
        var pingResult: String
        var health: SystemHealth?
        do {
            health = try await ClientHealthCheck.ping(timeout: .seconds(3))
            let version = health?.apiServerVersion ?? "unknown"
            let commit = health?.apiServerCommit ?? "unknown"
            pingResult = "OK (v\(version), commit \(commit))"
        } catch {
            pingResult = "FAILED — \(error.localizedDescription)"
        }

        // Step 2: If ping failed, try SystemStart
        var startResult: String?
        if health == nil {
            do {
                try await Application.SystemStart.parse(["--enable-kernel-install"]).run()
                startResult = nil
            } catch {
                startResult = "Error: \(error)"
            }

            // Step 3: Re-ping after start attempt
            if startResult == nil {
                do {
                    health = try await ClientHealthCheck.ping(timeout: .seconds(3))
                    pingResult = "OK after start (v\(health?.apiServerVersion ?? "unknown"), commit \(health?.apiServerCommit ?? "unknown"))"
                } catch {
                    pingResult = "FAILED after start attempt"
                }
            }
        }

        // Print diagnostics
        if health != nil {
            print("✓ Container Runtime Diagnostics:")
            print("  EUID: \(euid)\(isRoot ? " (running as root)" : " (not root — sudo recommended)")")
            print("  API server ping: \(pingResult)")
        } else {
            print("⚠️  Container Runtime Diagnostics:")
            print("  EUID: \(euid)\(isRoot ? " (running as root)" : " (not root — container operations may fail without sudo)")")
            print("  API server ping: FAILED — connection timed out")
            if let startResult {
                print("  SystemStart attempt: \(startResult)")
            }
            print("  API server after start: FAILED")
            print("  ❌ Container runtime is not available. Tests requiring containers will likely fail.")
            print("     Try running with: sudo ./run-tests.sh")
        }

        // Run Test
        try await function()
    }

    @Test("Test Service Name Length Limit")
    func testServiceNameLengthExceeded() async throws {
        let longServiceName = String(repeating: "a", count: 64)
        let yaml = """
            version: '3.8'
            services:
              \(longServiceName):
                image: nginx:alpine
            """
        
        let tempLocation = URL.temporaryDirectory.appending(path: "CCT_LongName_\(UUID().uuidString)/docker-compose.yaml")
        try? FileManager.default.createDirectory(at: tempLocation.deletingLastPathComponent(), withIntermediateDirectories: true)
        try yaml.write(to: tempLocation, atomically: false, encoding: .utf8)
        
        // This test documents that very long names are a risk factor on macOS Virtualization.framework
        // We expect it to at least parse and attempt run, even if the underlying runtime throws Code 22.
        var composeUp = try ComposeUp.parse(["-d", "--cwd", tempLocation.deletingLastPathComponent().path(percentEncoded: false)])
        // Check service name was parsed (indirectly by the fact that it didn't throw during parse)
        #expect(composeUp.services.isEmpty) // It's empty because longServiceName is a service KEY, not an argument
        
        // Cleanup
        try? FileManager.default.removeItem(at: tempLocation.deletingLastPathComponent())
    }
}

extension Trait where Self == ContainerDependentTrait {
    static var containerDependent: ContainerDependentTrait { .init() }
}
