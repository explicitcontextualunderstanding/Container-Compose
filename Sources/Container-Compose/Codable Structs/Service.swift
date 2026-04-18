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

/// Shell-like argument splitting that respects single quotes, double quotes,
/// and backslash escapes. Handles commands like: `sh -c 'echo hello world'`
/// and `echo "foo bar" baz`.
func shellSplit(_ string: String) -> [String] {
    var args: [String] = []
    var current = ""
    var chars = string.makeIterator()
    var inSingleQuote = false
    var inDoubleQuote = false

    while let char = chars.next() {
        if char == "\\" && !inSingleQuote {
            // Backslash escape: take next char literally
            if let escaped = chars.next() {
                current.append(escaped)
            }
        } else if char == "'" && !inDoubleQuote {
            inSingleQuote.toggle()
        } else if char == "\"" && !inSingleQuote {
            inDoubleQuote.toggle()
        } else if char == " " && !inSingleQuote && !inDoubleQuote {
            if !current.isEmpty {
                args.append(current)
                current = ""
            }
        } else {
            current.append(char)
        }
    }

    if !current.isEmpty {
        args.append(current)
    }

    return args
}

//
//  Service.swift
//  container-compose-app
//
//  Created by Morris Richman on 6/17/25.
//

import Foundation
import SecurityHardening


/// Condition for `depends_on` long-form entries.
public enum DependsOnCondition: String, Codable, Hashable {
    case service_started
    case service_healthy
    case service_completed_successfully
}

/// Relay configuration for service-to-service communication
/// Enables declarative routing in compose files (Phase 5)
public struct ServiceRelay: Codable, Hashable {
    /// Transport protocol for the relay
    public let transport: TransportType

    /// VSOCK Context ID (for vsock transport only)
    public let cid: UInt32?

    /// Target service name to route to
    public let target: String?

    /// Port number (for vsock/tcp transports)
    public let port: UInt32?

    /// Unix socket path (for unix transport)
    public let socket: String?

    public init(
        transport: TransportType,
        cid: UInt32? = nil,
        target: String? = nil,
        port: UInt32? = nil,
        socket: String? = nil
    ) {
        self.transport = transport
        self.cid = cid
        self.target = target
        self.port = port
        self.socket = socket
    }
}

/// Apple Container vsock relay configuration (Plan 77 Phase 6)
/// Enables declarative vsock routing in compose files
public struct AppleRelayConfig: Codable, Hashable {
    /// Relay type identifier
    public let type: String
    
    /// VSOCK port number
    public let port: UInt32
    
    /// Target service for routing (optional)
    public let target: String?
    
    /// Priority level (optional)
    public let priority: String?
    
    /// Socket path for Unix domain socket (optional, for vsock-db type)
    /// Used to specify where PostgreSQL creates its socket in shared volume
    public let socket_path: String?
    
    public init(type: String, port: UInt32, target: String? = nil, priority: String? = nil, socket_path: String? = nil) {
        self.type = type
        self.port = port
        self.target = target
        self.priority = priority
        self.socket_path = socket_path
    }
}

/// A single entry in the long-form `depends_on` map.
public struct DependsOnEntry: Codable, Hashable {
    public let condition: DependsOnCondition?

    public init(condition: DependsOnCondition? = nil) {
        self.condition = condition
    }
}

/// Represents a single service definition within the `services` section.
/// NOTE: Changed from struct to class to enable proper mutation of dependedBy during topological sort.
public final class Service: Codable, Hashable {
    /// Docker image name
    public let image: String?

    /// Build configuration if the service is built from a Dockerfile
    public let build: Build?

    /// Deployment configuration (primarily for Swarm)
    public let deploy: Deploy?

    /// Restart policy (e.g., 'unless-stopped', 'always')
    public let restart: String?

    /// Healthcheck configuration
    public let healthcheck: Healthcheck?

    /// List of volume mounts (e.g., "hostPath:containerPath", "namedVolume:/path")
    public let volumes: [String]?

