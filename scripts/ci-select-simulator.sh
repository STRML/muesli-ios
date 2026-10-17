#!/usr/bin/env bash
# Prints the UDID of the iPhone simulator the CI jobs use.
#
# Every job that touches a simulator calls this, so the build and the test jobs
# agree on the device without sharing state. It is the selection the single-job
# pipeline used: the first available iPhone that is not in a transient state.
set -euo pipefail

udid="$(xcrun simctl list devices available | awk -F '[()]' '/iPhone/ && /Shutdown|Booted/ { print $2; exit }')"
if [ -z "$udid" ]; then
  echo "No available iPhone simulator found" >&2
  xcrun simctl list devices available >&2
  exit 1
fi
xcrun simctl list devices available | grep "$udid" >&2
echo "$udid"
