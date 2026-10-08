/* =====================================================================
   Performance tuning walkthrough (JD duty 3 / duty 11)
   Run section by section in SSMS or Azure Data Studio with "Include Actual
   Execution Plan" on (Ctrl+M). Record YOUR numbers in docs/performance-tuning.md.

   Prerequisite: seeded data (SEED_ROWS=500000) and no tuning index yet.
   ===================================================================== */
USE PublicServicePortal;
GO

/* ---------------------------------------------------------------------
   STEP 1 - Reproduce the slow query as the application sees it.
   The supervisor dashboard (app.usp_Dashboard_Summary) computes SLA
   compliance for the last 90 days. Impersonate a supervisor session so
   Row-Level Security is applied exactly as in production.
   (Use a fresh query window: session context is read-only once set.)
   --------------------------------------------------------------------- */
DECLARE @SupervisorId int = (SELECT TOP (1) UserId FROM sec.AppUser WHERE RoleCode = 'SUPERVISOR' ORDER BY UserId);
EXEC app.usp_Session_Set @UserId = @SupervisorId;

DBCC DROPCLEANBUFFERS;   -- cold cache: worst case (DEV/TEST ONLY - never on production)
SET STATISTICS IO, TIME ON;

EXEC app.usp_Dashboard_Summary;

SET STATISTICS IO, TIME OFF;
/* Record from the Messages tab:
     - logical reads on 'ServiceRequest' for each statement
     - CPU time / elapsed time
   Look at the actual plan: expect a Clustered Index SCAN of core.ServiceRequest
   for the "submitted last 7 days", "closed last 7 days" and "SLA 90 days" tiles,
   because nothing indexes SubmittedAtUtc or ClosedAtUtc. */
GO

/* ---------------------------------------------------------------------
   STEP 2 - Confirm with Query Store / DMVs which statements cost the most.
   --------------------------------------------------------------------- */
SELECT TOP (10)
       qs.execution_count,
       qs.total_logical_reads / qs.execution_count AS avg_logical_reads,
       qs.total_elapsed_time  / qs.execution_count / 1000 AS avg_elapsed_ms,
       SUBSTRING(st.text, (qs.statement_start_offset / 2) + 1,
                 ((CASE qs.statement_end_offset WHEN -1 THEN DATALENGTH(st.text) ELSE qs.statement_end_offset END
                   - qs.statement_start_offset) / 2) + 1) AS statement_text
FROM sys.dm_exec_query_stats qs
CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) st
WHERE st.objectid = OBJECT_ID('app.usp_Dashboard_Summary')
ORDER BY avg_logical_reads DESC;

-- What the optimizer itself thinks is missing:
SELECT d.statement, d.equality_columns, d.inequality_columns, d.included_columns,
       s.user_seeks, s.avg_user_impact
FROM sys.dm_db_missing_index_details d
JOIN sys.dm_db_missing_index_groups g ON g.index_handle = d.index_handle
JOIN sys.dm_db_missing_index_group_stats s ON s.group_handle = g.index_group_handle
WHERE d.database_id = DB_ID()
ORDER BY s.avg_user_impact DESC;
GO

/* ---------------------------------------------------------------------
   STEP 3 - Fix: two narrow covering indexes on the date columns the
   dashboard filters on. INCLUDE the columns the queries read (and the
   RLS predicate's DepartmentId/ResidentId) so no key lookups are needed.
   ONLINE = ON needs Developer/Enterprise edition; remove it on Express/Standard.
   --------------------------------------------------------------------- */
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_ServiceRequest_Closed' AND object_id = OBJECT_ID('core.ServiceRequest'))
    CREATE INDEX IX_ServiceRequest_Closed ON core.ServiceRequest (ClosedAtUtc)
        INCLUDE (StatusCode, DueDate, DepartmentId, ResidentId)
        WHERE ClosedAtUtc IS NOT NULL
        WITH (ONLINE = ON, DATA_COMPRESSION = PAGE);

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_ServiceRequest_Submitted' AND object_id = OBJECT_ID('core.ServiceRequest'))
    CREATE INDEX IX_ServiceRequest_Submitted ON core.ServiceRequest (SubmittedAtUtc)
        INCLUDE (CategoryId, DepartmentId, ResidentId)
        WITH (ONLINE = ON, DATA_COMPRESSION = PAGE);
GO

/* ---------------------------------------------------------------------
   STEP 4 - Re-run STEP 1 in a NEW query window and compare reads / time.
   Then make the fix permanent: copy the two CREATE INDEX statements into a
   new migration (database/migrations/V005__dashboard_indexes.sql) so it is
   promoted Dev -> Test -> Prod through the pipeline like any other change.
   --------------------------------------------------------------------- */

/* ---------------------------------------------------------------------
   STEP 5 - Ongoing monitoring: index usage and fragmentation.
   --------------------------------------------------------------------- */
SELECT OBJECT_SCHEMA_NAME(i.object_id) + '.' + OBJECT_NAME(i.object_id) AS table_name, i.name AS index_name,
       us.user_seeks, us.user_scans, us.user_lookups, us.user_updates
FROM sys.indexes i
LEFT JOIN sys.dm_db_index_usage_stats us ON us.object_id = i.object_id AND us.index_id = i.index_id AND us.database_id = DB_ID()
WHERE OBJECTPROPERTY(i.object_id, 'IsUserTable') = 1 AND i.name IS NOT NULL
ORDER BY table_name, index_name;

SELECT OBJECT_NAME(ps.object_id) AS table_name, i.name AS index_name,
       ps.avg_fragmentation_in_percent, ps.page_count
FROM sys.dm_db_index_physical_stats(DB_ID(), NULL, NULL, NULL, 'LIMITED') ps
JOIN sys.indexes i ON i.object_id = ps.object_id AND i.index_id = ps.index_id
WHERE ps.page_count > 1000
ORDER BY ps.avg_fragmentation_in_percent DESC;
GO
