/* =====================================================================
   SQL Server Agent jobs: backup strategy + nightly warehouse load
   (JD duty 9: "transaction logs and backup / recovery procedures")

   Strategy (database in FULL recovery model):
     Full         Sunday 01:00          -> weekly baseline
     Differential Mon-Sat 01:00         -> fast restores (full + 1 diff + logs)
     Log          every 15 minutes      -> RPO <= 15 minutes, point-in-time restore
     Warehouse    daily 02:00           -> ops.usp_Warehouse_Load
   All backups use CHECKSUM (detects page corruption) and COMPRESSION.

   Usage: sqlcmd -S localhost -U sa -i backup_jobs.sql -v DbName=PublicServicePortal BackupDir=/var/opt/mssql/backup
   Docker: the container must run with MSSQL_AGENT_ENABLED=true (see docker-compose.yml).
   ===================================================================== */
:on error exit
SET NOCOUNT ON;
USE msdb;
GO

DECLARE @Db sysname = N'$(DbName)', @Dir nvarchar(260) = N'$(BackupDir)';
DECLARE @Jobs TABLE (JobName sysname, Command nvarchar(max), FreqType int, FreqInterval int,
                     SubdayType int, SubdayInterval int, StartTime int, Description nvarchar(512));

-- Each command builds a timestamped file name, e.g. PublicServicePortal_LOG_20261007_181500.trn
INSERT @Jobs VALUES
 (CONCAT(@Db, N' - Full backup'),
  CONCAT(N'DECLARE @f nvarchar(400) = N''', @Dir, N'/', @Db, N'_FULL_'' + FORMAT(SYSDATETIME(), ''yyyyMMdd_HHmmss'') + N''.bak'';
BACKUP DATABASE [', @Db, N'] TO DISK = @f WITH CHECKSUM, COMPRESSION, INIT;
RESTORE VERIFYONLY FROM DISK = @f WITH CHECKSUM;'),
  8, 1, 1, 0, 10000, N'Weekly full backup (Sunday 01:00) followed by RESTORE VERIFYONLY.'),

 (CONCAT(@Db, N' - Differential backup'),
  CONCAT(N'DECLARE @f nvarchar(400) = N''', @Dir, N'/', @Db, N'_DIFF_'' + FORMAT(SYSDATETIME(), ''yyyyMMdd_HHmmss'') + N''.bak'';
BACKUP DATABASE [', @Db, N'] TO DISK = @f WITH DIFFERENTIAL, CHECKSUM, COMPRESSION, INIT;'),
  8, 126, 1, 0, 10000, N'Differential backup Monday-Saturday 01:00.'),

 (CONCAT(@Db, N' - Log backup'),
  CONCAT(N'DECLARE @f nvarchar(400) = N''', @Dir, N'/', @Db, N'_LOG_'' + FORMAT(SYSDATETIME(), ''yyyyMMdd_HHmmss'') + N''.trn'';
BACKUP LOG [', @Db, N'] TO DISK = @f WITH CHECKSUM, COMPRESSION, INIT;'),
  4, 1, 4, 15, 0, N'Transaction log backup every 15 minutes (RPO 15 min).'),

 (CONCAT(@Db, N' - Warehouse load'),
  N'EXEC ops.usp_Warehouse_Load;',
  4, 1, 1, 0, 20000, N'Nightly rebuild of the rpt star schema for SSRS / Excel / Power BI.');

DECLARE @JobName sysname, @Command nvarchar(max), @FreqType int, @FreqInterval int, @SubdayType int,
        @SubdayInterval int, @StartTime int, @Description nvarchar(512), @JobId uniqueidentifier;

DECLARE c CURSOR LOCAL FAST_FORWARD FOR SELECT * FROM @Jobs;
OPEN c;
FETCH NEXT FROM c INTO @JobName, @Command, @FreqType, @FreqInterval, @SubdayType, @SubdayInterval, @StartTime, @Description;
WHILE @@FETCH_STATUS = 0
BEGIN
    IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = @JobName)
        EXEC msdb.dbo.sp_delete_job @job_name = @JobName;

    SET @JobId = NULL;
    EXEC msdb.dbo.sp_add_job @job_name = @JobName, @description = @Description, @enabled = 1, @job_id = @JobId OUTPUT;
    EXEC msdb.dbo.sp_add_jobstep @job_id = @JobId, @step_name = N'Run', @subsystem = N'TSQL',
         @database_name = @Db, @command = @Command, @retry_attempts = 1, @retry_interval = 5;
    EXEC msdb.dbo.sp_add_jobschedule @job_id = @JobId, @name = N'Schedule', @enabled = 1,
         @freq_type = @FreqType, @freq_interval = @FreqInterval, @freq_recurrence_factor = 1,
         @freq_subday_type = @SubdayType, @freq_subday_interval = @SubdayInterval, @active_start_time = @StartTime;
    EXEC msdb.dbo.sp_add_jobserver @job_id = @JobId, @server_name = N'(local)';

    PRINT CONCAT('Created job: ', @JobName);
    FETCH NEXT FROM c INTO @JobName, @Command, @FreqType, @FreqInterval, @SubdayType, @SubdayInterval, @StartTime, @Description;
END
CLOSE c; DEALLOCATE c;

-- A log backup chain needs a full backup to start from: take one now.
DECLARE @first nvarchar(400) = CONCAT(@Dir, N'/', @Db, N'_FULL_', FORMAT(SYSDATETIME(), 'yyyyMMdd_HHmmss'), N'.bak');
DECLARE @sql nvarchar(max) = CONCAT(N'BACKUP DATABASE [', @Db, N'] TO DISK = @f WITH CHECKSUM, COMPRESSION, INIT;');
EXEC sys.sp_executesql @sql, N'@f nvarchar(400)', @f = @first;
PRINT CONCAT('Initial full backup written to ', @first);
GO
