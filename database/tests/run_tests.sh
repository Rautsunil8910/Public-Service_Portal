#!/usr/bin/env bash
# Runs each test file in its own session (session context is per connection).
set -uo pipefail
SQL_SERVER="${SQL_SERVER:-localhost,1433}"; SQL_USER="${SQL_USER:-sa}"; DB_NAME="${DB_NAME:-PublicServicePortal}"
SQLCMD="${SQLCMD:-sqlcmd}"; SQLCMD_EXTRA="${SQLCMD_EXTRA:-}"
export SQLCMDPASSWORD="${SQL_PASSWORD:?SQL_PASSWORD must be set}"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
failed=0
for f in $(ls "$DIR"/T*.sql | sort); do
  if $SQLCMD -S "$SQL_SERVER" -U "$SQL_USER" -d "$DB_NAME" -b -I -f 65001 $SQLCMD_EXTRA -i "$f"; then :; else
    echo "FAILED: $(basename "$f")"; failed=$((failed + 1)); fi
done
echo "Database tests finished: $failed failure(s)"
exit $failed
