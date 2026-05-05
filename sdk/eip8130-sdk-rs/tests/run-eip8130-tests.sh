#!/usr/bin/env bash
# Compatibility wrapper: runs both basic + boundary suites in sequence.
# New usage prefers calling run-basic-tests.sh / run-boundary-tests.sh
# directly so individual scripts can be filtered or skipped.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
"$HERE/run-basic-tests.sh" "$@"
basic=$?
"$HERE/run-boundary-tests.sh" "$@"
boundary=$?
exit $(( basic | boundary ))
