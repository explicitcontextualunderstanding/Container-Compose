# Container-Compose

Swift 6.1 project for Apple Container runtime orchestration.

## Swift Environment Rules (Critical)

**No Swift LSP available via MCP bridge.** sourcekit-lsp cannot be routed through `mcp-language-server` (confirmed non-functional). Do NOT attempt to use any LSP tool on `.swift` files.

### Lost LSP Feature → Agent Workaround

| Lost Feature | Workaround |
|---|---|
| Error squiggles | `swift build` — parse line/column errors from output |
| Auto-complete | `Grep` for existing usage patterns of the API |
| Go to Definition | Follow `import` statements + `Grep` for `(struct\|class\|enum\|protocol\|actor) SymbolName` |
| Find References | `Grep -rn "SymbolName" Sources/` |
| Hover (type info) | Read the file; check `import` statements for module origin |
| Refactoring safety | Multi-file `Grep` + `Edit`, then `swift build` to catch breakage |

### Discovery-First Protocol

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
- **Use `swift build` for compilation errors** — this is the ONLY way to get Swift diagnostics
- **Use `./run-tests.sh` for tests** — handles cleanup, logging, port allocation
- **SwiftPM uses a `.build` lock** — only one build at a time; stale Xcode processes can hang indefinitely

### Surgical Editing Rules

- **Match local style:** Read the last 20 lines of a file before inserting code to match indentation and spacing exactly
- **No speculative search:** Only search `Sources/` sub-directories relevant to the current target's path
- **Clean up orphans:** If removing a symbol, check if it was the last use of an `import` and remove the import
- **Never use pyright on `.swift` files** — pyright is Python-only
- **Only edit files required by the task** — mention dead code but do not touch it