    /// Environment variables to set in the container
    public let environment: [String: String]?

    /// List of .env files to load environment variables from
    public let env_file: [String]?

    /// Port mappings (e.g., "hostPort:containerPort")
    public let ports: [String]?

    /// Command to execute in the container, overriding the image's default
    public let command: [String]?

    /// Services this service depends on (for startup order)
    /// Supports both short-form `[String]` and long-form `[String: DependsOnEntry]`.
    /// Long-form allows specifying conditions like `service_healthy`.
    public let depends_on: [String: DependsOnEntry]?

    /// User or UID to run the container as
    public let user: String?

    /// Explicit name for the container instance
    public let container_name: String?

    /// List of networks the service will connect to
    public let networks: [String]?

    /// Container hostname
    public let hostname: String?

    /// Entrypoint to execute in the container, overriding the image's default
    public let entrypoint: [String]?

    /// Run container in privileged mode
    public let privileged: Bool?

    /// Mount container's root filesystem as read-only
    public let read_only: Bool?

    /// Working directory inside the container
    public let working_dir: String?

    /// Platform architecture for the service
    public let platform: String?

    /// Registry scheme override (Apple Container extension: http, https, auto)
    /// Not part of Docker Compose spec — controls protocol used for image pulls
    public let scheme: String?

    /// Native init flag to request an init process (maps to container --init)
    public let `init`: Bool?

    /// Service-specific config usage (primarily for Swarm)
    public let configs: [ServiceConfig]?

    /// Service-specific secret usage (primarily for Swarm)
    public let secrets: [ServiceSecret]?

    /// Keep STDIN open (-i flag for `container run`)
    public let stdin_open: Bool?

    /// Allocate a pseudo-TTY (-t flag for `container run`)
    public let tty: Bool?

    /// DNS server(s) to use for container DNS resolution
    /// Supports both single string and array of strings
    public let dns: [String]?

    /// DNS search domain(s) for container-to-container name resolution
    /// Supports both single string and array of strings
    public let dns_search: [String]?

    /// Native runtime to use for this service (maps to container --runtime)
    public let runtime: String?

  /// Native init-image to use for this service (maps to container --init-image)
  public let init_image: String?

    /// Socket to publish from container to host (Apple Container extension: --publish-socket)
    /// Format: "containerPath:hostPath" or just "containerPath" (uses /tmp/{service}.sock)
    public let publish_socket: String?

    /// Relay configuration for declarative routing (Phase 5)
    /// Enables vsock/tcp/unix socket routing to other services
    public let relay: ServiceRelay?
    
    /// Apple Container vsock relay extensions (Plan 77 Phase 6)
    /// Declarative vsock configuration for hardware-isolated IPC
public let x_apple_relays: [AppleRelayConfig]?

  /// CamelCase accessor for x_apple_relays (for test compatibility)
  public var xAppleRelays: [AppleRelayConfig]? { x_apple_relays }

  /// Apple Container secrets extension (Plan 86)
  /// Declarative secrets mount configuration for zero-persistence security
  public let x_apple_secrets: XAppleSecretsConfig?

  /// CamelCase accessor for x_apple_secrets (for test compatibility)
  public var xAppleSecrets: XAppleSecretsConfig? { x_apple_secrets }

  /// Raw command string to pass directly to `container run` (Experiment 1)
  /// Bypasses all internal command/entrypoint merging logic
  public let x_apple_raw_command: String?

  /// Other services that depend on this service
  public var dependedBy: [String] = []

    /// Flat list of dependency service names (from both short and long form).
    public var dependencyNames: [String] {
        depends_on?.keys.sorted() ?? []
    }

    /// Dependency service names that require `service_healthy` condition.
    public var healthyDependencies: [String] {
        depends_on?.compactMap { name, entry in
            entry.condition == .service_healthy ? name : nil
        }.sorted() ?? []
    }
    
