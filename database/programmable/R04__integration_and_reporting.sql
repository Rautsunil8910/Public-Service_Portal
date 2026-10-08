/* =====================================================================
   R04 - ERP integration (service-oriented, XML) and BI warehouse load
   ===================================================================== */

/* Work orders ready to post to Finance, with the XML message built in SQL (FOR XML).
   Only the integration login (integ_executor) can run integ.* procedures. */
CREATE OR ALTER PROCEDURE integ.usp_ErpPosting_GetPending
    @BatchSize   int = 50,
    @MaxAttempts tinyint = 5
AS
BEGIN
    SET NOCOUNT ON;
    SELECT TOP (@BatchSize)
        r.RequestId,
        r.RequestNumber,
        r.ErpAttempts,
        (SELECT r.RequestNumber              AS [SourceReference],
                'PUBLIC-PORTAL'              AS [SourceSystem],
                r.CostCentre                 AS [CostCentre],
                d.Code                       AS [DepartmentCode],
                cp.PathName                  AS [Description],
                CAST(r.CostAmount AS decimal(12,2)) AS [Amount],
                'CAD'                        AS [Currency],
                CONVERT(char(10), CAST(r.ClosedAtUtc AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS date), 126) AS [PostingDate]
         FOR XML PATH('CostPosting'), TYPE) AS PayloadXml
    FROM core.ServiceRequest r
    JOIN core.Department d       ON d.DepartmentId = r.DepartmentId
    JOIN core.vw_CategoryPath cp ON cp.CategoryId = r.CategoryId
    WHERE r.StatusCode = 'CLOSED'
      AND r.CostAmount IS NOT NULL
      AND r.ErpPostedAtUtc IS NULL
      AND r.ErpAttempts < @MaxAttempts
    ORDER BY r.ErpAttempts, r.ClosedAtUtc;
END
GO

CREATE OR ALTER PROCEDURE integ.usp_ErpPosting_Record
    @RequestId       int,
    @Succeeded       bit,
    @RequestPayload  xml,
    @ResponsePayload xml           = NULL,
    @ErpDocumentNo   varchar(30)   = NULL,
    @ErrorMessage    nvarchar(1000) = NULL,
    @DurationMs      int           = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    BEGIN TRAN;
        DECLARE @Attempt tinyint;
        UPDATE core.ServiceRequest
        SET @Attempt       = ErpAttempts + 1,
            ErpAttempts    = ErpAttempts + 1,
            ErpPostedAtUtc = CASE WHEN @Succeeded = 1 THEN SYSUTCDATETIME() ELSE NULL END,
            ErpDocumentNo  = CASE WHEN @Succeeded = 1 THEN @ErpDocumentNo ELSE NULL END
        WHERE RequestId = @RequestId AND ErpPostedAtUtc IS NULL;

        IF @@ROWCOUNT = 0 THROW 50002, 'Request not pending ERP posting.', 1;

        INSERT integ.ErpPostingLog (RequestId, AttemptNo, RequestPayload, ResponsePayload, Succeeded, ErrorMessage, DurationMs)
        VALUES (@RequestId, @Attempt, @RequestPayload, @ResponsePayload, @Succeeded, @ErrorMessage, @DurationMs);
    COMMIT;
END
GO

CREATE OR ALTER PROCEDURE integ.usp_Error_Log
    @Source  varchar(100),
    @Message nvarchar(1000),
    @Detail  nvarchar(max) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    INSERT ops.ErrorLog (Source, Message, Detail, UserName) VALUES (@Source, LEFT(@Message, 1000), @Detail, N'integration-worker');
END
GO

/* ---------- Warehouse load (SQL Agent, nightly) ----------
   Full rebuild inside one transaction: reports never see a half-loaded warehouse. */
