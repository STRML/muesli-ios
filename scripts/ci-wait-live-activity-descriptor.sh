#!/usr/bin/env bash
# Install the built app on a booted simulator and wait until chronod has
# queried the Live Activity extension's widget descriptors.
#
# Until that query completes, chronod never launches the extension and the
# Dynamic Island renders empty ("Archive was nil. LiveActivity will be empty").
# On a freshly booted CI device the query can sit behind a backlog for minutes,
# so the UI test has to wait for this line instead of for a fixed delay.
#
# Usage: ci-wait-live-activity-descriptor.sh <udid> <path-to-Muesli.app>
#
# Never fails the job: after one reboot-and-retry it emits a ::warning:: and
# exits 0, so the test then fails exactly as it does without this step.
# Writes sim-diagnostics/descriptor-wait.txt:
#   descriptor_wait_seconds=<n> result=<found|timeout|reboot-found>
set -u

udid="${1:?usage: $0 <udid> <app>}"
app="${2:?usage: $0 <udid> <app>}"
bundle_id="com.samuelreed.muesli.ios"
# The exact text chronod logs; see the passing runs in issue #32.
marker="com.samuelreed.muesli.ios.liveactivity] query completed"
timeout_seconds="${DESCRIPTOR_TIMEOUT_SECONDS:-300}"
poll_seconds="${DESCRIPTOR_POLL_SECONDS:-10}"
out_dir="${DIAGNOSTICS_DIR:-sim-diagnostics}"
mkdir -p "$out_dir"

start=$SECONDS

install_and_launch() {
  xcrun simctl install "$udid" "$app" || echo "::warning::simctl install failed"
  xcrun simctl launch "$udid" "$bundle_id" || true
  sleep 2
  xcrun simctl terminate "$udid" "$bundle_id" || true
}

descriptor_logged() {
  xcrun simctl spawn "$udid" log show --last 10m --style compact --info --debug \
    --predicate "process == \"chronod\" AND eventMessage CONTAINS \"$marker\"" 2>/dev/null \
    | grep -qF "$marker"
}

# Polls until the line appears or the timeout passes. Returns 0 when found.
poll() {
  local deadline=$((SECONDS + timeout_seconds))
  while :; do
    if descriptor_logged; then
      return 0
    fi
    [ "$SECONDS" -ge "$deadline" ] && return 1
    sleep "$poll_seconds"
  done
}

record() {
  echo "descriptor_wait_seconds=$((SECONDS - start)) result=$1" | tee "$out_dir/descriptor-wait.txt"
}

install_and_launch
if poll; then
  record found
  exit 0
fi

echo "Descriptor query not seen after ${timeout_seconds}s; rebooting the simulator once."
xcrun simctl shutdown "$udid" || true
xcrun simctl boot "$udid" || true
xcrun simctl bootstatus "$udid" -b || true
install_and_launch
if poll; then
  record reboot-found
  exit 0
fi

record timeout
echo "::warning title=Live Activity descriptor::chronod never logged the Muesli extension descriptor query; the Dynamic Island test will probably render an empty island"
exit 0
