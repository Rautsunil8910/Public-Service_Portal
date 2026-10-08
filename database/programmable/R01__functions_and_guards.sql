/* =====================================================================
   R01 - Functions and security guard procedures (repeatable: CREATE OR ALTER)
   Error numbers used across the API (the web app maps them to HTTP results):
     50001 access denied   50002 not found   50003 invalid workflow transition
     50004 concurrency conflict (row changed)  50005 validation failure
   ===================================================================== */

/* Local "today" for the County (SLA dates are local business days, not UTC). */
CREATE OR ALTER FUNCTION core.fn_LocalToday ()
RETURNS TABLE
AS RETURN
    SELECT CAST(SYSDATETIMEOFFSET() AT TIME ZONE 'Eastern Standard Time' AS date) AS Today;
GO

/* Add N business days to a date (weekends and statutory holidays skipped). */
CREATE OR ALTER FUNCTION core.fn_AddBusinessDays (@StartDate date, @Days int)
RETURNS TABLE
AS RETURN
    SELECT TOP (1) target.CalendarDate AS ResultDate
    FROM core.Calendar start
    JOIN core.Calendar target
      ON target.BusinessDaySeq = start.BusinessDaySeq + @Days
     AND target.IsBusinessDay = 1
    WHERE start.CalendarDate = @StartDate;
GO

/* Business days between two dates (O(1) thanks to the running sequence). */
CREATE OR ALTER FUNCTION core.fn_BusinessDaysBetween (@FromDate date, @ToDate date)
RETURNS TABLE
AS RETURN
    SELECT t.BusinessDaySeq - f.BusinessDaySeq AS BusinessDays
    FROM core.Calendar f
    JOIN core.Calendar t ON t.CalendarDate = @ToDate
    WHERE f.CalendarDate = @FromDate;
GO

/* Permit fee = base + rate per $1,000 of project value, clamped to min/max. */
CREATE OR ALTER FUNCTION core.fn_PermitFee (@PermitTypeCode varchar(20), @ProjectValue decimal(14,2))
RETURNS TABLE
AS RETURN
    SELECT pt.PermitTypeCode,
           pt.DisplayName,
           pt.BaseFee,
           pt.RatePerThousand,
           pt.MinFee,
           pt.MaxFee,
           CAST(CASE
                    WHEN raw.Amount < pt.MinFee THEN pt.MinFee
                    WHEN pt.MaxFee IS NOT NULL AND raw.Amount > pt.MaxFee THEN pt.MaxFee
                    ELSE raw.Amount
                END AS decimal(10,2)) AS Fee
    FROM core.PermitType pt
    CROSS APPLY (SELECT ROUND(pt.BaseFee + pt.RatePerThousand * @ProjectValue / 1000.0, 2) AS Amount) raw
    WHERE pt.PermitTypeCode = @PermitTypeCode;
GO

/* Category path, e.g. "Roads > Pothole" (recursive CTE over the category tree). */
CREATE OR ALTER VIEW core.vw_CategoryPath
AS
WITH tree AS (
    SELECT CategoryId, ParentCategoryId, Name, CAST(Name AS nvarchar(400)) AS PathName, 0 AS Depth,
           DepartmentId, SlaBusinessDays, DefaultPriority, IsActive
    FROM core.RequestCategory
    WHERE ParentCategoryId IS NULL
    UNION ALL
    SELECT c.CategoryId, c.ParentCategoryId, c.Name, CAST(t.PathName + N' > ' + c.Name AS nvarchar(400)), t.Depth + 1,
           c.DepartmentId, c.SlaBusinessDays, c.DefaultPriority, c.IsActive
    FROM core.RequestCategory c
    JOIN tree t ON t.CategoryId = c.ParentCategoryId
)
SELECT CategoryId, ParentCategoryId, Name, PathName, Depth, DepartmentId, SlaBusinessDays, DefaultPriority, IsActive
FROM tree;
GO

/* ---------- Guards: called at the top of app procedures ---------- */

-- Screen-level security re-checked in the database (defence in depth: a bug or a
-- crafted HTTP request in the web tier still cannot reach data it shouldn't).
CREATE OR ALTER PROCEDURE ops.usp_AssertScreen
    @ScreenCode varchar(40)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Role varchar(20) = CAST(SESSION_CONTEXT(N'RoleCode') AS varchar(20));

    IF @Role IS NULL
        THROW 50001, 'Access denied: no user session.', 1;

    IF NOT EXISTS (SELECT 1 FROM sec.RoleScreen WHERE RoleCode = @Role AND ScreenCode = @ScreenCode)
    BEGIN
        DECLARE @msg nvarchar(200) = CONCAT(N'Access denied: role ', @Role, N' cannot use ', @ScreenCode, N'.');
        THROW 50001, @msg, 1;
    END
END
GO

CREATE OR ALTER PROCEDURE ops.usp_AssertRole
    @AllowedRoles varchar(200)   -- comma separated
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Role varchar(20) = CAST(SESSION_CONTEXT(N'RoleCode') AS varchar(20));
    IF @Role IS NULL OR NOT EXISTS (SELECT 1 FROM STRING_SPLIT(@AllowedRoles, ',') WHERE value = @Role)
        THROW 50001, 'Access denied for this role.', 1;
END
GO
