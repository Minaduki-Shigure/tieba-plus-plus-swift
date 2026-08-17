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
log_path="$artifact_dir/xctrace.log"
scenarios=(baseline long-plain-text inline-replies many-floors)
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

record_scenario() {
  local scenario="$1"
  local trace_path="$artifact_dir/time-profiler-$scenario.trace"
  local toc_path="$artifact_dir/time-profiler-$scenario-toc.xml"
  local samples_path="$artifact_dir/time-profiler-$scenario-samples.xml"
  local potential_hangs_path="$artifact_dir/time-profiler-$scenario-potential-hangs.xml"
  local hang_risks_path="$artifact_dir/time-profiler-$scenario-hang-risks.xml"
  local recorder_log="$artifact_dir/xctrace-$scenario.log"
  local launch_output
  local app_pid
  local recorder_ready=0
  local marker_prefix="$data_container/tmp/tieba-scroll-profile-$scenario"

  rm -rf "$trace_path"
  rm -f \
    "$toc_path" \
    "$samples_path" \
    "$potential_hangs_path" \
    "$hang_risks_path" \
    "$recorder_log"
  rm -f \
    "$marker_prefix-ready" \
    "$marker_prefix-go" \
    "$marker_prefix-started" \
    "$marker_prefix-completed"
  xcrun simctl terminate "$simulator_id" "$bundle_id" 2>/dev/null || true

  if ! launch_output="$({
    SIMCTL_CHILD_TIEBA_PERFORMANCE_SCENARIO="$scenario" \
      SIMCTL_CHILD_TIEBA_PERFORMANCE_AUTOSCROLL=1 \
      xcrun simctl launch --terminate-running-process \
        "$simulator_id" "$bundle_id" -AppleLanguages '(zh-Hans)'
  } 2>> "$log_path")"; then
    echo "$scenario: application launch failed" >> "$log_path"
    return 1
  fi
  echo "$scenario launch: $launch_output" >> "$log_path"
  app_pid="${launch_output##*: }"
  if [[ ! "$app_pid" =~ ^[0-9]+$ ]]; then
    echo "$scenario: could not parse application PID" >> "$log_path"
    return 1
  fi
  if ! kill -0 "$app_pid" 2>/dev/null; then
    echo "$scenario: application exited before profiling" >> "$log_path"
    return 1
  fi

  for _ in $(seq 1 100); do
    if [[ -f "$marker_prefix-ready" ]]; then break; fi
    if ! kill -0 "$app_pid" 2>/dev/null; then break; fi
    sleep 0.1
  done
  if [[ ! -f "$marker_prefix-ready" ]]; then
    echo "$scenario: performance fixture did not become ready" >> "$log_path"
    xcrun simctl terminate "$simulator_id" "$bundle_id" 2>/dev/null || true
    return 1
  fi

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
    echo "$scenario: Time Profiler did not enter the recording state" >> "$log_path"
    xcrun simctl terminate "$simulator_id" "$bundle_id" 2>/dev/null || true
    return 1
  fi
  touch "$marker_prefix-go"
  if ! wait "$active_recorder_pid"; then
    active_recorder_pid=""
    cat "$recorder_log" >> "$log_path"
    echo "$scenario: Time Profiler recording failed" >> "$log_path"
    xcrun simctl terminate "$simulator_id" "$bundle_id" 2>/dev/null || true
    return 1
  fi
  active_recorder_pid=""
  cat "$recorder_log" >> "$log_path"
  xcrun simctl terminate "$simulator_id" "$bundle_id" 2>/dev/null || true

  if [[ ! -f "$marker_prefix-started" || ! -f "$marker_prefix-completed" ]]; then
    echo "$scenario: autoscroll did not start and complete inside the trace window" >> "$log_path"
    return 1
  fi

  if ! xcrun xctrace export \
    --input "$trace_path" \
    --toc \
    --output "$toc_path" \
    >> "$log_path" 2>&1; then
    echo "$scenario: trace TOC export failed" >> "$log_path"
    return 1
  fi
  if ! xcrun xctrace export \
    --input "$trace_path" \
    --xpath '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]' \
    --output "$samples_path" \
    >> "$log_path" 2>&1; then
    echo "$scenario: time-profile table export failed" >> "$log_path"
    return 1
  fi
  if ! xcrun xctrace export \
    --input "$trace_path" \
    --xpath '/trace-toc/run[@number="1"]/data/table[@schema="potential-hangs"]' \
    --output "$potential_hangs_path" \
    >> "$log_path" 2>&1; then
    echo "$scenario: potential-hangs table export failed" >> "$log_path"
    return 1
  fi
  if ! xcrun xctrace export \
    --input "$trace_path" \
    --xpath '/trace-toc/run[@number="1"]/data/table[@schema="hang-risks"]' \
    --output "$hang_risks_path" \
    >> "$log_path" 2>&1; then
    echo "$scenario: hang-risks table export failed" >> "$log_path"
    return 1
  fi
  if [[ ! -s "$toc_path" || ! -s "$samples_path" || ! -s "$potential_hangs_path" \
    || ! -s "$hang_risks_path" ]]; then
    echo "$scenario: exported profile is empty" >> "$log_path"
    return 1
  fi
  if ! grep -q "TiebaPlusPlus" "$toc_path" || ! grep -q "<row" "$samples_path"; then
    echo "$scenario: exported profile has no application samples" >> "$log_path"
    return 1
  fi
  echo "$scenario: success" >> "$artifact_dir/time-profiler-scenarios.txt"
}

: > "$artifact_dir/time-profiler-scenarios.txt"
failed=0
for scenario in "${scenarios[@]}"; do
  if ! record_scenario "$scenario"; then
    echo "$scenario: failure" >> "$artifact_dir/time-profiler-scenarios.txt"
    failed=1
  fi
done

exit "$failed"
