#!/bin/sh
# Loads Empower's catalogue into RDS once. Runs as a one-off ECS task (see ci/run.sh).
set -eu
if [ "$(psql -tAc "select to_regclass('public.products') is not null")" = "t" ]; then
  echo "Database already seeded; nothing to do."
  exit 0
fi
psql -v ON_ERROR_STOP=1 -f /seed/empowerplant.sql
echo "Seeded: $(psql -tAc 'select count(*) from products') products."
