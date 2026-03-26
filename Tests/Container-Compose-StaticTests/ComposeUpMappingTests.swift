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

    func testDNSSearchMapping() throws {
        let yaml = """
        services:
          app:
            image: busybox:latest
            dns_search: "my-namespace.local"
        """
        let dockerCompose = try YAMLDecoder().decode(DockerCompose.self, from: yaml)
        guard let service = dockerCompose.services["app"] ?? nil else { return XCTFail("Service 'app' missing") }

        let args = try ComposeUp.makeRunArgs(service: service, serviceName: "app", image: nil, dockerCompose: dockerCompose, projectName: "proj", detach: false, cwd: "/tmp", environmentVariables: [:])

        XCTAssertTrue(args.contains("--dns-search"), "Expected --dns-search flag present in args: \(args)")
        XCTAssertTrue(args.contains("my-namespace.local"), "Expected dns search value present in args: \(args)")
    }

    // MARK: - Previously untested makeRunArgs flags

    func testUserMapping() throws {
        let yaml = """
        services:
          app:
            image: busybox:latest
            user: "1000:1000"
        """
        let dockerCompose = try YAMLDecoder().decode(DockerCompose.self, from: yaml)
        guard let service = dockerCompose.services["app"] ?? nil else { return XCTFail("Service 'app' missing") }

        let args = try ComposeUp.makeRunArgs(service: service, serviceName: "app", image: nil, dockerCompose: dockerCompose, projectName: "proj", detach: false, cwd: "/tmp", environmentVariables: [:])

        XCTAssertTrue(args.contains("--user"), "Expected --user flag in args: \(args)")
        XCTAssertTrue(args.contains("1000:1000"), "Expected user value in args: \(args)")
    }

    func testHostnameMapping() throws {
        let yaml = """
        services:
          app:
            image: busybox:latest
            hostname: myhost
        """
        let dockerCompose = try YAMLDecoder().decode(DockerCompose.self, from: yaml)
        guard let service = dockerCompose.services["app"] ?? nil else { return XCTFail("Service 'app' missing") }

        let args = try ComposeUp.makeRunArgs(service: service, serviceName: "app", image: nil, dockerCompose: dockerCompose, projectName: "proj", detach: false, cwd: "/tmp", environmentVariables: [:])

        XCTAssertTrue(args.contains("--hostname"), "Expected --hostname flag in args: \(args)")
        XCTAssertTrue(args.contains("myhost"), "Expected hostname value in args: \(args)")
    }

    func testWorkingDirMapping() throws {
        let yaml = """
        services:
          app:
            image: busybox:latest
            working_dir: /app
        """
        let dockerCompose = try YAMLDecoder().decode(DockerCompose.self, from: yaml)
        guard let service = dockerCompose.services["app"] ?? nil else { return XCTFail("Service 'app' missing") }

        let args = try ComposeUp.makeRunArgs(service: service, serviceName: "app", image: nil, dockerCompose: dockerCompose, projectName: "proj", detach: false, cwd: "/tmp", environmentVariables: [:])

        XCTAssertTrue(args.contains("--workdir"), "Expected --workdir flag in args: \(args)")
        XCTAssertTrue(args.contains("/app"), "Expected working_dir value in args: \(args)")
    }

    func testPrivilegedMapping() throws {
        let yaml = """
        services:
          app:
            image: busybox:latest
            privileged: true
        """
        let dockerCompose = try YAMLDecoder().decode(DockerCompose.self, from: yaml)
        guard let service = dockerCompose.services["app"] ?? nil else { return XCTFail("Service 'app' missing") }

        let args = try ComposeUp.makeRunArgs(service: service, serviceName: "app", image: nil, dockerCompose: dockerCompose, projectName: "proj", detach: false, cwd: "/tmp", environmentVariables: [:])

        XCTAssertTrue(args.contains("--privileged"), "Expected --privileged flag in args: \(args)")
    }

    func testReadOnlyMapping() throws {
        let yaml = """
        services:
          app:
            image: busybox:latest
            read_only: true
        """
        let dockerCompose = try YAMLDecoder().decode(DockerCompose.self, from: yaml)
        guard let service = dockerCompose.services["app"] ?? nil else { return XCTFail("Service 'app' missing") }

        let args = try ComposeUp.makeRunArgs(service: service, serviceName: "app", image: nil, dockerCompose: dockerCompose, projectName: "proj", detach: false, cwd: "/tmp", environmentVariables: [:])

        XCTAssertTrue(args.contains("--read-only"), "Expected --read-only flag in args: \(args)")
    }

    func testTtyAndStdinOpenMapping() throws {
        let yaml = """
        services:
          app:
            image: busybox:latest
            tty: true
            stdin_open: true
        """
        let dockerCompose = try YAMLDecoder().decode(DockerCompose.self, from: yaml)
        guard let service = dockerCompose.services["app"] ?? nil else { return XCTFail("Service 'app' missing") }

        let args = try ComposeUp.makeRunArgs(service: service, serviceName: "app", image: nil, dockerCompose: dockerCompose, projectName: "proj", detach: false, cwd: "/tmp", environmentVariables: [:])

        XCTAssertTrue(args.contains("-t"), "Expected -t flag in args: \(args)")
        XCTAssertTrue(args.contains("-i"), "Expected -i flag in args: \(args)")
    }

    func testDetachFlag() throws {
        let yaml = """
        services:
          app:
            image: busybox:latest
        """
        let dockerCompose = try YAMLDecoder().decode(DockerCompose.self, from: yaml)
        guard let service = dockerCompose.services["app"] ?? nil else { return XCTFail("Service 'app' missing") }

        let args = try ComposeUp.makeRunArgs(service: service, serviceName: "app", image: nil, dockerCompose: dockerCompose, projectName: "proj", detach: true, cwd: "/tmp", environmentVariables: [:])

        XCTAssertTrue(args.contains("-d"), "Expected -d flag in args: \(args)")
    }

    func testPortMapping() throws {
        let yaml = """
        services:
          app:
            image: nginx:latest
            ports:
              - "8080:80"
              - "9090:443"
        """
        let dockerCompose = try YAMLDecoder().decode(DockerCompose.self, from: yaml)
        guard let service = dockerCompose.services["app"] ?? nil else { return XCTFail("Service 'app' missing") }

        let args = try ComposeUp.makeRunArgs(service: service, serviceName: "app", image: nil, dockerCompose: dockerCompose, projectName: "proj", detach: false, cwd: "/tmp", environmentVariables: [:])

        XCTAssertTrue(args.contains("--publish"), "Expected --publish flag in args: \(args)")
        XCTAssertTrue(args.contains("8080:80"), "Expected port mapping 8080:80 in args: \(args)")
        XCTAssertTrue(args.contains("9090:443"), "Expected port mapping 9090:443 in args: \(args)")
    }

    func testEnvironmentVariableMapping() throws {
        let yaml = """
        services:
          app:
            image: busybox:latest
        """
        let dockerCompose = try YAMLDecoder().decode(DockerCompose.self, from: yaml)
        guard let service = dockerCompose.services["app"] ?? nil else { return XCTFail("Service 'app' missing") }

        let envVars = ["DB_HOST": "db", "DB_PORT": "5432"]
        let args = try ComposeUp.makeRunArgs(service: service, serviceName: "app", image: nil, dockerCompose: dockerCompose, projectName: "proj", detach: false, cwd: "/tmp", environmentVariables: envVars)

        XCTAssertTrue(args.contains("--env"), "Expected --env flag in args: \(args)")
        XCTAssertTrue(args.contains("DB_HOST=db"), "Expected DB_HOST=db in args: \(args)")
        XCTAssertTrue(args.contains("DB_PORT=5432"), "Expected DB_PORT=5432 in args: \(args)")
    }

    func testContainerNameFromService() throws {
        let yaml = """
        services:
          app:
            image: busybox:latest
        """
        let dockerCompose = try YAMLDecoder().decode(DockerCompose.self, from: yaml)
        guard let service = dockerCompose.services["app"] ?? nil else { return XCTFail("Service 'app' missing") }

        let args = try ComposeUp.makeRunArgs(service: service, serviceName: "app", image: nil, dockerCompose: dockerCompose, projectName: "myproject", detach: false, cwd: "/tmp", environmentVariables: [:])

        XCTAssertTrue(args.contains("--name"), "Expected --name flag in args: \(args)")
        XCTAssertTrue(args.contains("myproject-app"), "Expected container name 'myproject-app' in args: \(args)")
    }

    func testExplicitContainerName() throws {
        let yaml = """
        services:
          app:
            image: busybox:latest
            container_name: my-custom-name
        """
        let dockerCompose = try YAMLDecoder().decode(DockerCompose.self, from: yaml)
        guard let service = dockerCompose.services["app"] ?? nil else { return XCTFail("Service 'app' missing") }

        let args = try ComposeUp.makeRunArgs(service: service, serviceName: "app", image: nil, dockerCompose: dockerCompose, projectName: "myproject", detach: false, cwd: "/tmp", environmentVariables: [:])

        XCTAssertTrue(args.contains("--name"), "Expected --name flag in args: \(args)")
        XCTAssertTrue(args.contains("my-custom-name"), "Expected explicit container name 'my-custom-name' in args: \(args)")
        XCTAssertFalse(args.contains("myproject-app"), "Should NOT contain generated name when explicit name is set")
    }
}
