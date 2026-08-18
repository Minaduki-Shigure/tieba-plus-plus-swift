#!/usr/bin/env bash

set -euo pipefail

if [[ $# -ne 4 ]]; then
  echo "usage: $0 SIMULATOR_ID BUNDLE_ID APP_PATH ARTIFACT_DIR" >&2
  exit 64
fi

simulator_id="$1"
bundle_id="$2"
app_path="$3"
artifact_dir="$4"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
log_path="$artifact_dir/xctrace.log"
plan_path="$artifact_dir/time-profiler-plan.tsv"
results_path="$artifact_dir/time-profiler-results.tsv"
active_recorder_pid=""

mkdir -p "$artifact_dir"
: > "$log_path"

cleanup() {
  if [[ -n "$active_recorder_pid" ]]; then
    kill "$active_recorder_pid" 2>/dev/null || true
    wait "$active_recorder_pid" 2>/dev/null || true
  fi
  xcrun simctl terminate "$simulator_id" "$bundle_id" 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

xcrun simctl terminate "$simulator_id" "$bundle_id" 2>/dev/null || true
xcrun simctl uninstall "$simulator_id" "$bundle_id" 2>/dev/null || true
xcrun simctl install "$simulator_id" "$app_path" >> "$log_path" 2>&1
data_container="$(xcrun simctl get_app_container "$simulator_id" "$bundle_id" data)"
mkdir -p "$data_container/tmp"

record_profile() {
  local profile_id="$1"
  local scenario="$2"
  local experiment="$3"
  local attempt="$4"
  local trace_path="$artifact_dir/time-profiler-$profile_id.trace"
  local samples_path="$artifact_dir/time-profiler-$profile_id-samples.xml"
  local recorder_log="$artifact_dir/xctrace-$profile_id.log"
  local launch_output
  local app_pid
  local recorder_ready=0
  local marker_prefix="$data_container/tmp/tieba-scroll-profile-$profile_id"

  if [[ ! "$profile_id" =~ ^[a-z0-9-]+$ ]]; then
    echo "$profile_id: invalid profile identifier" >> "$log_path"
    return 1
  fi

  rm -rf "$trace_path"
  rm -f \
    "$samples_path" \
    "$recorder_log"
  rm -f \
    "$marker_prefix-ready" \
    "$marker_prefix-go" \
    "$marker_prefix-started" \
    "$marker_prefix-completed"
  xcrun simctl terminate "$simulator_id" "$bundle_id" 2>/dev/null || true

  if ! launch_output="$({
    SIMCTL_CHILD_TIEBA_PERFORMANCE_SCENARIO="$scenario" \
      SIMCTL_CHILD_TIEBA_PERFORMANCE_EXPERIMENT="$experiment" \
      SIMCTL_CHILD_TIEBA_PERFORMANCE_PROFILE_ID="$profile_id" \
      SIMCTL_CHILD_TIEBA_PERFORMANCE_AUTOSCROLL=1 \
      xcrun simctl launch --terminate-running-process \
        "$simulator_id" "$bundle_id" -AppleLanguages '(zh-Hans)'
  } 2>> "$log_path")"; then
    echo "$profile_id: application launch failed" >> "$log_path"
    return 1
  fi
  echo "$profile_id attempt $attempt launch ($scenario, $experiment): $launch_output" \
    >> "$log_path"
  app_pid="${launch_output##*: }"
  if [[ ! "$app_pid" =~ ^[0-9]+$ ]]; then
    echo "$profile_id: could not parse application PID" >> "$log_path"
    return 1
  fi
  if ! kill -0 "$app_pid" 2>/dev/null; then
    echo "$profile_id: application exited before profiling" >> "$log_path"
    return 1
  fi

  for _ in $(seq 1 100); do
    if [[ -f "$marker_prefix-ready" ]]; then break; fi
    if ! kill -0 "$app_pid" 2>/dev/null; then break; fi
    sleep 0.1
  done
  if [[ ! -f "$marker_prefix-ready" ]]; then
    echo "$profile_id: performance fixture did not become ready" >> "$log_path"
    xcrun simctl terminate "$simulator_id" "$bundle_id" 2>/dev/null || true
    return 1
  fi
  # The first xctrace attach on a freshly booted runner can lag process registration.
  sleep 0.5

  xcrun xctrace record \
    --template "Time Profiler" \
    --device "$simulator_id" \
    --attach "$app_pid" \
    --time-limit 24s \
    --no-prompt \
    --output "$trace_path" \
    > "$recorder_log" 2>&1 &
  active_recorder_pid=$!
  for _ in $(seq 1 80); do
    if grep -q "Ctrl-C to stop the recording" "$recorder_log" 2>/dev/null; then
      recorder_ready=1
      break
    fi
    if ! kill -0 "$active_recorder_pid" 2>/dev/null; then break; fi
    sleep 0.125
  done
  if [[ "$recorder_ready" -ne 1 ]]; then
    kill "$active_recorder_pid" 2>/dev/null || true
    wait "$active_recorder_pid" || true
    active_recorder_pid=""
    cat "$recorder_log" >> "$log_path"
    echo "$profile_id: Time Profiler did not enter the recording state" >> "$log_path"
    xcrun simctl terminate "$simulator_id" "$bundle_id" 2>/dev/null || true
    return 1
  fi
  touch "$marker_prefix-go"
  if ! wait "$active_recorder_pid"; then
    active_recorder_pid=""
    cat "$recorder_log" >> "$log_path"
    echo "$profile_id: Time Profiler recording failed" >> "$log_path"
    xcrun simctl terminate "$simulator_id" "$bundle_id" 2>/dev/null || true
    return 1
  fi
  active_recorder_pid=""
  cat "$recorder_log" >> "$log_path"
  xcrun simctl terminate "$simulator_id" "$bundle_id" 2>/dev/null || true

  if [[ ! -f "$marker_prefix-started" || ! -f "$marker_prefix-completed" ]]; then
    echo "$profile_id: autoscroll did not start and complete inside the trace window" >> "$log_path"
    return 1
  fi

  if ! xcrun xctrace export \
    --input "$trace_path" \
    --xpath '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]' \
    --output "$samples_path" \
    >> "$log_path" 2>&1; then
    echo "$profile_id: time-profile table export failed" >> "$log_path"
    return 1
  fi
  if [[ ! -s "$samples_path" ]]; then
    echo "$profile_id: exported profile is empty" >> "$log_path"
    return 1
  fi
  if ! grep -q "<row" "$samples_path"; then
    echo "$profile_id: exported profile has no application samples" >> "$log_path"
    return 1
  fi
}

cp "$script_dir/thread_scroll_profile_plan.tsv" "$plan_path"
ruby "$script_dir/validate_thread_scroll_profile_plan.rb" "$plan_path" > /dev/null

printf 'profile_id\tstatus\n' > "$results_path"
failed=0
while IFS=$'\t' read -r ordinal profile_id comparison variant replicate scenario experiment; do
  if [[ "$ordinal" == "ordinal" ]]; then continue; fi
  status=failure
  for attempt in 1 2; do
    if record_profile "$profile_id" "$scenario" "$experiment" "$attempt"; then
      status=success
      break
    fi
    echo "$profile_id attempt $attempt failed" >> "$log_path"
  done
  if [[ "$status" == failure ]]; then
    failed=1
  fi
  printf '%s\t%s\n' "$profile_id" "$status" >> "$results_path"
done < "$plan_path"

exit "$failed"
