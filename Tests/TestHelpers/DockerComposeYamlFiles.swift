//===----------------------------------------------------------------------===//
// Copyright © 2025 Morris Richman and the Container-Compose project authors. All rights reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//===----------------------------------------------------------------------===//

import Foundation

public enum YamlError: Error, CustomStringConvertible {
  case missingRegistryURL

  public var description: String {
    switch self {
    case .missingRegistryURL:
      return """
      OCI_REGISTRY_URL environment variable is not set.

      E2E tests require OCI_REGISTRY_URL to be configured.
      Run via ./run-tests.sh which loads OCI_REGISTRY_URL from ops.env.

      To run E2E tests manually:
      1. Ensure OCI_REGISTRY_URL is set (from ops.env or .env)
      2. Run: swift test --filter <test_name>
      """
    }
  }
}

public struct DockerComposeYamlFiles {
    /// Resolves environment variables in a YAML string
    /// - Parameter yaml: YAML string with ${VAR} placeholders
    /// - Returns: YAML with environment variables substituted
    public static func resolveEnvVars(_ yaml: String) -> String {
        var result = yaml
        let pattern = #"\$\{([^}]+)\}"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return result
        }
        
        let range = NSRange(result.startIndex..., in: result)
        let matches = regex.matches(in: result, options: [], range: range).reversed()
        
