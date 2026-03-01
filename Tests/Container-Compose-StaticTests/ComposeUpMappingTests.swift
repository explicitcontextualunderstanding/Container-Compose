import XCTest
@testable import ContainerComposeCore
import Yams

final class ComposeUpMappingTests: XCTestCase {
    func testRestartPolicyMapping_Always() throws {
        let yaml = """
        services:
          web:
            image: nginx:latest
            restart: always
        """
        let dockerCompose = try YAMLDecoder().decode(DockerCompose.self, from: yaml)
        guard let service = dockerCompose.services["web"] ?? nil else { return XCTFail("Service 'web' missing") }

        let args = try ComposeUp.makeRunArgs(service: service, serviceName: "web", image: nil, dockerCompose: dockerCompose, projectName: "proj", detach: false, cwd: "/tmp", environmentVariables: [:])

        XCTAssertTrue(args.contains("--restart"), "Expected --restart flag present in args: \(args)")
        XCTAssertTrue(args.contains("always"), "Expected restart value 'always' present in args: \(args)")
    }

    func testRestartPolicyMapping_No() throws {
        let yaml = """
        services:
          web:
            image: nginx:latest
            restart: "no"
        """
        let dockerCompose = try YAMLDecoder().decode(DockerCompose.self, from: yaml)
        guard let service = dockerCompose.services["web"] ?? nil else { return XCTFail("Service 'web' missing") }

        let args = try ComposeUp.makeRunArgs(service: service, serviceName: "web", image: nil, dockerCompose: dockerCompose, projectName: "proj", detach: false, cwd: "/tmp", environmentVariables: [:])

        // For "no", we either expect no --restart flag or --restart no
        if let idx = args.firstIndex(of: "--restart") {
            XCTAssertEqual(args[idx + 1], "no", "Expected restart value 'no' after --restart flag in args: \(args)")
        }
    }

    func testRestartPolicyMapping_OnFailure() throws {
        let yaml = """
        services:
          web:
            image: nginx:latest
            restart: on-failure
        """
        let dockerCompose = try YAMLDecoder().decode(DockerCompose.self, from: yaml)
        guard let service = dockerCompose.services["web"] ?? nil else { return XCTFail("Service 'web' missing") }

        let args = try ComposeUp.makeRunArgs(service: service, serviceName: "web", image: nil, dockerCompose: dockerCompose, projectName: "proj", detach: false, cwd: "/tmp", environmentVariables: [:])

        XCTAssertTrue(args.contains("--restart"), "Expected --restart flag present in args: \(args)")
        XCTAssertTrue(args.contains("on-failure"), "Expected restart value 'on-failure' present in args: \(args)")
    }

    func testRestartPolicyMapping_UnlessStopped() throws {
        let yaml = """
        services:
          web:
            image: nginx:latest
            restart: unless-stopped
        """
        let dockerCompose = try YAMLDecoder().decode(DockerCompose.self, from: yaml)
        guard let service = dockerCompose.services["web"] ?? nil else { return XCTFail("Service 'web' missing") }

        let args = try ComposeUp.makeRunArgs(service: service, serviceName: "web", image: nil, dockerCompose: dockerCompose, projectName: "proj", detach: false, cwd: "/tmp", environmentVariables: [:])

        XCTAssertTrue(args.contains("--restart"), "Expected --restart flag present in args: \(args)")
        // unless-stopped should map to always for apple/container compatibility if it doesn't support unless-stopped
        XCTAssertTrue(args.contains("always"), "Expected restart value 'always' for 'unless-stopped' in args: \(args)")
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

        let args = try ComposeUp.makeRunArgs(service: service, serviceName: "app", image: nil, dockerCompose: dockerCompose, projectName: "proj", detach: false, cwd: "/tmp", environmentVariables: [:])

        XCTAssertTrue(args.contains("--init"), "Expected --init flag present in args: \(args)")
    }

    func testInitImageFlagMapping() throws {
        let yaml = """
        services:
          app:
            image: busybox:latest
            init_image: my-custom-init:1.0
        """
        let dockerCompose = try YAMLDecoder().decode(DockerCompose.self, from: yaml)
        guard let service = dockerCompose.services["app"] ?? nil else { return XCTFail("Service 'app' missing") }

        let args = try ComposeUp.makeRunArgs(service: service, serviceName: "app", image: nil, dockerCompose: dockerCompose, projectName: "proj", detach: false, cwd: "/tmp", environmentVariables: [:])

        XCTAssertTrue(args.contains("--init-image"), "Expected --init-image flag present in args: \(args)")
        XCTAssertTrue(args.contains("my-custom-init:1.0"), "Expected init image value present in args: \(args)")
        XCTAssertTrue(args.contains("--init"), "Expected implicit --init flag when init_image is provided: \(args)")
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

        let args = try ComposeUp.makeRunArgs(service: service, serviceName: "api", image: nil, dockerCompose: dockerCompose, projectName: "proj", detach: false, cwd: "/tmp", environmentVariables: [:])

        guard let entryIdx = args.firstIndex(of: "--entrypoint"), let imageIdx = args.firstIndex(of: "nginx:latest") else {
            return XCTFail("Expected both --entrypoint and image in args: \(args)")
        }

        XCTAssertTrue(entryIdx < imageIdx, "Expected --entrypoint to appear before image, but args: \(args)")
    }
}
