#!/bin/bash
set -e

echo "Building Wanderer.swiftpm..."

cd "$(dirname "$0")"
cd Wanderer.swiftpm

swift build

echo "Build successful!"
