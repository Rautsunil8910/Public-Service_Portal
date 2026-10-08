#!/usr/bin/env bash
# =====================================================================
# Database deployment / code promotion (JD duty 4).
#  1. Creates the database if missing (FULL recovery, Query Store, RCSI).
#  2. Applies versioned migrations (migrations/V*.sql) exactly once each,
#     recorded in ops.SchemaVersion.
#  3. Re-applies all repeatable scripts (programmable/R*.sql: CREATE OR ALTER).
#  4. Creates/updates environment logins from secrets (post-deploy/logins.sql).
#  5. Optionally seeds demo data (SEED_ROWS=n).
# The same script deploys Dev, Test and Prod - only the variables change.
#
# Required env: SQL_PASSWORD
# Optional env: SQL_SERVER (localhost,1433) SQL_USER (sa) DB_NAME (PublicServicePortal)
#               APP_PASSWORD INTEG_PASSWORD RPT_PASSWORD  -> create logins
#               SEED_ROWS -> number of demo service requests to generate
#               INSTALL_AGENT_JOBS=true BACKUP_DIR=... -> create backup + warehouse SQL Agent jobs
#               SQLCMD (sqlcmd) SQLCMD_EXTRA (e.g. "-C" to trust a dev certificate)
# =====================================================================
set -euo pipefail

SQL_SERVER="${SQL_SERVER:-localhost,1433}"
SQL_USER="${SQL_USER:-sa}"
DB_NAME="${DB_NAME:-PublicServicePortal}"
SQLCMD="${SQLCMD:-sqlcmd}"
SQLCMD_EXTRA="${SQLCMD_EXTRA:-}"
: "${SQL_PASSWORD:?SQL_PASSWORD must be set}"
export SQLCMDPASSWORD="$SQL_PASSWORD"   # keeps the password off the process list

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# -b: stop on error   -I: QUOTED_IDENTIFIER ON (filtered indexes, XML)   -f 65001: read scripts as UTF-8
run()   { $SQLCMD -S "$SQL_SERVER" -U "$SQL_USER" -b -I -f 65001 $SQLCMD_EXTRA "$@"; }
query() { run -d "$DB_NAME" -h -1 -W -Q "SET NOCOUNT ON; $1" | tr -d '[:space:]'; }

echo "==> Target: $SQL_SERVER / $DB_NAME"

echo "==> Ensuring database exists"
[[ "$DB_NAME" =~ ^[A-Za-z0-9_]+$ ]] || { echo "DB_NAME may only contain letters, digits and _"; exit 1; }
run -d master -Q "
IF DB_ID('$DB_NAME') IS NULL CREATE DATABASE [$DB_NAME];
ALTER DATABASE [$DB_NAME] SET RECOVERY FULL;
ALTER DATABASE [$DB_NAME] SET QUERY_STORE = ON (OPERATION_MODE = READ_WRITE);
IF (SELECT is_read_committed_snapshot_on FROM sys.databases WHERE name = '$DB_NAME') = 0
    ALTER DATABASE [$DB_NAME] SET READ_COMMITTED_SNAPSHOT ON WITH ROLLBACK IMMEDIATE;"

run -d "$DB_NAME" -Q "
IF SCHEMA_ID('ops') IS NULL EXEC('CREATE SCHEMA ops');
IF OBJECT_ID('ops.SchemaVersion') IS NULL
    CREATE TABLE ops.SchemaVersion (
        Version      varchar(50)   NOT NULL PRIMARY KEY,
        ScriptName   nvarchar(260) NOT NULL,
        AppliedAtUtc datetime2(0)  NOT NULL DEFAULT SYSUTCDATETIME(),
        AppliedBy    sysname       NOT NULL DEFAULT SUSER_SNAME());"

echo "==> Versioned migrations"
for f in $(ls "$DIR"/migrations/V*.sql | sort); do
  name="$(basename "$f")"
  version="${name%%__*}"
  applied="$(query "SELECT COUNT(*) FROM ops.SchemaVersion WHERE Version = '$version'")"
  if [[ "$applied" == "0" ]]; then
    echo "    applying $name"
    run -d "$DB_NAME" -i "$f"
    run -d "$DB_NAME" -Q "INSERT ops.SchemaVersion (Version, ScriptName) VALUES ('$version', '$name')"
  else
    echo "    skip     $name (already applied)"
  fi
done

echo "==> Repeatable scripts (procedures, functions, views)"
for f in $(ls "$DIR"/programmable/R*.sql | sort); do
  echo "    $(basename "$f")"
  run -d "$DB_NAME" -i "$f"
done

if [[ -n "${APP_PASSWORD:-}" && -n "${INTEG_PASSWORD:-}" && -n "${RPT_PASSWORD:-}" ]]; then
  echo "==> Logins and users"
  run -d master -i "$DIR/post-deploy/logins.sql" \
      -v DbName="$DB_NAME" AppPassword="$APP_PASSWORD" IntegPassword="$INTEG_PASSWORD" RptPassword="$RPT_PASSWORD"
else
  echo "==> Skipping logins (APP_PASSWORD / INTEG_PASSWORD / RPT_PASSWORD not all set)"
fi

if [[ -n "${SEED_ROWS:-}" ]]; then
  existing="$(query "SELECT COUNT(*) FROM core.ServiceRequest")"
  if [[ "$existing" == "0" ]]; then
    echo "==> Seeding $SEED_ROWS demo service requests (this can take a few minutes)"
    run -d "$DB_NAME" -i "$DIR/ops/seed_demo_data.sql" -v RequestCount="$SEED_ROWS"
    run -d "$DB_NAME" -Q "EXEC ops.usp_Warehouse_Load"
  else
    echo "==> Seed skipped: $existing requests already exist"
  fi
fi

if [[ "${INSTALL_AGENT_JOBS:-}" == "true" ]]; then
  echo "==> SQL Agent jobs (backups every 15 min / daily / weekly, nightly warehouse load)"
  run -d msdb -i "$DIR/ops/backup_jobs.sql" -v DbName="$DB_NAME" BackupDir="${BACKUP_DIR:-/var/opt/mssql/data}"
fi

echo "==> Deployed. Current schema version: $(query "SELECT MAX(Version) FROM ops.SchemaVersion")"
