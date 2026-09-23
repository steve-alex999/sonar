#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build/ModuleCache
# Exercise signal types from the production source rather than duplicated implementations.
sed -n '/^struct Spectrum {/,/^final class Sonar:/{ /^final class Sonar:/!p; }' Sonar.swift > build/SignalTypes.swift
{ echo 'import Foundation'; cat build/SignalTypes.swift SignalTests.swift; } > build/main.swift
swiftc -module-cache-path build/ModuleCache build/main.swift -o build/SignalTests
build/SignalTests
