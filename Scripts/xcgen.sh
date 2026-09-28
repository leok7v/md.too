#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
xcodegen generate
