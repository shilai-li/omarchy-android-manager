#!/usr/bin/env bash

# The whole suite. Pure logic under plain node, plus the helpers run for real
# along every path that needs no phone.
#
#   bash test/test.sh

set -euo pipefail
cd "$(dirname "$0")/.."

node test/android-test.js
node test/scripts-test.js
