#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# XCTest is absent in standalone Command Line Tools; these checks need no test framework.
swift run CoreChecks
