#!/bin/sh
set -eu

command -v xcodegen >/dev/null 2>&1 || {
  echo "xcodegen 2.45.4 or newer is required" >&2
  exit 1
}

xcodegen generate
swift package resolve --package-path Packages/TiebaCore
