#!/bin/bash
# Thin wrapper around the canonical deploy script.
set -e
exec "$(dirname "$0")/../scripts/deploy.sh" --module weka-axon "$@"
