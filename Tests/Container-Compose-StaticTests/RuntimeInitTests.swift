import XCTest
@testable import ContainerComposeCore
import Yams

final class RuntimeInitTests: XCTestCase {
    func testRuntimeFlagMapping() throws {
        let yaml = """
        services:
          worker:
            image: busybox:latest
            runtime: kata
        """
        let dockerCompose = try YAMLDecoder().decode(DockerCompose.self, from: yaml)
        guard let service = dockerCompose.services["worker"] ?? nil else { return XCTFail("Service 'worker' missing") }

        let args = try ComposeUp.makeRunArgs(service: service, serviceName: "worker", dockerCompose: dockerCompose, projectName: "proj", detach: false, cwd: "/tmp", environmentVariables: [:])

        XCTAssertTrue(args.contains("--runtime"))
        XCTAssertTrue(args.contains("kata"))
    }

    func testInitImageFlagMapping() throws {
        let yaml = """
        services:
          db:
            image: postgres:latest
            init: true
            init_image: custom/init-img:1.2
        """
        let dockerCompose = try YAMLDecoder().decode(DockerCompose.self, from: yaml)
        guard let service = dockerCompose.services["db"] ?? nil else { return XCTFail("Service 'db' missing") }

        let args = try ComposeUp.makeRunArgs(service: service, serviceName: "db", dockerCompose: dockerCompose, projectName: "proj", detach: false, cwd: "/tmp", environmentVariables: [:])

        XCTAssertTrue(args.contains("--init-image"))
        XCTAssertTrue(args.contains("custom/init-img:1.2"))
        XCTAssertTrue(args.contains("--init"))
    }
}