CREATE OR ALTER PROCEDURE ops.usp_Warehouse_Load
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @RunId bigint, @Rows int, @Today date = (SELECT Today FROM core.fn_LocalToday());

    INSERT ops.JobRun (JobName, StartedAtUtc) VALUES ('Warehouse_Load', SYSUTCDATETIME());
    SET @RunId = SCOPE_IDENTITY();

    BEGIN TRY
        BEGIN TRAN;
            DELETE rpt.FactServiceRequest;
            DELETE rpt.FactPermit;
            DELETE rpt.DimDate;
            DELETE rpt.DimDepartment;
            DELETE rpt.DimCategory;
            DELETE rpt.DimMunicipality;

            INSERT rpt.DimDate (DateKey, FullDate, [Year], [Quarter], [Month], MonthName, YearMonth, IsBusinessDay)
            SELECT CONVERT(int, CONVERT(char(8), CalendarDate, 112)), CalendarDate, YEAR(CalendarDate),
                   DATEPART(quarter, CalendarDate), MONTH(CalendarDate),
                   DATENAME(month, CalendarDate), CONVERT(char(7), CalendarDate, 126), IsBusinessDay
            FROM core.Calendar;

            INSERT rpt.DimDepartment (DepartmentKey, DepartmentCode, DepartmentName, DivisionName, OrgPath, OrgNode)
            SELECT d.DepartmentId, d.Code, d.Name, p.Name, d.OrgNode.ToString(), d.OrgNode
            FROM core.Department d
            LEFT JOIN core.Department p ON p.OrgNode = d.OrgNode.GetAncestor(1);

            INSERT rpt.DimCategory (CategoryKey, CategoryName, CategoryGroup, SlaBusinessDays)
            SELECT c.CategoryId, c.Name, p.Name, c.SlaBusinessDays
            FROM core.RequestCategory c
            JOIN core.RequestCategory p ON p.CategoryId = c.ParentCategoryId
            WHERE c.DepartmentId IS NOT NULL;

            INSERT rpt.DimMunicipality (MunicipalityKey, MunicipalityName)
            SELECT MunicipalityId, Name FROM core.Municipality;

            INSERT rpt.FactServiceRequest (RequestId, SubmittedDateKey, ClosedDateKey, DueDateKey, DepartmentKey, CategoryKey,
                                           MunicipalityKey, StatusCode, IsOpen, Priority, Channel, BusinessDaysOpen,
                                           IsOverdue, MetSla, CostAmount)
            SELECT r.RequestId,
                   CONVERT(int, CONVERT(char(8), x.SubmittedDate, 112)),
                   CONVERT(int, CONVERT(char(8), x.ClosedDate, 112)),
                   CONVERT(int, CONVERT(char(8), r.DueDate, 112)),
                   r.DepartmentId, r.CategoryId, r.MunicipalityId, r.StatusCode,
                   CASE WHEN s.IsTerminal = 0 THEN 1 ELSE 0 END,
                   r.Priority, r.Channel,
                   ce.BusinessDaySeq - cs.BusinessDaySeq,
                   CASE WHEN s.IsTerminal = 0 AND r.DueDate < @Today THEN 1 ELSE 0 END,
                   CASE WHEN r.StatusCode = 'CLOSED' THEN CASE WHEN x.ClosedDate <= r.DueDate THEN 1 ELSE 0 END END,
                   r.CostAmount
            FROM core.ServiceRequest r
            JOIN core.RequestStatus s ON s.StatusCode = r.StatusCode
            CROSS APPLY (SELECT CAST(r.SubmittedAtUtc AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS date) AS SubmittedDate,
                                CAST(r.ClosedAtUtc    AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS date) AS ClosedDate) x
            JOIN core.Calendar cs ON cs.CalendarDate = x.SubmittedDate
            JOIN core.Calendar ce ON ce.CalendarDate = COALESCE(x.ClosedDate, @Today);
            SET @Rows = @@ROWCOUNT;

            INSERT rpt.FactPermit (PermitId, SubmittedDateKey, DecidedDateKey, PermitTypeCode, PermitTypeName, StatusCode, ProjectValue, Fee)
            SELECT p.PermitId,
                   CONVERT(int, CONVERT(char(8), CAST(p.SubmittedAtUtc AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS date), 112)),
                   CONVERT(int, CONVERT(char(8), CAST(p.DecidedAtUtc   AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS date), 112)),
                   p.PermitTypeCode, pt.DisplayName, p.StatusCode, p.ProjectValue, p.Fee
            FROM core.Permit p
            JOIN core.PermitType pt ON pt.PermitTypeCode = p.PermitTypeCode;
            SET @Rows += @@ROWCOUNT;
        COMMIT;

        UPDATE ops.JobRun SET EndedAtUtc = SYSUTCDATETIME(), RowsAffected = @Rows, Succeeded = 1 WHERE JobRunId = @RunId;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        UPDATE ops.JobRun SET EndedAtUtc = SYSUTCDATETIME(), Succeeded = 0, Message = LEFT(ERROR_MESSAGE(), 1000) WHERE JobRunId = @RunId;
        INSERT ops.ErrorLog (Source, Message, Detail) VALUES ('ops.usp_Warehouse_Load', LEFT(ERROR_MESSAGE(), 1000), CONCAT('Line ', ERROR_LINE()));
        THROW;
    END CATCH
