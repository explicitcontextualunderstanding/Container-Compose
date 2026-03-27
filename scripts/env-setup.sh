#!/bin/bash
# Shared environment setup for Container-Compose build/test/install scripts
# Neutralizes conda-injected compiler flags and removes miniconda from PATH
# Compatible with both bash and zsh (for interactive sourcing).
#
# Usage: source scripts/env-setup.sh
#
# Sets _ENV_SETUP_SUMMARY with a human-readable summary of what was done.

_ENV_SETUP_SUMMARY=""

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
