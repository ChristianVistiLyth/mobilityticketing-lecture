#!/bin/sh
# Rebuild the database and apply every lecture's migrations in number order.
# Docker runs the lecture*/init/ files listed in compose.yaml on the empty database.
#
#   sh scripts/db-reset.sh        init scripts + every migration
#   sh scripts/db-reset.sh 000    init scripts only (lecture 1 slice + weak ticketing schema)
#   sh scripts/db-reset.sh 011    stop after 011 (lecture 2 state)
#   sh scripts/db-reset.sh 022    stop after 022 (lecture 3 state, start of lecture 4)
#
# This deletes the database volume. Use it only on the local course database.
set -eu
cd "$(dirname "$0")/.."

last="${1:-999}"
case "$last" in
    ''|*[!0-9]*)
        echo "usage: sh scripts/db-reset.sh [last-migration-number, e.g. 011]" >&2
        exit 2
        ;;
esac

docker compose down -v
docker compose up -d --wait

# Migration numbers are unique across lectures, so sorting by file name gives the order.
migrations=$(for f in lecture*/migrations/*.sql; do echo "$(basename "$f") $f"; done | sort | cut -d' ' -f2)

for file in $migrations; do
    number=$(basename "$file" | cut -c1-3)
    if [ "$number" -gt "$last" ]; then
        break
    fi
    echo "== applying $file"
    docker compose exec -T postgres psql -U mobility -d mobility -v ON_ERROR_STOP=1 < "$file"
done
