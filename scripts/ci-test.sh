#!/bin/bash
# Runs the test suite for CI. If it's still going after 5 minutes (it normally takes seconds), prints a
# stack sample of the test process, so a hang shows exactly what the main thread was waiting on.
set -u
script -q /dev/null swift test &
runner=$!
for _ in $(seq 1 300); do
    if ! kill -0 "$runner" 2>/dev/null; then
        wait "$runner"
        exit $?
    fi
    sleep 1
done
echo "::error::Tests still running after 5 minutes. Sampling the test process:"
for pid in $(pgrep -f "swiftpm-testing-helper|StacklingPackageTests"); do
    echo "=== pid $pid: $(ps -o command= -p "$pid" | cut -c1-120)"
    sample "$pid" 2 -mayDie 2>/dev/null | sed -n '1,220p'
done
kill "$runner" 2>/dev/null
exit 1
