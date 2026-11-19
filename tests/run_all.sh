#!/bin/sh
# Runs every test; stops at the first failure.

cd "$(dirname "$0")/.." || exit 1
sage tests/test_search.sage || exit 1
sage tests/test_bench.sage || exit 1
echo
for params in "37 6 4" "587 6 4" "587 6 8" "4099 6 8" "37 10 4" "37 18 4"; do
  set -- $params
  SKY_P=$1 SKY_ROUNDS=$2 SKY_BITS=$3 sage tests/selftest.sage || exit 1
  echo
done
echo "all tests passed"