    /// Dependency service names that require `service_completed_successfully` condition.
    public var completedSuccessfullyDependencies: [String] {
        depends_on?.compactMap { name, entry in
            entry.condition == .service_completed_successfully ? name : nil
        }.sorted() ?? []
    }
    
// Defines custom coding keys to map YAML keys to Swift properties
// Note: 'env' is a shorthand alias for 'environment' in Docker Compose
    enum CodingKeys: String, CodingKey {
        case image, build, deploy, restart, healthcheck, volumes, environment, env, env_file, ports, command, depends_on, user, container_name, networks, hostname, entrypoint, privileged, read_only, working_dir, configs, secrets, stdin_open, tty, platform, scheme, runtime, `init`, init_image, dns, dns_search, publish_socket, relay
        case x_apple_relays = "x-apple-relays"
        case x_apple_secrets = "x-apple-secrets"
        case x_apple_raw_command = "x-apple-raw-command"
    }
    
    /// Public memberwise initializer for testing
    public init(
        image: String? = nil,
        build: Build? = nil,
        deploy: Deploy? = nil,
        restart: String? = nil,
        healthcheck: Healthcheck? = nil,
        volumes: [String]? = nil,
        environment: [String: String]? = nil,
        env_file: [String]? = nil,
        ports: [String]? = nil,
        command: [String]? = nil,
        depends_on: [String: DependsOnEntry]? = nil,
        user: String? = nil,
        container_name: String? = nil,
        networks: [String]? = nil,
        hostname: String? = nil,
        entrypoint: [String]? = nil,
        privileged: Bool? = nil,
        read_only: Bool? = nil,
        working_dir: String? = nil,
        platform: String? = nil,
        scheme: String? = nil,
        `init`: Bool? = nil,
        configs: [ServiceConfig]? = nil,
        secrets: [ServiceSecret]? = nil,
        stdin_open: Bool? = nil,
        tty: Bool? = nil,
        dns: [String]? = nil,
        dns_search: [String]? = nil,
        runtime: String? = nil,
        init_image: String? = nil,
        publish_socket: String? = nil,
        relay: ServiceRelay? = nil,
  x_apple_relays: [AppleRelayConfig]? = nil,
    x_apple_secrets: XAppleSecretsConfig? = nil,
    x_apple_raw_command: String? = nil,
    dependedBy: [String] = []
  ) {
    self.image = image
    self.build = build
    self.deploy = deploy
    self.restart = restart
    self.healthcheck = healthcheck
    self.volumes = volumes
    self.environment = environment
        self.env_file = env_file
        self.ports = ports
        self.command = command
        self.depends_on = depends_on
        self.user = user
        self.container_name = container_name
        self.networks = networks
        self.hostname = hostname
        self.entrypoint = entrypoint
        self.privileged = privileged
        self.read_only = read_only
        self.working_dir = working_dir
        self.platform = platform
        self.scheme = scheme
        self.`init` = `init`
        self.configs = configs
        self.secrets = secrets
        self.stdin_open = stdin_open
        self.tty = tty
        self.dns = dns
        self.dns_search = dns_search
self.runtime = runtime
    self.init_image = init_image
    self.publish_socket = publish_socket
    self.relay = relay
    self.x_apple_relays = x_apple_relays
    self.x_apple_secrets = x_apple_secrets
    self.x_apple_raw_command = x_apple_raw_command
    self.dependedBy = dependedBy
  }

  /// Custom initializer to handle decoding and basic validation.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        image = try container.decodeIfPresent(String.self, forKey: .image)
        build = try container.decodeIfPresent(Build.self, forKey: .build)
        deploy = try container.decodeIfPresent(Deploy.self, forKey: .deploy)
        
        // Ensure that a service has either an image or a build context.
        guard image != nil || build != nil else {
            throw DecodingError.dataCorruptedError(forKey: .image, in: container, debugDescription: "Service must have either 'image' or 'build' specified.")
        }

