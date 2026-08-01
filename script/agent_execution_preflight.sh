#!/bin/bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
exec python3 "$script_dir/agent_execution_controller.py" "$@"
