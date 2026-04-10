# Container-Compose

Swift 6.1 project for Apple Container runtime orchestration.

## Swift Environment Rules (Critical)

**Do NOT use `mcp-language-server` for sourcekit-lsp** — it cannot communicate with
sourcekit-lsp (zero stdio output, 30s timeout). Use `sourcekit-lsp-mcp` instead.

### Swift MCP Tools: sourcekit-lsp-mcp

`sourcekit-lsp-mcp` provides 10 Swift analysis tools via MCP. It responds to MCP
`initialize` instantly, then starts sourcekit-lsp in the background (Bridge-and-Poll).
First tool call may be slow while sourcekit-lsp indexes; subsequent calls are fast.

| Tool | Description |
|---|---|
| `swift_hover` | Type info + doc comments at file:line:char |
| `swift_definition` | Go to symbol definition |
| `swift_references` | Find all references across project |
| `swift_document_symbols` | Hierarchical file outline |
| `swift_workspace_symbol` | Search symbols by name |
| `swift_diagnostics` | Compiler errors/warnings for a file |
| `swift_call_hierarchy` | Call graph (incoming/outgoing) |
| `swift_implementations` | Protocol conformances, overrides |
| `swift_code_actions` | Available quick fixes |
| `swift_rename` | Rename symbol atomically across project |

### When to Use MCP Tools vs Grep

| Task | MCP Tool | Grep Fallback |
|---|---|---|
| Type info at a symbol | `swift_hover` | Read file + check imports |
| Find definition | `swift_definition` | `Grep -rnE "(struct\|class\|enum\|protocol\|actor) Name" Sources/` |
| Find references | `swift_references` | `Grep -rn "Name" Sources/ Tests/` |
| File outline | `swift_document_symbols` | Read file structure |
| Compiler errors | `swift_diagnostics` | `swift build` |
| Rename symbol | `swift_rename` | Multi-file `Grep` + `Edit` + `swift build` |
| Symbol search | `swift_workspace_symbol` | `Grep -rn "pattern" Sources/` |

### Discovery-First Protocol (fallback when MCP tools are unavailable)

**Phase A — Map the Module Graph (do this once per session)**

Read `Package.swift`. The module graph is:

```
SecurityHardening (standalone)
    ↑
ContainerComposeCore (depends on SecurityHardening, ContainerCommands, ArgumentParser, Yams, Rainbow)
    ↑
ContainerComposeApp (executable, depends on ContainerComposeCore)
```

Test targets depend on `ContainerComposeCore` + `TestHelpers`.
SecurityHardeningTests depends on both `SecurityHardening` and `ContainerComposeCore`.

**Key paths:**
- `Sources/SecurityHardening/` — standalone security module
- `Sources/Container-Compose/` — core library (most code lives here)
- `Sources/ContainerComposeApp/` — CLI entry point
- `Tests/Container-Compose-Tests/` — unit tests
- `Tests/Container-Compose-DynamicTests/` — dynamic/integration tests
- `Tests/SecurityHardeningTests/` — security module tests

**Phase B — Tactical Symbol Search**

- **Find a type definition:** `Grep -rnE "(struct|class|enum|protocol|actor) SymbolName" Sources/`
- **Find an extension:** `Grep -rnE "extension SymbolName" Sources/`
- **Find all usages:** `Grep -rn "SymbolName" Sources/ Tests/`
- **Check circular dependency risk:** Only `SecurityHardening` has no internal deps. `ContainerComposeCore` imports `SecurityHardening` but NOT vice versa — keep it that way.

### Build Rules

- **Always check for running Swift processes before building:** `ps aux | grep -E "swift-build|swift-frontend" | grep -v grep | wc -l` — wait if > 0
- **Use `swift build` for definitive compilation errors** — `swift_diagnostics` uses cached results from sourcekit-lsp and may miss issues
- **Use `./run-tests.sh` for tests** — handles cleanup, logging, port allocation
- **SwiftPM uses a `.build` lock** — only one build at a time; stale Xcode processes can hang indefinitely

### Surgical Editing Rules

- **Match local style:** Read the last 20 lines of a file before inserting code to match indentation and spacing exactly
- **No speculative search:** Only search `Sources/` sub-directories relevant to the current target's path
- **Clean up orphans:** If removing a symbol, check if it was the last use of an `import` and remove the import
- **Never use pyright on `.swift` files** — pyright is Python-only
- **Only edit files required by the task** — mention dead code but do not touch it
