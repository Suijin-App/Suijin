#!/bin/bash
# Generate Sevinda.xcodeproj from project.yml. Run after cloning or whenever project.yml changes.
set -euo pipefail
cd "$(dirname "$0")/.."
command -v xcodegen >/dev/null || { echo "xcodegen is required: brew install xcodegen" >&2; exit 1; }
xcodegen generate --quiet
echo "✓ Generated Sevinda.xcodeproj"
