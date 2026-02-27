import XCTest
@testable import ContainerComposeCore
import Yams

final class ComposeUpMappingTests: XCTestCase {
    func testRestartPolicyMapping() throws {
        let yaml = """
        services:
          web:
            image: nginx:latest
            restart: always
        """
        let dockerCompose = try YAMLDecoder().decode(DockerCompose.self, from: yaml)
        guard let service = dockerCompose.services["web"] ?? nil else { return XCTFail("Service 'web' missing") }

        // Expected: a helper that builds run args from a service. Tests written first (TDD).
        let args = try ComposeUp.makeRunArgs(service: service, serviceName: "web", dockerCompose: dockerCompose, projectName: "proj", detach: false, cwd: "/tmp", environmentVariables: [:])

        XCTAssertTrue(args.contains("--restart"), "Expected --restart flag present in args: \(args)")
        XCTAssertTrue(args.contains("always"), "Expected restart value 'always' present in args: \(args)")
    }

    func testInitFlagMapping() throws {
        let yaml = """
        services:
          app:
            image: busybox:latest
            init: true
        """
        let dockerCompose = try YAMLDecoder().decode(DockerCompose.self, from: yaml)
        guard let service = dockerCompose.services["app"] ?? nil else { return XCTFail("Service 'app' missing") }

        let args = try ComposeUp.makeRunArgs(service: service, serviceName: "app", dockerCompose: dockerCompose, projectName: "proj", detach: false, cwd: "/tmp", environmentVariables: [:])

        XCTAssertTrue(args.contains("--init"), "Expected --init flag present in args: \(args)")
    }

    func testEntrypointPlacedBeforeImage() throws {
        let yaml = """
        services:
          api:
            image: nginx:latest
            entrypoint: ["/bin/sh", "-c"]
        """
        let dockerCompose = try YAMLDecoder().decode(DockerCompose.self, from: yaml)
        guard let service = dockerCompose.services["api"] ?? nil else { return XCTFail("Service 'api' missing") }

        let args = try ComposeUp.makeRunArgs(service: service, serviceName: "api", dockerCompose: dockerCompose, projectName: "proj", detach: false, cwd: "/tmp", environmentVariables: [:])

        guard let entryIdx = args.firstIndex(of: "--entrypoint"), let imageIdx = args.firstIndex(of: "nginx:latest") else {
            return XCTFail("Expected both --entrypoint and image in args: \(args)")
        }

        XCTAssertTrue(entryIdx < imageIdx, "Expected --entrypoint to appear before image, but args: \(args)")
    }
}
