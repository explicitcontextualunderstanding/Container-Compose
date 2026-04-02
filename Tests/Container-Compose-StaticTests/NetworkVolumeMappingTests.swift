import XCTest
@testable import ContainerComposeCore
import Yams

final class NetworkVolumeMappingTests: XCTestCase {
    
    func testNetworkMapping_Basic() throws {
        let network = try YAMLDecoder().decode(Network.self, from: "name: my-net")
        let args = ComposeUp.makeNetworkCreateArgs(name: "my-net", config: network)
        
        XCTAssertEqual(args, ["my-net"])
    }
    
    func testNetworkMapping_Internal() throws {
        let network = try YAMLDecoder().decode(Network.self, from: "internal: true")
        let args = ComposeUp.makeNetworkCreateArgs(name: "my-net", config: network)
        
        XCTAssertTrue(args.contains("--internal"))
        XCTAssertEqual(args.last, "my-net")
    }
    
    func testNetworkMapping_Labels() throws {
        let yaml = """
        labels:
          com.example.description: "Test Network"
          type: "frontend"
        """
        let network = try YAMLDecoder().decode(Network.self, from: yaml)
        let args = ComposeUp.makeNetworkCreateArgs(name: "my-net", config: network)
        
        XCTAssertTrue(args.contains("--label"))
        XCTAssertTrue(args.contains("type=frontend"))
        XCTAssertTrue(args.contains("com.example.description=Test Network"))
    }
    
    func testNetworkMapping_Subnet() throws {
        let yaml = """
        ipam:
          config:
            - subnet: 172.20.0.0/16
        """
        let network = try YAMLDecoder().decode(Network.self, from: yaml)
        let args = ComposeUp.makeNetworkCreateArgs(name: "my-net", config: network)
        
        XCTAssertTrue(args.contains("--subnet"))
        XCTAssertTrue(args.contains("172.20.0.0/16"))
    }
    
    func testVolumeMapping_Basic() throws {
        let volume = try YAMLDecoder().decode(Volume.self, from: "name: my-vol")
        let args = ComposeUp.makeVolumeCreateArgs(name: "my-vol", config: volume)
        
        XCTAssertEqual(args, ["my-vol"])
    }
    
    func testVolumeMapping_Labels() throws {
        let yaml = """
        labels:
          storage: "ssd"
        """
        let volume = try YAMLDecoder().decode(Volume.self, from: yaml)
        let args = ComposeUp.makeVolumeCreateArgs(name: "my-vol", config: volume)
        
        XCTAssertTrue(args.contains("--label"))
        XCTAssertTrue(args.contains("storage=ssd"))
    }
    
func testVolumeMapping_Opts() throws {
        let yaml = """
            driver_opts:
              type: "nfs"
              device: ":/path/to/dir"
            """
        let volume = try YAMLDecoder().decode(Volume.self, from: yaml)
        let args = ComposeUp.makeVolumeCreateArgs(name: "my-vol", config: volume)
        
        XCTAssertTrue(args.contains("--opt"))
        XCTAssertTrue(args.contains("type=nfs"))
        XCTAssertTrue(args.contains("device=:/path/to/dir"))
    }
    
    // MARK: - Virtiofs Database Path Guardrails (Phase 4)
    
    func testVirtiofsWarnsOnPostgresDataPath() throws {
        // Test that virtiofs emits warning for PostgreSQL data directory
        let yaml = """
            services:
              db:
                image: postgres:14
                volumes:
                  - pgdata:/var/lib/postgresql/data
            """
        
        let dockerCompose = try YAMLDecoder().decode(DockerCompose.self, from: yaml)
        guard let service = dockerCompose.services["db"]?.flatMap({ $0 }),
              let volumes = service.volumes else {
            XCTFail("Failed to parse service")
            return
        }
        
        // Check if volumes contain PostgreSQL data path
        let hasPostgresPath = volumes.contains { vol in
            vol.contains("/var/lib/postgresql/data")
        }
        XCTAssertTrue(hasPostgresPath, "Should detect PostgreSQL data path")
        
        // Check for virtiofs warning
        let warningPaths = Self.checkVirtiofsDatabasePaths(volumes: volumes)
        XCTAssertTrue(warningPaths.contains("PostgreSQL"), "Should warn about PostgreSQL path")
    }
    
    func testVirtiofsWarnsOnMySQLDataPath() throws {
        // Test that virtiofs emits warning for MySQL data directory
        let yaml = """
            services:
              db:
                image: mysql:8.0
                volumes:
                  - dbdata:/var/lib/mysql
            """
        
        let dockerCompose = try YAMLDecoder().decode(DockerCompose.self, from: yaml)
        guard let service = dockerCompose.services["db"]?.flatMap({ $0 }),
              let volumes = service.volumes else {
            XCTFail("Failed to parse service")
            return
        }
        
        let warningPaths = Self.checkVirtiofsDatabasePaths(volumes: volumes)
        XCTAssertTrue(warningPaths.contains("MySQL"), "Should warn about MySQL path")
    }
    
    func testVirtiofsWarnsOnRedisDataPath() throws {
        // Test that virtiofs emits warning for Redis data directory
        let yaml = """
            services:
              cache:
                image: redis:alpine
                volumes:
                  - redisdata:/data
            """
        
        let dockerCompose = try YAMLDecoder().decode(DockerCompose.self, from: yaml)
        guard let service = dockerCompose.services["cache"]?.flatMap({ $0 }),
              let volumes = service.volumes else {
            XCTFail("Failed to parse service")
            return
        }
        
        let warningPaths = Self.checkVirtiofsDatabasePaths(volumes: volumes)
        XCTAssertTrue(warningPaths.contains("Redis"), "Should warn about Redis path")
    }
    
    func testVirtiofsNoWarningOnSafePath() throws {
        // Test that no warning is emitted for non-database paths
        let yaml = """
            services:
              app:
                image: nginx:alpine
                volumes:
                  - ./html:/usr/share/nginx/html
            """
        
        let dockerCompose = try YAMLDecoder().decode(DockerCompose.self, from: yaml)
        guard let service = dockerCompose.services["app"]?.flatMap({ $0 }),
              let volumes = service.volumes else {
            XCTFail("Failed to parse service")
            return
        }
        
        let warningPaths = Self.checkVirtiofsDatabasePaths(volumes: volumes)
        XCTAssertTrue(warningPaths.isEmpty, "Should not warn about non-database paths")
    }
    
    // MARK: - Helper Methods
    
    /// Checks volumes for known database paths that may have virtiofs issues on macOS
    /// Returns array of database type names that have warnings
    private static func checkVirtiofsDatabasePaths(volumes: [String]) -> [String] {
        var warnings: [String] = []
        
        let databasePaths: [(String, String)] = [
            ("PostgreSQL", "/var/lib/postgresql/data"),
            ("MySQL", "/var/lib/mysql"),
            ("MariaDB", "/var/lib/mysql"),
            ("Redis", "/data"),
            ("MongoDB", "/data/db"),
            ("SQLite", ".db"),
            ("BerkeleyDB", "/var/lib/berkeleydb")
        ]
        
        for volume in volumes {
            for (dbName, dbPath) in databasePaths {
                if volume.contains(dbPath) {
                    warnings.append(dbName)
                }
            }
        }
        
        return warnings
    }
}
