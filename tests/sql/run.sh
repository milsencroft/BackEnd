#!/usr/bin/env bash
# Runs every tests/sql/*.sql file against DATABASE_URL (use a throwaway or staging database).
# Each file ends with `raise exception 'PASS_ROLLBACK'`; any other error is a failure.
set -u
: "${DATABASE_URL:?set DATABASE_URL}"
fail=0
for f in "$(dirname "$0")"/*.sql; do
  out=$(psql "$DATABASE_URL" -v ON_ERROR_STOP=0 -f "$f" 2>&1)
  if echo "$out" | grep -q PASS_ROLLBACK; then echo "PASS $(basename "$f")"; else echo "FAIL $(basename "$f")"; echo "$out" | tail -5; fail=1; fi
done
exit $fail