        // Validate restart policy if present
        let rawRestart = try container.decodeIfPresent(String.self, forKey: .restart)
        if let restartPolicy = rawRestart {
            let validPolicies = ["no", "always", "on-failure", "unless-stopped"]
            guard validPolicies.contains(restartPolicy) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .restart,
                    in: container,
                    debugDescription: "Invalid restart policy '\(restartPolicy)'. Valid policies: \(validPolicies.joined(separator: ", "))"
                )
            }
        }
        restart = rawRestart
        healthcheck = try container.decodeIfPresent(Healthcheck.self, forKey: .healthcheck)
        // Note: volumes validated below after env_file
        // Support both 'environment:' and shorthand 'env:' - env takes precedence as the shorthand
        // TODO(Phase 4): Remove list-format support after YAML sunset
        // Pkl schemas use strict Mapping types
        func decodeEnvironmentInternal(forKey key: CodingKeys) throws -> [String: String]? {
            if let map = try? container.decodeIfPresent([String: String].self, forKey: key) {
                return map
            }
            if let list = try? container.decodeIfPresent([String].self, forKey: key) {
                var map: [String: String] = [:]
                for entry in list {
                    let parts = entry.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                    if parts.count == 2 {
                        map[String(parts[0])] = String(parts[1])
                    } else if parts.count == 1 {
                        map[String(parts[0])] = ""
                    }
                }
                return map
            }
            return nil
        }

        var mergedEnv = try decodeEnvironmentInternal(forKey: .environment)
        if let envShort = try decodeEnvironmentInternal(forKey: .env) {
            if var env = mergedEnv {
                // Merge with env (shorthand) taking precedence
                for (key, value) in envShort {
                    env[key] = value
                }
                mergedEnv = env
            } else {
                mergedEnv = envShort
            }
        }
        environment = mergedEnv
        env_file = try container.decodeIfPresent([String].self, forKey: .env_file)

        // Validate volumes if present
        let rawVolumes = try container.decodeIfPresent([String].self, forKey: .volumes)
        if let vols = rawVolumes {
            for (index, vol) in vols.enumerated() {
                // If volume has a colon, validate format
                // Named volume: "name:/path" or "name:/path:ro"
                // Bind mount: "./host:/container" or "./host:/container:rw"
                // Anonymous volume: "/path" (no colon, valid)
                if vol.contains(":") {
                    let parts = vol.split(separator: ":", omittingEmptySubsequences: false)
                    // Must have at least 2 parts (source:destination)
                    // Can have 3 parts with mode (source:destination:ro/rw)
                    guard parts.count >= 2 && !parts[0].isEmpty && !parts[1].isEmpty else {
                        throw DecodingError.dataCorruptedError(
                            forKey: .volumes,
                            in: container,
                            debugDescription: "Invalid volume '\(vol)' at index \(index). Volumes with colon must be in format 'source:destination' or 'source:destination:mode' (e.g., 'wordpress_data:/var/www/html:ro')"
                        )
                    }
                }
            }
        }
        volumes = rawVolumes

        // Validate ports if present
        let rawPorts = try container.decodeIfPresent([String].self, forKey: .ports)
        if let prts = rawPorts {
            for (index, port) in prts.enumerated() {
                // Port should contain a colon separating host and container ports
                guard port.contains(":") else {
                    throw DecodingError.dataCorruptedError(
                        forKey: .ports,
                        in: container,
                        debugDescription: "Invalid port '\(port)' at index \(index). Ports must be in format 'host:container' (e.g., '8080:80')"
                    )
                }
            }
        }
        ports = rawPorts

    // Decode 'command' which can be either a single string or an array of strings.
    if let cmdArray = try? container.decodeIfPresent([String].self, forKey: .command) {
      command = cmdArray
    } else if let cmdString = try? container.decodeIfPresent(String.self, forKey: .command) {
      command = shellSplit(cmdString)
    } else {
      command = nil
    }
        
        // Decode depends_on: supports string, [string], and {service: {condition: ...}} forms
        if let dependsOnString = try? container.decodeIfPresent(String.self, forKey: .depends_on) {
            depends_on = [dependsOnString: DependsOnEntry(condition: nil)]
        } else if let dependsOnArray = try? container.decodeIfPresent([String].self, forKey: .depends_on) {
            depends_on = Dictionary(uniqueKeysWithValues: dependsOnArray.map { ($0, DependsOnEntry(condition: nil)) })
        } else {
            depends_on = try container.decodeIfPresent([String: DependsOnEntry].self, forKey: .depends_on)
        }
        user = try container.decodeIfPresent(String.self, forKey: .user)

        container_name = try container.decodeIfPresent(String.self, forKey: .container_name)
        networks = try container.decodeIfPresent([String].self, forKey: .networks)
        hostname = try container.decodeIfPresent(String.self, forKey: .hostname)
        
    // Decode 'entrypoint' which can be either a single string or an array of strings.
    if let entrypointArray = try? container.decodeIfPresent([String].self, forKey: .entrypoint) {
      entrypoint = entrypointArray
    } else if let entrypointString = try? container.decodeIfPresent(String.self, forKey: .entrypoint) {
      entrypoint = shellSplit(entrypointString)
    } else {
      entrypoint = nil
    }

        privileged = try container.decodeIfPresent(Bool.self, forKey: .privileged)
        read_only = try container.decodeIfPresent(Bool.self, forKey: .read_only)
        working_dir = try container.decodeIfPresent(String.self, forKey: .working_dir)
        configs = try container.decodeIfPresent([ServiceConfig].self, forKey: .configs)
        secrets = try container.decodeIfPresent([ServiceSecret].self, forKey: .secrets)
        stdin_open = try container.decodeIfPresent(Bool.self, forKey: .stdin_open)
        tty = try container.decodeIfPresent(Bool.self, forKey: .tty)
        // Validate platform if present (should be in format os/arch like linux/amd64)
        let rawPlatform = try container.decodeIfPresent(String.self, forKey: .platform)
        if let plat = rawPlatform {
            let platformPattern = #"^[a-z]+/[a-z0-9]+$"#
            guard plat.range(of: platformPattern, options: .regularExpression) != nil else {
                throw DecodingError.dataCorruptedError(
                    forKey: .platform,
                    in: container,
                    debugDescription: "Invalid platform '\(plat)'. Expected format: 'os/architecture' (e.g., 'linux/amd64', 'linux/arm64')"
                )
            }
        }
        platform = rawPlatform
        // Decode optional registry scheme (Apple Container extension: http, https, auto)
        let rawScheme = try container.decodeIfPresent(String.self, forKey: .scheme)
        if let sch = rawScheme {
            let validSchemes = ["http", "https", "auto"]
            guard validSchemes.contains(sch) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .scheme,
                    in: container,
                    debugDescription: "Invalid scheme '\(sch)'. Valid values: \(validSchemes.joined(separator: ", "))"
                )
            }
        }
        scheme = rawScheme
        // Decode optional init flag (YAML key: init)
        `init` = try container.decodeIfPresent(Bool.self, forKey: .`init`)
        // Validate runtime if present (should not be empty)
        let rawRuntime = try container.decodeIfPresent(String.self, forKey: .runtime)
        if let rt = rawRuntime, rt.isEmpty {
            throw DecodingError.dataCorruptedError(
                forKey: .runtime,
                in: container,
                debugDescription: "Runtime cannot be an empty string"
            )
        }
        runtime = rawRuntime
    init_image = try container.decodeIfPresent(String.self, forKey: .init_image)
    publish_socket = try container.decodeIfPresent(String.self, forKey: .publish_socket)

    // Support both single string and array for dns
        if let dnsString = try? container.decodeIfPresent(String.self, forKey: .dns) {
            dns = [dnsString]
        } else {
            dns = try container.decodeIfPresent([String].self, forKey: .dns)
        }

    // Support both single string and array for dns_search
    if let dnsSearchString = try? container.decodeIfPresent(String.self, forKey: .dns_search) {
      dns_search = [dnsSearchString]
    } else {
      dns_search = try container.decodeIfPresent([String].self, forKey: .dns_search)
    }

    // Decode relay configuration if present (Phase 5)
    relay = try container.decodeIfPresent(ServiceRelay.self, forKey: .relay)
    
    // Decode Apple relay extensions if present (Plan 77 Phase 6)
    x_apple_relays = try container.decodeIfPresent([AppleRelayConfig].self, forKey: .x_apple_relays)

    // Decode Apple secrets extension if present (Plan 86)
    x_apple_secrets = try container.decodeIfPresent(XAppleSecretsConfig.self, forKey: .x_apple_secrets)

    // Decode Apple raw command extension if present (Experiment 1)
    x_apple_raw_command = try container.decodeIfPresent(String.self, forKey: .x_apple_raw_command)
  }
    
    /// Returns the services in topological order based on `depends_on` relationships.
    public static func topoSortConfiguredServices(
        _ services: [(serviceName: String, service: Service)]
    ) throws -> [(serviceName: String, service: Service)] {
        
        var visited = Set<String>()
        var visiting = Set<String>()
        var sorted: [(String, Service)] = []

  func visit(_ name: String, from service: String? = nil) throws {
    guard let serviceTupleIndex = services.firstIndex(where: { $0.serviceName == name }) else {
      throw NSError(domain: "ComposeError", code: 2, userInfo: [
        NSLocalizedDescriptionKey: "Service '\(name)' not found in services."
      ])
    }
    var serviceTuple = services[serviceTupleIndex]
            if let service {
                serviceTuple.service.dependedBy.append(service)
            }
            
            if visiting.contains(name) {
                throw NSError(domain: "ComposeError", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "Cyclic dependency detected involving '\(name)'"
                ])
            }
            guard !visited.contains(name) else { return }

            visiting.insert(name)
            for depName in serviceTuple.service.dependencyNames {
                try visit(depName, from: name)
            }
            visiting.remove(name)
            visited.insert(name)
            sorted.append(serviceTuple)
        }

        for (serviceName, _) in services {
            if !visited.contains(serviceName) {
                try visit(serviceName)
            }
        }

    return sorted
  }

  /// Custom encoder to handle env/encoding - only encodes environment, not the env alias
  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    // Encode all properties using their CodingKeys
    try container.encodeIfPresent(image, forKey: .image)
    try container.encodeIfPresent(build, forKey: .build)
    try container.encodeIfPresent(deploy, forKey: .deploy)
    try container.encodeIfPresent(restart, forKey: .restart)
    try container.encodeIfPresent(healthcheck, forKey: .healthcheck)
    try container.encodeIfPresent(volumes, forKey: .volumes)
    try container.encodeIfPresent(environment, forKey: .environment)
    try container.encodeIfPresent(env_file, forKey: .env_file)
    try container.encodeIfPresent(ports, forKey: .ports)
    try container.encodeIfPresent(command, forKey: .command)
    try container.encodeIfPresent(depends_on, forKey: .depends_on)
    try container.encodeIfPresent(user, forKey: .user)
    try container.encodeIfPresent(container_name, forKey: .container_name)
    try container.encodeIfPresent(networks, forKey: .networks)
    try container.encodeIfPresent(hostname, forKey: .hostname)
    try container.encodeIfPresent(entrypoint, forKey: .entrypoint)
    try container.encodeIfPresent(privileged, forKey: .privileged)
    try container.encodeIfPresent(read_only, forKey: .read_only)
    try container.encodeIfPresent(working_dir, forKey: .working_dir)
    try container.encodeIfPresent(configs, forKey: .configs)
    try container.encodeIfPresent(secrets, forKey: .secrets)
    try container.encodeIfPresent(stdin_open, forKey: .stdin_open)
    try container.encodeIfPresent(tty, forKey: .tty)
    try container.encodeIfPresent(platform, forKey: .platform)
    try container.encodeIfPresent(`init`, forKey: .`init`)
    try container.encodeIfPresent(runtime, forKey: .runtime)
    try container.encodeIfPresent(init_image, forKey: .init_image)
    try container.encodeIfPresent(dns, forKey: .dns)
    try container.encodeIfPresent(dns_search, forKey: .dns_search)
    try container.encodeIfPresent(publish_socket, forKey: .publish_socket)
    try container.encodeIfPresent(relay, forKey: .relay)
    try container.encodeIfPresent(x_apple_relays, forKey: .x_apple_relays)
    try container.encodeIfPresent(x_apple_secrets, forKey: .x_apple_secrets)
    try container.encodeIfPresent(x_apple_raw_command, forKey: .x_apple_raw_command)
  }

