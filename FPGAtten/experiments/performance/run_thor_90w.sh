#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 ]]; then
    echo "usage: $0 COMMAND [ARG ...]" >&2
    exit 2
fi

clock_state="/tmp/gqav7_thor_clocks_${USER}_$$.conf"
restore_clocks() {
    sudo jetson_clocks --restore "$clock_state" >/dev/null 2>&1 || true
    sudo rm -f "$clock_state"
}
trap restore_clocks EXIT INT TERM

sudo jetson_clocks --store "$clock_state"
sudo jetson_clocks
sudo jetson_clocks --show
"$@"
