# VSOCK Relays - Declarative IPC for Apple Container

## Overview

Container-Compose supports **VSOCK relays** via the `x-apple-relays` extension field in your compose files. This enables hardware-isolated inter-process communication without filesystem dependencies.

## Key Principle

**Container-Compose is declarative and application-agnostic.**

Like `docker-compose`, Container-Compose:
- Reads YOUR compose file
- Creates containers/services YOU define
- Sets up relays YOU declare
- Does NOT bake in knowledge of specific services

The declarative approach means YOU control your architecture via YAML, not via hardcoded tool logic.

## Supported Relay Types

| Type | Description | Requires Target |
|------|-------------|-----------------|
| `vsock-db` | PostgreSQL/WAL-G "dark database" (no TCP exposure) | No |
| `vsock-mcp-bridge` | Model Context Protocol bridge | Yes |
| `vsock-log-stream` | Log streaming relay | Yes |
| `vsock-ane-embedding` | Apple Neural Engine embedding | No |
| `vsock-generic` | Generic vsock relay | Optional |

## Usage Example

```yaml
services:
  my-database:
    image: postgres:15
    x-apple-relays:
      - type: 'vsock-db'        # Required
        port: 5432               # VSOCK port
        priority: 'high'          # Optional: high/medium/low

  my-api:
    image: myapp:latest
    depends_on:
      - my-database
    x-apple-relays:
      - type: 'vsock-mcp-bridge'
        port: 5002
        target: 'my-database'    # Required for MCP/log-stream
```

## Security Benefits

1. **Zero-disk IPC**: Data flows through kernel memory
2. **Hardware-isolated**: VM-to-host via Virtualization.framework
3. **No network exposure**: Containers run "dark" (no IP address)
4. **CID verification**: Connection authorization from virtualization layer

## Example Files

- `honcho-hermes.yml` - Full Honcho/Hermes/Codegraph setup
- Your own compose files can use any services you need

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│ Container-Compose (Generic Orchestrator)                │
│                                                         │
│  - Reads YOUR compose.yml                               │
│  - Processes x-apple-relays declarations                │
│  - Creates generic VSOCK listeners                      │
│  - Validates port conflicts                             │
│  - NO hardcoded service knowledge                       │
└─────────────────────────────────────────────────────────┘
                          │
                          ▼
┌─────────────────────────────────────────────────────────┐
│ Your Compose File (You Define Everything)               │
│                                                         │
│  services:                                              │
│    my-service:                                          │
│      x-apple-relays:                                    │
│        - type: 'vsock-generic'                         │
│          port: 5000                                     │
└─────────────────────────────────────────────────────────┘
```

## Validation

Container-Compose validates:
- Relay type is supported
- Port number is valid (1-65535)
- No port conflicts across services
- Required `target` field for MCP/log-stream types
- Priority values (if provided) are `high`, `medium`, or `low`
- Schema correctness before starting containers

### Error Types

Container-Compose throws specific errors that can be caught:

```swift
enum ConfigurationError: Error {
    case unsupportedRelayType(String)   // Unknown relay type
    case invalidPort(UInt32)              // Port 0 or > 65535
    case missingTarget(String)           // MCP/log-stream missing target
    case conflictingPort(UInt32, String) // Port already used
    case invalidPriority(String)          // Priority not high/medium/low
}
```

**Example error handling:**
```swift
do {
    let relays = try loader.loadRelays(from: services)
} catch let error as RelayConfigurationLoader.ConfigurationError {
    switch error {
    case .invalidPriority(let value):
        print("Priority '\(value)' not supported. Use: high, medium, low")
    case .missingTarget(let service):
        print("Service '\(service)' requires target field")
    // ... handle other errors
    }
}
```

## Test Coverage

- `RelayConfigurationLoaderTests.swift` - 23 tests
- `ComposeSchemaMappingTests.swift` - End-to-end YAML parsing
- See Plan 77 for full test matrix