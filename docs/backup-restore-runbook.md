# Backup and restore runbook

**System:** Service Portal database `PublicServicePortal`
**Recovery objectives:** RPO 15 minutes (log backup interval). RTO under 1 hour for a database of this size.

## Backup schedule (SQL Server Agent)

| Job | When | Command |
|---|---|---|
| `PublicServicePortal - Full backup` | Sunday 01:00 | `BACKUP DATABASE ... WITH CHECKSUM, COMPRESSION` then `RESTORE VERIFYONLY` |
| `PublicServicePortal - Differential backup` | Mon–Sat 01:00 | `BACKUP DATABASE ... WITH DIFFERENTIAL, CHECKSUM, COMPRESSION` |
| `PublicServicePortal - Log backup` | Every 15 minutes | `BACKUP LOG ... WITH CHECKSUM, COMPRESSION` |
| `PublicServicePortal - Warehouse load` | Daily 02:00 | `EXEC ops.usp_Warehouse_Load` |

Installed by `database/ops/backup_jobs.sql`. The database runs in the FULL recovery model (set by `deploy.sh`), which is what makes log backups and point-in-time restore possible.

**Production note:** backup files must also be copied off the server (for example to a network share or immutable object storage) and kept per the records retention schedule. A backup on the same disk as the database is not a backup.

## Daily checks

```sql
-- Most recent backup of each type
SELECT type, MAX(backup_finish_date) AS last_finished
FROM msdb.dbo.backupset WHERE database_name = 'PublicServicePortal' GROUP BY type;

-- Failed Agent jobs in the last 24 hours
SELECT j.name, h.run_date, h.run_time, h.message
FROM msdb.dbo.sysjobhistory h JOIN msdb.dbo.sysjobs j ON j.job_id = h.job_id
WHERE h.run_status = 0 AND h.step_id = 0
  AND msdb.dbo.agent_datetime(h.run_date, h.run_time) > DATEADD(day, -1, GETDATE());
```

Alert if the newest log backup is older than 30 minutes or the newest full is older than 8 days.

## Scenario: data was damaged at a known time

Example: a faulty bulk update at 14:32 overwrote request priorities.

1. **Stop the damage.** Disable the job or account responsible. Record the time as precisely as possible from `ops.ErrorLog`, the temporal history tables, or the user.
2. **Take a tail-log backup** so nothing after the last scheduled log backup is lost:
   ```sql
   BACKUP LOG PublicServicePortal TO DISK = N'/var/opt/mssql/data/PublicServicePortal_TAIL.trn' WITH CHECKSUM, NO_TRUNCATE;
   ```
3. **Generate and review the restore chain** (restores side-by-side; production is untouched):
   ```bash
   sqlcmd -S <server> -U sa -i database/ops/restore_point_in_time.sql \
     -v DbName=PublicServicePortal StopAt="2026-10-07T14:31:00" TargetDb=PublicServicePortal_Restore \
        DataDir=/var/opt/mssql/data Execute=0
   ```
   The script reads `msdb` history and prints: the last full before the stop time, the last differential on that full, and every log backup needed, each with `STOPAT`.
4. **Run it** with `Execute=1`. The script finishes with `RESTORE ... WITH RECOVERY` and `DBCC CHECKDB`.
5. **Verify** in the restored copy: row counts, the damaged values, and the latest legitimate change.
6. **Repair.** Usually copy only the affected rows back (for example `UPDATE ... FROM PublicServicePortal_Restore.core.ServiceRequest`). Replace the whole database only if damage is widespread, and only with business sign-off, because it discards legitimate work after the stop time.
7. **Record** the incident: cause, stop time chosen, rows repaired, and time taken.

For small mistakes, check the temporal history first. It may make a restore unnecessary:
```sql
SELECT * FROM core.ServiceRequest FOR SYSTEM_TIME AS OF '2026-10-07T18:31:00' WHERE RequestId = 123;  -- UTC
```

## Drill log (fill in each time you test)

| Date | Stop time | Backups used | Restore duration | CHECKDB | Verified by | Notes |
|---|---|---|---|---|---|---|
| | | | | | | |

A restore that has never been tested is a hope, not a plan. Run this drill at least quarterly.
