#!/bin/bash
# Thin wrapper around the canonical generate-manifests script.
set -e
exec "$(dirname "$0")/../scripts/generate-manifests.sh" --module weka-dedicated "$@"
