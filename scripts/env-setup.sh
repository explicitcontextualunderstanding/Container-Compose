#!/bin/bash
# Shared environment setup for Container-Compose build/test/install scripts
# Neutralizes conda-injected compiler flags and removes miniconda from PATH
#
# Usage: source scripts/env-setup.sh

# Clear ALL conda-injected compiler flags and variables
unset CPPFLAGS CFLAGS CXXFLAGS LDFLAGS DEBUG_CFLAGS DEBUG_CXXFLAGS CMAKE_ARGS 2>/dev/null || true
unset CONDA_TOOLCHAIN_BUILD CONDA_TOOLCHAIN_HOST CONDA_DEFAULT_ENV 2>/dev/null || true
unset CC CXX CC_FOR_BUILD CXX_FOR_BUILD OBJC_FOR_BUILD 2>/dev/null || true
unset _CE_CONDA _CE_M CONDA_PREFIX CONDA_PROMPT_MODIFIER 2>/dev/null || true

# Remove miniconda from PATH
export PATH="$(echo "$PATH" | tr ':' '\n' | grep -v 'miniconda' | tr '\n' ':')"
export PATH="${PATH%:}"
