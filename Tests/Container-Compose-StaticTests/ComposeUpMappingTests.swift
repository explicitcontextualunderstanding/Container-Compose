import XCTest
@testable import ContainerComposeCore
import Yams
import ArgumentParser

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

    func testDNSMappingSingleString() throws {
        let yaml = """
        services:
          app:
            image: busybox:latest
            dns: "8.8.8.8"
        """
        let dockerCompose = try YAMLDecoder().decode(DockerCompose.self, from: yaml)
        guard let service = dockerCompose.services["app"] ?? nil else { return XCTFail("Service 'app' missing") }

        let args = try ComposeUp.makeRunArgs(service: service, serviceName: "app", image: nil, dockerCompose: dockerCompose, projectName: "proj", detach: false, cwd: "/tmp", environmentVariables: [:])

        XCTAssertTrue(args.contains("--dns"), "Expected --dns flag present in args: \(args)")
        XCTAssertTrue(args.contains("8.8.8.8"), "Expected DNS value present in args: \(args)")
    }

    func testDNSMappingArray() throws {
        let yaml = """
        services:
          app:
            image: busybox:latest
            dns:
              - "8.8.8.8"
              - "1.1.1.1"
        """
        let dockerCompose = try YAMLDecoder().decode(DockerCompose.self, from: yaml)
        guard let service = dockerCompose.services["app"] ?? nil else { return XCTFail("Service 'app' missing") }

        let args = try ComposeUp.makeRunArgs(service: service, serviceName: "app", image: nil, dockerCompose: dockerCompose, projectName: "proj", detach: false, cwd: "/tmp", environmentVariables: [:])

        XCTAssertTrue(args.contains("--dns"), "Expected --dns flag present in args: \(args)")
        XCTAssertTrue(args.contains("8.8.8.8"), "Expected first DNS value present in args: \(args)")
        XCTAssertTrue(args.contains("1.1.1.1"), "Expected second DNS value present in args: \(args)")
    }

    func testDNSMappingNil() throws {
        let yaml = """
        services:
          app:
            image: busybox:latest
        """
        let dockerCompose = try YAMLDecoder().decode(DockerCompose.self, from: yaml)
        guard let service = dockerCompose.services["app"] ?? nil else { return XCTFail("Service 'app' missing") }

        let args = try ComposeUp.makeRunArgs(service: service, serviceName: "app", image: nil, dockerCompose: dockerCompose, projectName: "proj", detach: false, cwd: "/tmp", environmentVariables: [:])

        XCTAssertFalse(args.contains("--dns"), "Expected --dns flag NOT present in args: \(args)")
    }

    func testDNSAndDNSSearchMapping() throws {
        let yaml = """
        services:
          app:
            image: busybox:latest
            dns:
              - "8.8.8.8"
            dns_search:
              - "local"
              - "internal"
        """
        let dockerCompose = try YAMLDecoder().decode(DockerCompose.self, from: yaml)
        guard let service = dockerCompose.services["app"] ?? nil else { return XCTFail("Service 'app' missing") }

        let args = try ComposeUp.makeRunArgs(service: service, serviceName: "app", image: nil, dockerCompose: dockerCompose, projectName: "proj", detach: false, cwd: "/tmp", environmentVariables: [:])

        XCTAssertTrue(args.contains("--dns"), "Expected --dns flag present in args: \(args)")
        XCTAssertTrue(args.contains("8.8.8.8"), "Expected DNS value present in args: \(args)")
        XCTAssertTrue(args.contains("--dns-search"), "Expected --dns-search flag present in args: \(args)")
        XCTAssertTrue(args.contains("local"), "Expected first dns_search value present in args: \(args)")
        XCTAssertTrue(args.contains("internal"), "Expected second dns_search value present in args: \(args)")
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

    // MARK: - __SERVICE_HOST__ / __SERVICE_PORT__ placeholder resolution

    private func resolve(
        _ value: String,
        ips: [String: String] = [:],
        ports: [String: String] = [:],
        services: [String] = []
    ) -> String {
        ComposeUp.resolveServicePlaceholder(value, containerIps: ips, containerPorts: ports, knownServiceNames: services)
    }

    func testServiceHostResolvesToKnownIP() {
        let result = resolve(
            "__HONCHO_DB_HOST__",
            ips: ["honcho-db": "192.168.64.5"],
            services: ["honcho-db", "honcho-hub"]
        )
        XCTAssertEqual(result, "192.168.64.5")
    }

    func testServicePortResolvesToContainerPort() {
        let result = resolve(
            "__HONCHO_DB_PORT__",
            ports: ["honcho-db": "5432"],
            services: ["honcho-db", "honcho-hub"]
        )
        XCTAssertEqual(result, "5432")
    }

    func testUnknownServiceHostLeftUntouched() {
        let result = resolve(
            "__FOO_HOST__",
            ips: ["honcho-db": "192.168.64.5"],
            services: ["honcho-db", "honcho-hub"]
        )
        XCTAssertEqual(result, "__FOO_HOST__")
    }

    func testDialecticLevelsNotTreatedAsPlaceholder() {
        // DIALECTIC__LEVELS__minimal__PROVIDER has consecutive __ but doesn't
        // match the __{NAME}_(HOST|PORT)__ pattern, so it must be left alone.
        let result = resolve(
            "DIALECTIC__LEVELS__minimal__PROVIDER",
            ips: ["minimal": "10.0.0.1"],
            services: ["minimal"]
        )
        XCTAssertEqual(result, "DIALECTIC__LEVELS__minimal__PROVIDER")
    }

    func testMixedPlaceholdersAndVarRef() {
        let result = resolve(
            "postgresql://__HONCHO_DB_HOST__:__HONCHO_DB_PORT__/mydb",
            ips: ["honcho-db": "192.168.64.5"],
            ports: ["honcho-db": "5432"],
            services: ["honcho-db"]
        )
        XCTAssertEqual(result, "postgresql://192.168.64.5:5432/mydb")
    }

    func testFuzzyMatchingCaseInsensitive() {
        // Lowercase input should still match service "honcho-db"
        let result = resolve(
            "__honcho_db_host__",
            ips: ["honcho-db": "192.168.64.5"],
            services: ["honcho-db"]
        )
        XCTAssertEqual(result, "192.168.64.5")
    }

    func testFuzzyMatchingStripsHyphensAndUnderscores() {
        // HONCHODB (no separator) should match service "honcho-db"
        let result = resolve(
            "__HONCHODB_HOST__",
            ips: ["honcho-db": "192.168.64.5"],
            services: ["honcho-db"]
        )
        XCTAssertEqual(result, "192.168.64.5")
    }

    func testNoPlaceholderLeftAsIs() {
        let result = resolve("plain_value", ips: ["db": "10.0.0.1"], services: ["db"])
        XCTAssertEqual(result, "plain_value")
    }

    func testUnknownPortLeftUntouched() {
        let result = resolve(
            "__FOO_PORT__",
            ports: ["bar": "8080"],
            services: ["bar"]
        )
        XCTAssertEqual(result, "__FOO_PORT__")
    }

    // MARK: - -f flag path resolution

    func testAbsolutePathPreserved() throws {
        var cmd = try ComposeUp.parse(["-f", "/absolute/path/compose.yml", "--cwd", "/tmp/dir"])
        XCTAssertEqual(cmd.composeFile, "/absolute/path/compose.yml")
        XCTAssertEqual(cmd.composePath, "/absolute/path/compose.yml")
    }

    func testRelativePathJoinedWithCwd() throws {
        var cmd = try ComposeUp.parse(["-f", "relative.yml", "--cwd", "/tmp/dir"])
        XCTAssertEqual(cmd.composeFile, "relative.yml")
        XCTAssertEqual(cmd.composePath, "/tmp/dir/relative.yml")
    }

    func testDefaultComposePathUsesCwd() throws {
        var cmd = try ComposeUp.parse(["--cwd", "/tmp/dir"])
        XCTAssertNil(cmd.composeFile)
        XCTAssertEqual(cmd.composePath, "/tmp/dir/compose.yml")
    }

    func testNoDashFScanningNotOverridden() throws {
        // When -f is not provided, composeFile should be nil (scanning runs)
        var cmd = try ComposeUp.parse(["--cwd", "/home/user/project"])
        XCTAssertNil(cmd.composeFile, "composeFile should be nil when -f is not provided")
    }

    func testDashFOverridesScanning() throws {
        // When -f is explicitly provided, scanning should be skipped
        var cmd = try ComposeUp.parse(["-f", "/custom/path.yml"])
        XCTAssertNotNil(cmd.composeFile, "composeFile should be set when -f is provided")
        XCTAssertEqual(cmd.composePath, "/custom/path.yml")
    }

    // MARK: - Validation Tests

    func testRecoverMutuallyExclusiveWithBuild() throws {
        // ArgumentParser enforces mutual exclusivity during parse(), before validate() runs
        XCTAssertThrowsError(try ComposeUp.parse(["--recover", "--build"]), "Expected parse error when both --recover and --build are provided") { error in
            XCTAssertTrue(String(describing: error).contains("mutually exclusive"), "Error should mention mutual exclusivity, got: \(error)")
        }
    }

    func testRecoverMutuallyExclusiveWithForceRecreate() throws {
        XCTAssertThrowsError(try ComposeUp.parse(["--recover", "--force-recreate"]), "Expected parse error when both --recover and --force-recreate are provided") { error in
            XCTAssertTrue(String(describing: error).contains("mutually exclusive"), "Error should mention mutual exclusivity, got: \(error)")
        }
    }

    // MARK: - Volume Mapping Tests

    func testBindMountMapping() throws {
        let yaml = """
            services:
              app:
                image: busybox:latest
                volumes:
                  - ./data:/app/data
            """
        let dockerCompose = try YAMLDecoder().decode(DockerCompose.self, from: yaml)
        guard let service = dockerCompose.services["app"] ?? nil else { return XCTFail("Service 'app' missing") }

        let args = try ComposeUp.makeRunArgs(service: service, serviceName: "app", image: nil, dockerCompose: dockerCompose, projectName: "proj", detach: false, cwd: "/tmp", environmentVariables: [:])

        // Find -v flag and its argument
        guard let vIndex = args.firstIndex(of: "-v") else {
            return XCTFail("Expected -v flag in args: \(args)")
        }
        guard vIndex + 1 < args.count else {
            return XCTFail("Expected volume argument after -v flag")
        }
        let volumeArg = args[vIndex + 1]
        XCTAssertEqual(volumeArg, "./data:/app/data", "Expected bind mount volume argument")
    }

    func testNamedVolumeMapping() throws {
        let yaml = """
            services:
              app:
                image: busybox:latest
                volumes:
                  - mydata:/app/data
            """
        let dockerCompose = try YAMLDecoder().decode(DockerCompose.self, from: yaml)
        guard let service = dockerCompose.services["app"] ?? nil else { return XCTFail("Service 'app' missing") }

        let args = try ComposeUp.makeRunArgs(service: service, serviceName: "app", image: nil, dockerCompose: dockerCompose, projectName: "proj", detach: false, cwd: "/tmp", environmentVariables: [:])

        // Find -v flag and its argument
        guard let vIndex = args.firstIndex(of: "-v") else {
            return XCTFail("Expected -v flag in args: \(args)")
        }
        guard vIndex + 1 < args.count else {
            return XCTFail("Expected volume argument after -v flag")
        }
        let volumeArg = args[vIndex + 1]
        // Named volumes should be mapped to ~/.containers/Volumes/{projectName}/{source}
        XCTAssertTrue(volumeArg.contains("mydata"), "Expected named volume path to contain 'mydata': \(volumeArg)")
        XCTAssertTrue(volumeArg.contains("/app/data"), "Expected named volume destination '/app/data': \(volumeArg)")
    }

    func testAbsolutePathBindMountMappingWithinCwd() throws {
        // Absolute paths within the project directory should work
        // Using /tmp as cwd, so /tmp/var/log is within the project directory
        let yaml = """
            services:
              app:
                image: busybox:latest
                volumes:
                  - /tmp/var/log:/app/logs
            """
        let dockerCompose = try YAMLDecoder().decode(DockerCompose.self, from: yaml)
        guard let service = dockerCompose.services["app"] ?? nil else { return XCTFail("Service 'app' missing") }

        let args = try ComposeUp.makeRunArgs(service: service, serviceName: "app", image: nil, dockerCompose: dockerCompose, projectName: "proj", detach: false, cwd: "/tmp", environmentVariables: [:])

        // Find -v flag and its argument
        guard let vIndex = args.firstIndex(of: "-v") else {
            return XCTFail("Expected -v flag in args: \(args)")
        }
        guard vIndex + 1 < args.count else {
            return XCTFail("Expected volume argument after -v flag")
        }
        let volumeArg = args[vIndex + 1]
        XCTAssertEqual(volumeArg, "/tmp/var/log:/app/logs", "Expected absolute path bind mount within cwd")
    }

    func testOutsidePathSecuritySkipped() throws {
        // Absolute paths outside the project directory should be skipped for security
        let yaml = """
            services:
              app:
                image: busybox:latest
                volumes:
                  - /var/log:/app/logs
            """
        let dockerCompose = try YAMLDecoder().decode(DockerCompose.self, from: yaml)
        guard let service = dockerCompose.services["app"] ?? nil else { return XCTFail("Service 'app' missing") }

        let args = try ComposeUp.makeRunArgs(service: service, serviceName: "app", image: nil, dockerCompose: dockerCompose, projectName: "proj", detach: false, cwd: "/tmp", environmentVariables: [:])

        // Should NOT have -v flag because /var/log is outside /tmp
        XCTAssertNil(args.firstIndex(of: "-v"), "Should skip volumes outside project directory")
    }

// MARK: - Registry scheme (Apple Container 0.11.0+ extension)

func testSchemeMappingHttps() throws {
    // Container 0.11.0+ is installed and available
 
 let yaml = """
        services:
          app:
            image: 192.168.1.86:30500/myimage:latest
            scheme: https
        """
 let dockerCompose = try YAMLDecoder().decode(DockerCompose.self, from: yaml)
 guard let service = dockerCompose.services["app"] ?? nil else { return XCTFail("Service 'app' missing") }

 let args = try ComposeUp.makeRunArgs(service: service, serviceName: "app", image: nil, dockerCompose: dockerCompose, projectName: "proj", detach: false, cwd: "/tmp", environmentVariables: [:])

 XCTAssertTrue(args.contains("--scheme"), "Expected --scheme flag in args: \(args)")
 let schemeIdx = args.firstIndex(of: "--scheme")!
 XCTAssertEqual(args[args.index(after: schemeIdx)], "https", "Expected https scheme value")
 }

func testSchemeMappingHttp() throws {
    // Container 0.11.0+ is installed and available
 
 let yaml = """
        services:
          app:
            image: registry.local:5000/myimage:latest
            scheme: http
        """
 let dockerCompose = try YAMLDecoder().decode(DockerCompose.self, from: yaml)
 guard let service = dockerCompose.services["app"] ?? nil else { return XCTFail("Service 'app' missing") }

 let args = try ComposeUp.makeRunArgs(service: service, serviceName: "app", image: nil, dockerCompose: dockerCompose, projectName: "proj", detach: false, cwd: "/tmp", environmentVariables: [:])

 XCTAssertTrue(args.contains("--scheme"), "Expected --scheme flag in args: \(args)")
 let schemeIdx = args.firstIndex(of: "--scheme")!
 XCTAssertEqual(args[args.index(after: schemeIdx)], "http", "Expected http scheme value")
 }

    func testSchemeOmitted() throws {
        let yaml = """
        services:
          app:
            image: busybox:latest
        """
        let dockerCompose = try YAMLDecoder().decode(DockerCompose.self, from: yaml)
        guard let service = dockerCompose.services["app"] ?? nil else { return XCTFail("Service 'app' missing") }

        let args = try ComposeUp.makeRunArgs(service: service, serviceName: "app", image: nil, dockerCompose: dockerCompose, projectName: "proj", detach: false, cwd: "/tmp", environmentVariables: [:])

        XCTAssertFalse(args.contains("--scheme"), "Should not have --scheme flag when not specified: \(args)")
    }

    func testSchemeInvalidValue() throws {
        let yaml = """
        services:
          app:
            image: busybox:latest
            scheme: ftp
        """
        XCTAssertThrowsError(try YAMLDecoder().decode(DockerCompose.self, from: yaml)) { error in
            XCTAssertTrue(error is DecodingError, "Expected DecodingError for invalid scheme, got: \(error)")
        }
    }

    func testSchemeValidationAtDecodeTime() throws {
        let yaml = """
        services:
          app:
            image: busybox:latest
            scheme: invalid
        """
        do {
            _ = try YAMLDecoder().decode(DockerCompose.self, from: yaml)
            XCTFail("Should have thrown for invalid scheme value")
        } catch {
            guard error is DecodingError else {
                XCTFail("Expected DecodingError, got: \(error)")
                return
            }
        }
    }
}