        for match in matches {
            guard let fullRange = Range(match.range, in: result),
                  let varNameRange = Range(match.range(at: 1), in: result) else {
                continue
            }
            let varName = String(result[varNameRange])
            if let envValue = ProcessInfo.processInfo.environment[varName] {
                result.replaceSubrange(fullRange, with: envValue)
            }
        }
        return result
    }
    
    /// Finds an available port on the local machine.
    /// - Returns: An available port number
    public static func getAvailablePort() -> UInt16 {
        return getAvailablePort(attempts: 5)
    }

    /// Finds an available port on the local machine with retry logic.
    /// - Parameters:
    ///   - attempts: Number of attempts to find an available port
    /// - Returns: An available port number
    public static func getAvailablePort(attempts: Int) -> UInt16 {
        for _ in 0..<attempts {
            let port = getSingleAvailablePort()

            // Verify the port is still available by trying to bind to it again
            if isPortAvailable(port) {
                return port
            }

            // Port not available, try again after a short delay
            usleep(100_000) // 100ms
        }

        // Fallback to a random high port after all attempts
        return UInt16.random(in: 18080...19000)
    }

    /// Gets a single available port from the OS.
    private static func getSingleAvailablePort() -> UInt16 {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socket != -1 else {
            return UInt16.random(in: 18080...19000)
        }
        defer { Darwin.close(socket) }

        // Set SO_REUSEADDR to allow immediate reuse of the port
        var reuse: Int32 = 1
        setsockopt(socket, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0 // Let OS assign
        addr.sin_addr.s_addr = INADDR_ANY

        let bindResult = withUnsafePointer(to: &addr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.bind(socket, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        guard bindResult == 0 else {
            return UInt16.random(in: 18080...19000)
        }

        // Get the assigned port
        var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        var assignedAddr = sockaddr_in()
        let result = withUnsafeMutablePointer(to: &assignedAddr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.getsockname(socket, sockPtr, &addrLen)
            }
        }

        guard result == 0 else {
            return UInt16.random(in: 18080...19000)
        }

        // Convert from network byte order to host byte order
        let port = UInt16(bigEndian: assignedAddr.sin_port)
        return port
    }

    /// Verifies if a port is actually available for binding.
    private static func isPortAvailable(_ port: UInt16) -> Bool {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socket != -1 else { return false }
        defer { Darwin.close(socket) }

        // Set SO_REUSEADDR
        var reuse: Int32 = 1
        setsockopt(socket, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = INADDR_ANY

        let bindResult = withUnsafePointer(to: &addr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.bind(socket, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        return bindResult == 0
    }

    public static let dockerComposeYaml1 = """
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
          - "${TEST_PORT_WORDPRESS:-18080}:8080"
        depends_on:
          - wp
        volumes:
          - wordpress_data:/var/www/html:ro
          - ./nginx.conf:/etc/nginx/conf.d/default.conf:ro

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

    public static let nginxConf = """
    upstream php {
        server wp:9000;
    }

    server {
        listen 8080;
        server_name localhost;
        root /var/www/html;
        index index.php index.html;

        location / {
            try_files $uri $uri/ =404;
        }

        location ~ \\.php$ {
            try_files $uri =404;
            fastcgi_pass php;
            fastcgi_index index.php;
            fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
            include fastcgi_params;
        }
    }
    """

    public static let dockerComposeYaml2 = """
    version: '3.8'
    name: webapp

    services:
      nginx:
        image: nginx:alpine
        ports:
          - "${TEST_PORT_WEB:-18081}:80"
        depends_on:
          - app
        networks:
          - frontend

      app:
        image: node:18-alpine
        working_dir: /app
        environment:
          NODE_ENV: production
          DATABASE_URL: postgres://db:5432/myapp
        depends_on:
          - db
          - redis
        networks:
          - frontend
          - backend

      db:
        image: postgres:14-alpine
        environment:
          POSTGRES_DB: myapp
          POSTGRES_USER: user
          POSTGRES_PASSWORD: password
        volumes:
          - db-data:/var/lib/postgresql/data
        networks:
          - backend

      redis:
        image: redis:alpine
        networks:
          - backend

    volumes:
      db-data:

    networks:
      frontend:
      backend:
    """

    public static let dockerComposeYaml3 = """
    version: '3.8'

    services:
      api:
        image: traefik:v2.10
        ports:
          - "${TEST_PORT_GATEWAY:-18082}:80"
          - "${TEST_PORT_API:-18083}:8080"
        depends_on:
          - auth
          - user
          - order

      auth:
        image: auth:latest
        environment:
          JWT_SECRET: secret123
          DATABASE_URL: postgres://db:5432/auth

      user:
        image: user:latest
        environment:
          DATABASE_URL: postgres://db:5432/users

      order:
        image: order:latest
        environment:
          DATABASE_URL: postgres://db:5432/orders

      db:
        image: postgres:14
        environment:
          POSTGRES_PASSWORD: postgres
    """

    public static let dockerComposeYaml4 = """
    version: '3.8'

    services:
      app:
        build:
          context: .
          dockerfile: Dockerfile.dev
        volumes:
          - ./app:/app
          - /app/node_modules
        environment:
          NODE_ENV: development
        ports:
          - "${TEST_PORT_APP:-13000}:3000"
        command: npm run dev
    """

    public static let dockerComposeYaml5 = """
    version: '3.8'

    services:
      app:
        image: myapp:latest
        configs:
          - source: app_config
            target: /etc/app/config.yml
        secrets:
          - db_password

    configs:
      app_config:
        external: true

    secrets:
      db_password:
        external: true
    """

    public static let dockerComposeYaml6 = """
    version: '3.8'

    services:
      web:
        image: nginx:latest
        restart: unless-stopped
        healthcheck:
          test: ["CMD", "curl", "-f", "http://localhost"]
          interval: 30s
          timeout: 10s
          retries: 3
          start_period: 40s

      db:
        image: postgres:14
        restart: always
        healthcheck:
          test: ["CMD-SHELL", "pg_isready -U postgres"]
          interval: 10s
          timeout: 5s
          retries: 5
    """

    public static let dockerComposeYaml7 = """
    version: '3.8'

    services:
      frontend:
        image: frontend:latest
        depends_on:
          - api

      api:
        image: api:latest
        depends_on:
          - cache
          - db

      cache:
        image: redis:alpine

      db:
        image: postgres:14
    """

    public static let dockerComposeYaml8 = """
    version: '3.8'

    services:
      web:
        image: nginx:alpine
        ports:
          - "${TEST_PORT_WEB2:-18084}:80"
        depends_on:
          app:
            condition: service_started

      app:
        image: python:3.12-alpine
        depends_on:
          db:
            condition: service_healthy
        command: python -m http.server 8000
        environment:
          DATABASE_URL: postgres://postgres:postgres@db:5432/appdb

      db:
        image: postgres:14
        healthcheck:
          test: ["CMD-SHELL", "pg_isready -U postgres"]
          interval: 5s
          timeout: 3s
          retries: 5
          start_period: 10s
        environment:
          POSTGRES_DB: appdb
          POSTGRES_USER: postgres
          POSTGRES_PASSWORD: postgres
    """

    public static func dockerComposeYaml9(containerName: String) -> String {
        return """
        version: '3.8'
        services:
          web:
            image: nginx:alpine
            container_name: \(containerName)
        """
    }

    /// Represents a temporary Docker Compose project copied to a temporary location for testing.
    public struct TemporaryProject {
        /// The URL of the temporary docker-compose.yaml file.
        public let url: URL

        /// The base directory containing the temporary docker-compose.yaml file.
        public let base: URL

        /// The project name derived from the temporary directory name.
        public let name: String
    }

    /// Copies the provided Docker Compose YAML content to a temporary location and returns a
    /// TemporaryProject.
/// - Parameter yaml: The Docker Compose YAML content to copy.
  /// - Returns: A TemporaryProject containing the URL and project name.
  /// Note: Replaces hardcoded names/paths with UUID-based values for isolation
  public static func copyYamlToTemporaryLocation(yaml: String) throws -> TemporaryProject {
    let tempLocation = URL.temporaryDirectory.appending(
      path: "CCT_\(UUID().uuidString)/docker-compose.yaml"
    )
    let tempBase = tempLocation.deletingLastPathComponent()
    let projectName = tempBase.lastPathComponent
    
    // Replace hardcoded values with isolated UUID-based values:
    // 1. Project name for container isolation
    // 2. Socket path so test knows where to find it (matches temp directory)
    // 3. Environment variables (OCI_REGISTRY_URL, etc.)
    var isolatedYaml = yaml.replacingOccurrences(
      of: "name: vsock-relay-test",
      with: "name: \(projectName)"
    )
    
    // Replace hardcoded socket path with temp directory relative path
    // Old: /tmp/.container-compose-test/sockets/.s.PGSQL.5432
    // New: <tempBase>/sockets/.s.PGSQL.5432
    isolatedYaml = isolatedYaml.replacingOccurrences(
      of: "socket_path: /tmp/.container-compose-test/sockets/.s.PGSQL.5432",
      with: "socket_path: \(tempBase.path)/sockets/.s.PGSQL.5432"
    )
    
    // Replace environment variable placeholders
    // ${OCI_REGISTRY_URL} -> actual value from environment
    guard let registryURL = ProcessInfo.processInfo.environment["OCI_REGISTRY_URL"] else {
      throw YamlError.missingRegistryURL
    }
    isolatedYaml = isolatedYaml.replacingOccurrences(
      of: "${OCI_REGISTRY_URL}",
      with: registryURL
    )
    
    try? FileManager.default.createDirectory(at: tempBase, withIntermediateDirectories: true)
    try isolatedYaml.write(to: tempLocation, atomically: false, encoding: .utf8)

    return TemporaryProject(url: tempLocation, base: tempBase, name: projectName)
  }

  // MARK: - Vsock Relay Test Fixtures (Plan 84)

  /// Test fixture for vsock-db relay with socket_path configuration
  /// Uses pgmicro for faster startup (2-5s vs 30s) while still testing same relay paths
  /// pgmicro is PostgreSQL-compatible (same socket behavior) but lighter weight for E2E testing
  /// Note: Tests using this require OCI_REGISTRY_URL env var (via ops.env, gitignored)
  public static let vsockDbRelayYaml = """
    name: vsock-relay-test
    services:
      db:
        image: ${OCI_REGISTRY_URL}/pgmicro:latest
        environment:
          POSTGRES_DB: testdb
          POSTGRES_USER: test
          POSTGRES_PASSWORD: test
        volumes:
          - test-db-sockets:/var/run/postgresql/sockets
        x-apple-relays:
          - type: vsock-db
            port: 5432
            socket_path: /tmp/.container-compose-test/sockets/.s.PGSQL.5432
        command:
          - /pgmicro
          - --unix-socket-dir=/var/run/postgresql/sockets
    volumes:
      test-db-sockets:
    """

  /// Test fixture for vsock-db relay WITHOUT socket_path (backward compatibility)
  public static let vsockDbRelayNoSocketPathYaml = """
    name: vsock-relay-test-nopath
    services:
      db:
        image: postgres:15-alpine
        environment:
          POSTGRES_DB: testdb
          POSTGRES_USER: test
          POSTGRES_PASSWORD: test
        x-apple-relays:
  - type: vsock-db
    port: 5432
  command:
    - postgres
    - -c
    - listen_addresses=*
  """

  // MARK: - UDS Relay Test Fixtures (Plan 88)

  /// Test fixture for UDS relay with socket_path configuration
  /// Migrated from vsock-db to UDS-over-Virtio-FS
  public static let udsDbRelayYaml = """
name: uds-relay-test
services:
  db:
    image: ${OCI_REGISTRY_URL}/pgmicro:latest
    environment:
      POSTGRES_DB: testdb
      POSTGRES_USER: test
      POSTGRES_PASSWORD: test
    volumes:
      - test-db-sockets:/var/run/postgresql/sockets
    x-apple-relays:
      - type: uds
        port: 5432
        socket_path: /tmp/.container-compose-test/sockets/.s.PGSQL.5432
    command:
      - /pgmicro
      - --unix-socket-dir=/var/run/postgresql/sockets
volumes:
  test-db-sockets:
"""

  // MARK: - Socket Lifecycle Test Fixtures (VirtioFS Testing)

  /// Minimal socket-creating container for testing VirtioFS socket propagation
  /// Uses alpine + socat to create a real Unix Domain Socket without database overhead
  /// ~5MB footprint, <1s startup vs 150MB/30s for PostgreSQL
  public static let socketLifecycleYaml = """
name: socket-lifecycle-test
services:
  socket-generator:
    image: alpine:latest
    command: >
      sh -c "apk add --no-cache socat &&
             mkdir -p /tmp/socket-test &&
             rm -f /tmp/socket-test/test.sock &&
             socat UNIX-LISTEN:/tmp/socket-test/test.sock,fork STDOUT"
    volumes:
      - socket-volume:/tmp/socket-test
    init: true
volumes:
  socket-volume:
"""

  /// Socket lifecycle test with relay configuration
  public static let socketRelayLifecycleYaml = """
name: socket-relay-test
services:
  socket-generator:
    image: alpine:latest
    command: >
      sh -c "apk add --no-cache socat &&
             mkdir -p /tmp/socket-test &&
             rm -f /tmp/socket-test/pg.sock &&
             socat UNIX-LISTEN:/tmp/socket-test/pg.sock,fork STDOUT"
    volumes:
      - socket-volume:/tmp/socket-test
    x-apple-relays:
      - type: uds
        port: 5432
        socket_path: /tmp/.container-compose-test/sockets/pg.sock
    init: true
volumes:
  socket-volume:
"""

  /// Echo server for testing bidirectional socket communication
  public static let socketEchoYaml = """
name: socket-echo-test
services:
  socket-echo:
    image: alpine:latest
    command: >
      sh -c "apk add --no-cache socat &&
             mkdir -p /tmp/socket-test &&
             rm -f /tmp/socket-test/echo.sock &&
             socat UNIX-LISTEN:/tmp/socket-test/echo.sock,fork EXEC:'cat',nofork"
    volumes:
      - socket-volume:/tmp/socket-test
    init: true
volumes:
  socket-volume:
"""
}
