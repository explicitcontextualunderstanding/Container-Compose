#!/bin/bash
# Shared environment setup for Container-Compose build/test/install scripts
# Neutralizes conda-injected compiler flags and removes miniconda from PATH
# Loads OCI_REGISTRY_URL from ops.env if not already set
# Compatible with both bash and zsh (for interactive sourcing).
#
# Usage: source scripts/env-setup.sh
#
# Sets _ENV_SETUP_SUMMARY with a human-readable summary of what was done.

_ENV_SETUP_SUMMARY=""

# Load OCI_REGISTRY_URL if not already set
if [ -z "${OCI_REGISTRY_URL:-}" ]; then
  # Try to load from ops.env
  # Since BASH_SOURCE[0] is unreliable when sourced, use multiple methods:
  # 1. Check PWD (where the shell was when this was sourced)
  # 2. Check parent of scripts/ directory
  # 3. Check common workspace locations
  
  ENV_FILE=""
  
  # Method 1: PWD (most reliable when sourced from run-tests.sh)
  if [ -f "$PWD/ops.env" ]; then
    ENV_FILE="$PWD/ops.env"
  # Method 2: Relative to scripts/
  elif [ -f "$(dirname "${BASH_SOURCE[0]:-.}")/../ops.env" ]; then
    ENV_FILE="$(cd "$(dirname "${BASH_SOURCE[0]:-.}")/.." && pwd)/ops.env"
  # Method 3: Check up to 3 parent directories
  else
    for i in 1 2 3; do
      if [ -f "ops.env" ]; then
        ENV_FILE="$PWD/ops.env"
        break
      fi
      cd ..
    done
    cd "$PWD" 2>/dev/null || true
  fi

  if [ -f "$ENV_FILE" ]; then
    # Source the file and extract OCI_REGISTRY_URL
    while IFS= read -r line; do
      # Skip comments and empty lines
      [[ "$line" =~ ^[[:space:]]*# ]] && continue
      [[ -z "$line" ]] && continue

      # Extract OCI_REGISTRY_URL value (handles quoted and unquoted)
      if [[ "$line" =~ ^OCI_REGISTRY_URL=[\"\']?([^\"\'#[:space:]]+)[\"\']? ]]; then
        export OCI_REGISTRY_URL="${BASH_REMATCH[1]}"
        _ENV_SETUP_SUMMARY+="Loaded OCI_REGISTRY_URL from ops.env"
        break
      fi
    done < "$ENV_FILE"
  fi

  # Check if still not set
  if [ -z "$OCI_REGISTRY_URL" ]; then
    echo "⚠️ WARNING: OCI_REGISTRY_URL not set and ops.env not found or empty"
    echo "   Database tests requiring container registry will be skipped"
    echo "   Create ops.env with: OCI_REGISTRY_URL=registry.example.com"
  fi
fi

# Detect conda contamination
_CONDA_VARS=()
for _var in CPPFLAGS CFLAGS CXXFLAGS LDFLAGS DEBUG_CFLAGS DEBUG_CXXFLAGS CMAKE_ARGS \
            CONDA_TOOLCHAIN_BUILD CONDA_TOOLCHAIN_HOST CONDA_DEFAULT_ENV \
            CC CXX CC_FOR_BUILD CXX_FOR_BUILD OBJC_FOR_BUILD \
            _CE_CONDA _CE_M CONDA_PREFIX CONDA_PROMPT_MODIFIER; do
  eval "_val=\"\${$_var:-}\""
  if [ -n "$_val" ]; then
    _CONDA_VARS+=("$_var")
    unset "$_var" 2>/dev/null || true
  fi
done

_CONDA_PATH=""
if echo "$PATH" | tr ':' '\n' | grep -q 'miniconda'; then
  _CONDA_PATH="yes"
  export PATH="$(echo "$PATH" | tr ':' '\n' | grep -v 'miniconda' | tr '\n' ':')"
  export PATH="${PATH%:}"
fi

# Build summary
if [ ${#_CONDA_VARS[@]} -gt 0 ] || [ -n "$_CONDA_PATH" ]; then
  _ENV_SETUP_SUMMARY="Cleaned conda env"
  [ ${#_CONDA_VARS[@]} -gt 0 ] && _ENV_SETUP_SUMMARY+=" (unset ${#_CONDA_VARS[@]} vars)"
  [ -n "$_CONDA_PATH" ] && _ENV_SETUP_SUMMARY+=" (removed miniconda from PATH)"
fi