// MARK: - Hashable Conformance (class requires explicit implementation)

  public static func == (lhs: Service, rhs: Service) -> Bool {
    lhs.image == rhs.image &&
    lhs.build == rhs.build &&
    lhs.deploy == rhs.deploy &&
    lhs.restart == rhs.restart &&
    lhs.healthcheck == rhs.healthcheck &&
    lhs.volumes == rhs.volumes &&
    lhs.environment == rhs.environment &&
    lhs.env_file == rhs.env_file &&
    lhs.ports == rhs.ports &&
    lhs.command == rhs.command &&
    lhs.depends_on == rhs.depends_on &&
    lhs.user == rhs.user &&
    lhs.container_name == rhs.container_name &&
    lhs.networks == rhs.networks &&
    lhs.hostname == rhs.hostname &&
    lhs.entrypoint == rhs.entrypoint &&
    lhs.privileged == rhs.privileged &&
    lhs.read_only == rhs.read_only &&
    lhs.working_dir == rhs.working_dir &&
    lhs.platform == rhs.platform &&
    lhs.`init` == rhs.`init` &&
    lhs.configs == rhs.configs &&
    lhs.secrets == rhs.secrets &&
    lhs.stdin_open == rhs.stdin_open &&
    lhs.tty == rhs.tty &&
    lhs.dns == rhs.dns &&
    lhs.dns_search == rhs.dns_search &&
    lhs.runtime == rhs.runtime &&
    lhs.init_image == rhs.init_image &&
    lhs.publish_socket == rhs.publish_socket &&
    lhs.relay == rhs.relay &&
    lhs.x_apple_relays == rhs.x_apple_relays &&
    lhs.x_apple_secrets == rhs.x_apple_secrets &&
    lhs.x_apple_raw_command == rhs.x_apple_raw_command
  }

  public func hash(into hasher: inout Hasher) {
    hasher.combine(image)
    hasher.combine(build)
    hasher.combine(deploy)
    hasher.combine(restart)
    hasher.combine(healthcheck)
    hasher.combine(volumes)
    hasher.combine(environment)
    hasher.combine(env_file)
    hasher.combine(ports)
    hasher.combine(command)
    hasher.combine(depends_on)
    hasher.combine(user)
    hasher.combine(container_name)
    hasher.combine(networks)
    hasher.combine(hostname)
    hasher.combine(entrypoint)
    hasher.combine(privileged)
    hasher.combine(read_only)
    hasher.combine(working_dir)
    hasher.combine(platform)
    hasher.combine(`init`)
    hasher.combine(configs)
    hasher.combine(secrets)
    hasher.combine(stdin_open)
    hasher.combine(tty)
    hasher.combine(dns)
    hasher.combine(dns_search)
    hasher.combine(runtime)
    hasher.combine(init_image)
    hasher.combine(publish_socket)
    hasher.combine(relay)
    hasher.combine(x_apple_relays)
    hasher.combine(x_apple_secrets)
    hasher.combine(x_apple_raw_command)
  }
}
