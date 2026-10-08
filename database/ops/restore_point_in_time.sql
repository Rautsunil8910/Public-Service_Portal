/* =====================================================================
   Point-in-time restore (business continuity drill)
   Builds the restore chain from msdb backup history:
       latest FULL before @StopAt
     + latest DIFF after that full and before @StopAt
     + every LOG backup needed to reach @StopAt
   and restores it SIDE-BY-SIDE as a new database (production is untouched),
   so data can be compared or copied back.

   Usage:
     sqlcmd -S localhost -U sa -i restore_point_in_time.sql -v DbName=PublicServicePortal \
            StopAt="2026-10-07T14:30:00" TargetDb=PublicServicePortal_Restore DataDir=/var/opt/mssql/data Execute=0
   Execute=0 prints the script for review; Execute=1 runs it.
   See docs/backup-restore-runbook.md for the full procedure.
   ===================================================================== */
:on error exit
SET NOCOUNT ON;
USE msdb;
GO

DECLARE @Db       sysname       = N'$(DbName)',
        @Target   sysname       = N'$(TargetDb)',
        @StopAt   datetime      = '$(StopAt)',
        @DataDir  nvarchar(260) = N'$(DataDir)',
        @Execute  bit           = $(Execute);

DECLARE @FullId int, @FullLsn numeric(25,0), @DiffId int, @BaseLsn numeric(25,0), @sql nvarchar(max) = N'';

-- 1. Latest full backup that finished before the stop time.
SELECT TOP (1) @FullId = backup_set_id, @FullLsn = checkpoint_lsn
FROM dbo.backupset
WHERE database_name = @Db AND type = 'D' AND is_copy_only = 0 AND backup_finish_date <= @StopAt
ORDER BY backup_finish_date DESC;

IF @FullId IS NULL THROW 50010, 'No full backup found before the requested stop time.', 1;

-- 2. Latest differential based on that full.
SELECT TOP (1) @DiffId = backup_set_id
FROM dbo.backupset
WHERE database_name = @Db AND type = 'I' AND differential_base_lsn = @FullLsn AND backup_finish_date <= @StopAt
ORDER BY backup_finish_date DESC;

SET @BaseLsn = (SELECT last_lsn FROM dbo.backupset WHERE backup_set_id = COALESCE(@DiffId, @FullId));

-- Logical file names for MOVE (the restore goes to new physical files).
DECLARE @DataLogical sysname, @LogLogical sysname;
SELECT @DataLogical = MAX(CASE WHEN file_type = 'D' THEN logical_name END),
       @LogLogical  = MAX(CASE WHEN file_type = 'L' THEN logical_name END)
FROM dbo.backupfile WHERE backup_set_id = @FullId;

-- 3. Full
SELECT @sql += CONCAT(N'RESTORE DATABASE [', @Target, N'] FROM DISK = N''', mf.physical_device_name, N'''',
                      N' WITH NORECOVERY, REPLACE, CHECKSUM, STATS = 10,',
                      N' MOVE N''', @DataLogical, N''' TO N''', @DataDir, N'/', @Target, N'.mdf'',',
                      N' MOVE N''', @LogLogical,  N''' TO N''', @DataDir, N'/', @Target, N'_log.ldf'';', CHAR(10))
FROM dbo.backupmediafamily mf JOIN dbo.backupset bs ON bs.media_set_id = mf.media_set_id
WHERE bs.backup_set_id = @FullId;

-- 4. Differential
IF @DiffId IS NOT NULL
    SELECT @sql += CONCAT(N'RESTORE DATABASE [', @Target, N'] FROM DISK = N''', mf.physical_device_name,
                          N''' WITH NORECOVERY, CHECKSUM;', CHAR(10))
    FROM dbo.backupmediafamily mf JOIN dbo.backupset bs ON bs.media_set_id = mf.media_set_id
    WHERE bs.backup_set_id = @DiffId;

-- 5. Logs: every log whose range ends after the base, up to and including the first one that passes @StopAt.
DECLARE @LastLogId int = (
    SELECT TOP (1) backup_set_id FROM dbo.backupset
    WHERE database_name = @Db AND type = 'L' AND last_lsn > @BaseLsn AND backup_finish_date >= @StopAt
    ORDER BY backup_finish_date);

IF @LastLogId IS NULL
    PRINT '-- WARNING: no log backup covers the stop time yet; restoring to the latest available log instead.';

-- STRING_AGG ... WITHIN GROUP guarantees LSN order (variable concatenation with ORDER BY does not).
SELECT @sql += ISNULL(STRING_AGG(CAST(CONCAT(N'RESTORE LOG [', @Target, N'] FROM DISK = N''', mf.physical_device_name,
                      N''' WITH NORECOVERY, CHECKSUM, STOPAT = ''', CONVERT(varchar(23), @StopAt, 126), N''';') AS nvarchar(max)), CHAR(10))
                      WITHIN GROUP (ORDER BY bs.first_lsn), N'') + CHAR(10)
FROM dbo.backupset bs
JOIN dbo.backupmediafamily mf ON mf.media_set_id = bs.media_set_id
WHERE bs.database_name = @Db AND bs.type = 'L'
  AND bs.last_lsn > @BaseLsn
  AND (@LastLogId IS NULL OR bs.backup_finish_date <= (SELECT backup_finish_date FROM dbo.backupset WHERE backup_set_id = @LastLogId));

SET @sql += CONCAT(N'RESTORE DATABASE [', @Target, N'] WITH RECOVERY;', CHAR(10),
                   N'DBCC CHECKDB ([', @Target, N']) WITH NO_INFOMSGS;', CHAR(10));

PRINT N'-- Restore chain for ' + @Db + N' to ' + CONVERT(varchar(23), @StopAt, 126) + N' as ' + @Target;
PRINT @sql;

IF @Execute = 1
BEGIN
    EXEC sys.sp_executesql @sql;
    PRINT N'-- Restore complete. Verify with: SELECT COUNT(*) FROM [' + @Target + N'].core.ServiceRequest;';
END
GO