END
GO

/* ---------- Reporting views (read by SSRS / Excel / Power BI via rpt_reader) ---------- */
CREATE OR ALTER VIEW rpt.vw_SlaComplianceMonthly
AS
SELECT dd.[Year], dd.[Month], dd.YearMonth, dep.DivisionName, dep.DepartmentName, cat.CategoryGroup, cat.CategoryName,
       COUNT(*) AS ClosedRequests,
       SUM(CASE WHEN f.MetSla = 1 THEN 1 ELSE 0 END) AS MetSla,
       CAST(100.0 * SUM(CASE WHEN f.MetSla = 1 THEN 1 ELSE 0 END) / COUNT(*) AS decimal(5,1)) AS SlaPct,
       AVG(CAST(f.BusinessDaysOpen AS decimal(9,2))) AS AvgBusinessDays
FROM rpt.FactServiceRequest f
JOIN rpt.DimDate dd        ON dd.DateKey = f.ClosedDateKey
JOIN rpt.DimDepartment dep ON dep.DepartmentKey = f.DepartmentKey
JOIN rpt.DimCategory cat   ON cat.CategoryKey = f.CategoryKey
WHERE f.StatusCode = 'CLOSED'
GROUP BY dd.[Year], dd.[Month], dd.YearMonth, dep.DivisionName, dep.DepartmentName, cat.CategoryGroup, cat.CategoryName;
GO

CREATE OR ALTER VIEW rpt.vw_OpenRequestsByDepartment
AS
SELECT dep.DivisionName, dep.DepartmentName, cat.CategoryName, f.Priority,
       COUNT(*) AS OpenRequests,
       SUM(CAST(f.IsOverdue AS int)) AS OverdueRequests,
       MAX(f.BusinessDaysOpen) AS OldestBusinessDays
FROM rpt.FactServiceRequest f
JOIN rpt.DimDepartment dep ON dep.DepartmentKey = f.DepartmentKey
JOIN rpt.DimCategory cat   ON cat.CategoryKey = f.CategoryKey
WHERE f.IsOpen = 1
GROUP BY dep.DivisionName, dep.DepartmentName, cat.CategoryName, f.Priority;
GO

CREATE OR ALTER VIEW rpt.vw_RequestsByMunicipality
AS
SELECT dd.[Year], dd.[Quarter], m.MunicipalityName, cat.CategoryGroup,
       COUNT(*) AS Requests,
       SUM(CAST(f.IsOpen AS int)) AS StillOpen,
       SUM(f.CostAmount) AS TotalCost
FROM rpt.FactServiceRequest f
JOIN rpt.DimDate dd          ON dd.DateKey = f.SubmittedDateKey
JOIN rpt.DimMunicipality m   ON m.MunicipalityKey = f.MunicipalityKey
JOIN rpt.DimCategory cat     ON cat.CategoryKey = f.CategoryKey
GROUP BY dd.[Year], dd.[Quarter], m.MunicipalityName, cat.CategoryGroup;
GO

CREATE OR ALTER VIEW rpt.vw_PermitRevenueQuarterly
AS
SELECT dd.[Year], dd.[Quarter], f.PermitTypeName,
       COUNT(*) AS PermitsIssued, SUM(f.ProjectValue) AS ConstructionValue, SUM(f.Fee) AS FeeRevenue
FROM rpt.FactPermit f
JOIN rpt.DimDate dd ON dd.DateKey = f.DecidedDateKey
WHERE f.StatusCode = 'APPROVED'
GROUP BY dd.[Year], dd.[Quarter], f.PermitTypeName;
GO
