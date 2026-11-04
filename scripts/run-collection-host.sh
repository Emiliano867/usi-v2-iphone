#!/usr/bin/env bash
set -eo pipefail
umask 077
USI_PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
USI_COLLECTION_OVERLAY="${USI_COLLECTION_OVERLAY:-$USI_PROJECT_ROOT/../collection-ros/install/usi_collection_msgs/share/usi_collection_msgs/local_setup.bash}"
if [[ ! -f /opt/ros/jazzy/setup.bash || ! -f "$USI_COLLECTION_OVERLAY" ]]; then
    echo 'ROS 2 Jazzy and the usi_collection_msgs overlay are required. See docs/collection-host.md.' >&2
    exit 1
fi
source /opt/ros/jazzy/setup.bash
source "$USI_COLLECTION_OVERLAY"
cd -- "$USI_PROJECT_ROOT"
exec python3 -u -m usi_stream.collector --output-root "${1:-$HOME/usi_ws/recordings/suction-umi-v2}"
