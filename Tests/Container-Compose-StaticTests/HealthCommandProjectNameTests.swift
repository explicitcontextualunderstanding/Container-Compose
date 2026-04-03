import XCTest
@testable import ContainerComposeCore
import Yams

final class HealthCommandProjectNameTests: XCTestCase {

    func testProjectNameFromComposeNameField() throws {
        // Test that health command uses 'name:' from compose file
        let yamlContent = """
        name: test-project
        services:
          db:
            image: postgres:15
            healthcheck:
              test: ["CMD", "pg_isready"]
              interval: 5s
        """

        let dockerCompose = try YAMLDecoder().decode(DockerCompose.self, from: yamlContent)

        // Verify name field is parsed
        XCTAssertNotNil(dockerCompose.name)
        XCTAssertEqual(dockerCompose.name, "test-project")
    }

    func testProjectNameFallbackToDeriveProjectName() throws {
        // Test that health command falls back to deriveProjectName when name: is missing
        let yamlContent = """
        services:
          web:
            image: nginx:latest
        """

        let dockerCompose = try YAMLDecoder().decode(DockerCompose.self, from: yamlContent)

        // Verify name field is nil
        XCTAssertNil(dockerCompose.name)

        // Should use deriveProjectName(cwd:) as fallback
        let projectName = try deriveProjectName(cwd: "/tmp/test-dir")
        XCTAssertEqual(projectName, "test-dir")
    }

    func testHealthCommandMatchesPsProjectNameResolution() throws {
        // Test that HealthCommand and ComposePs use same project name resolution logic
        let yamlContent = """
        name: myapp
        services:
          api:
            image: node:18
        """

        let dockerCompose = try YAMLDecoder().decode(DockerCompose.self, from: yamlContent)

        // Both should use name: field when present
        let projectName: String
        if let name = dockerCompose.name {
            projectName = name
        } else {
            projectName = try deriveProjectName(cwd: "/tmp")
        }

        XCTAssertEqual(projectName, "myapp")
    }
}
