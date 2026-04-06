import Foundation
import os.log

// MARK: - Relay Configuration Loader (Plan 77 Phase 6)

/// Loads and validates Apple Container relay configurations from compose YAML
/// Maps declarative `x-apple-relays` to Swift relay actors
public struct RelayConfigurationLoader {
    private let logger = Logger(subsystem: "com.container-compose.relay", category: "ConfigurationLoader")
    
    /// Supported relay types for hardware-accelerated IPC
    public enum SupportedRelayType: String, CaseIterable {
        case vsockAneEmbedding = "vsock-ane-embedding"
        case vsockMcpBridge = "vsock-mcp-bridge"
        case vsockLogStream = "vsock-log-stream"
        case vsockDb = "vsock-db"
        case vsockGeneric = "vsock-generic"
        
        public var description: String {
            switch self {
            case .vsockAneEmbedding: return "ANE Native Embedding Relay"
            case .vsockMcpBridge: return "MCP Bridge Relay"
            case .vsockLogStream: return "Log Stream Relay"
            case .vsockDb: return "Database VSOCK Relay (PostgreSQL/WAL-G)"
            case .vsockGeneric: return "Generic VSOCK Relay"
            }
        }
        
        /// Whether this relay type requires a target service
        public var requiresTarget: Bool {
            switch self {
            case .vsockMcpBridge, .vsockLogStream:
                return true
            case .vsockAneEmbedding, .vsockDb, .vsockGeneric:
                return false
            }
        }
    }
    
    /// Errors during configuration loading
    public enum ConfigurationError: Error, CustomStringConvertible {
        case unsupportedRelayType(String)
        case invalidPort(UInt32)
        case missingTarget(String)
        case conflictingPort(UInt32, String)
        
        public var description: String {
            switch self {
            case .unsupportedRelayType(let type):
                return "Unsupported relay type: '\(type)'. Supported types: \(SupportedRelayType.allCases.map { $0.rawValue })"
            case .invalidPort(let port):
                return "Invalid port number: \(port). Must be > 0 and < 65536"
            case .missingTarget(let service):
                return "Relay in service '\(service)' requires 'target' for inter-container routing"
            case .conflictingPort(let port, let service):
                return "Port \(port) already in use by service '\(service)'"
            }
        }
    }
    
    /// Loaded and validated relay configuration
    public struct LoadedRelay {
        public let serviceName: String
        public let type: SupportedRelayType
        public let port: UInt32
        public let target: String?
        public let priority: String?
        
        public init(serviceName: String, type: SupportedRelayType, port: UInt32, target: String? = nil, priority: String? = nil) {
            self.serviceName = serviceName
            self.type = type
            self.port = port
            self.target = target
            self.priority = priority
        }
    }
    
    /// Load relay configurations from services
    /// - Parameter services: List of service tuples from compose file
    /// - Returns: Array of validated relay configurations
    /// - Throws: ConfigurationError if validation fails
    public func loadRelays(from services: [(serviceName: String, service: Service)]) throws -> [LoadedRelay] {
        var loadedRelays: [LoadedRelay] = []
        var usedPorts: [UInt32: String] = [:]
        
        for (serviceName, service) in services {
            guard let appleRelays = service.x_apple_relays else { continue }
            
            logger.info("Processing \(appleRelays.count) relay(s) for service: \(serviceName)")
            
            for relayConfig in appleRelays {
                // Validate port
                guard relayConfig.port > 0 && relayConfig.port < 65536 else {
                    throw ConfigurationError.invalidPort(relayConfig.port)
                }
                
                // Check for port conflicts
                if let existingService = usedPorts[relayConfig.port] {
                    throw ConfigurationError.conflictingPort(relayConfig.port, existingService)
                }
                
                // Parse relay type
                guard let supportedType = SupportedRelayType(rawValue: relayConfig.type) else {
                    throw ConfigurationError.unsupportedRelayType(relayConfig.type)
                }
                
                // Validate target requirement
                if supportedType.requiresTarget && relayConfig.target == nil {
                    throw ConfigurationError.missingTarget(serviceName)
                }
                
                let loaded = LoadedRelay(
                    serviceName: serviceName,
                    type: supportedType,
                    port: relayConfig.port,
                    target: relayConfig.target,
                    priority: relayConfig.priority
                )
                
                loadedRelays.append(loaded)
                usedPorts[relayConfig.port] = serviceName
                
                logger.info("✓ Loaded relay: \(supportedType.description) on port \(relayConfig.port) for \(serviceName)")
            }
        }
        
        return loadedRelays
    }
    
    /// Check if any services declare Apple relay extensions
    public func hasAppleRelays(in services: [(serviceName: String, service: Service)]) -> Bool {
        return services.contains { _, service in
            service.x_apple_relays != nil && !service.x_apple_relays!.isEmpty
        }
    }
    
    /// Get summary of loaded relays for display
    public func summarize(_ relays: [LoadedRelay]) -> String {
        guard !relays.isEmpty else { return "No vsock relays configured" }
        
        var lines = ["Active vsock relays:"]
        for relay in relays {
            var line = "  - Port \(relay.port): \(relay.type.description)"
            if let target = relay.target {
                line += " → \(target)"
            }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }
}
