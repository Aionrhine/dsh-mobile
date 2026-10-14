#!/bin/sh
set -eu
project_root="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
if [ "${1:-}" = "--prepare" ]; then
  exec python3 "$project_root/scripts/publish_r2_release.py" "$@"
fi
runtime="$project_root/build/r2-tools/bin/python"
if [ ! -x "$runtime" ]; then
  python3 -m venv "$project_root/build/r2-tools"
fi
if ! "$runtime" -c 'import boto3' >/dev/null 2>&1; then
  "$runtime" -m pip install -r "$project_root/scripts/r2-requirements.txt"
fi
exec "$runtime" "$project_root/scripts/publish_r2_release.py" "$@"
