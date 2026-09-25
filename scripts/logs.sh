#!/bin/zsh
# Shows Stackling's logs.
#   scripts/logs.sh                 stream live (debug level included)
#   scripts/logs.sh 10m             the last 10 minutes
#   scripts/logs.sh 1h capture      the last hour, one category
#   scripts/logs.sh live stack      stream live, one category
#   TESTS=1 scripts/logs.sh 5m      include log lines from `swift test` runs
#
# Categories: app, stack, capture, recording, library, actions, keys, editor
set -e

span=${1:-live}
category=$2
predicate='subsystem == "io.github.leonmiltiadou.stackling"'
[ -z "$TESTS" ] && predicate="$predicate AND process == \"Stackling\""
[ -n "$category" ] && predicate="$predicate AND category == \"$category\""

if [ "$span" = "live" ]; then
  exec /usr/bin/log stream --level debug --style compact --predicate "$predicate"
else
  exec /usr/bin/log show --last "$span" --debug --info --style compact --predicate "$predicate"
fi
