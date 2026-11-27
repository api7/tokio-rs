#!/usr/bin/env bash
# Run the tests of the apisix/scripts tools: apisix/scripts/tests/run.sh
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
result=0
for test in "$here"/test-*.sh; do
    printf '== %s\n' "${test##*/}"
    bash "$test" || result=1
done
exit "$result"
