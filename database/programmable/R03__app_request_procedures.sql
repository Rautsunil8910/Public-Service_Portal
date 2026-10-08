/* =====================================================================
   R03 - Service request workflow, permits, dashboard, reports, admin logs
   All reads are automatically row-filtered by sec.RowAccessPolicy.
   ===================================================================== */

/* ---------- Service requests ---------- */
CREATE OR ALTER PROCEDURE app.usp_ServiceRequest_Create
    @CategoryId     int,
    @MunicipalityId tinyint,
    @Description    nvarchar(2000),
    @LocationText   nvarchar(200),
    @Latitude       decimal(9,6) = NULL,
    @Longitude      decimal(9,6) = NULL,
    @Channel        varchar(10)  = 'WEB',
    @Priority       tinyint      = NULL,
    -- Used when staff enter a request on a caller's behalf (phone/counter):
    @CallerFirstName nvarchar(60)  = NULL,
    @CallerLastName  nvarchar(60)  = NULL,
    @CallerEmail     nvarchar(254) = NULL,
    @CallerPhone     varchar(25)   = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    EXEC ops.usp_AssertScreen 'REQUEST_SUBMIT';

    DECLARE @Role varchar(20) = CAST(SESSION_CONTEXT(N'RoleCode') AS varchar(20)),
            @UserId int       = CAST(SESSION_CONTEXT(N'UserId') AS int),
            @ResidentId int   = CAST(SESSION_CONTEXT(N'ResidentId') AS int),
            @DepartmentId int, @Sla tinyint, @DefaultPriority tinyint, @DueDate date, @RequestId int;

    SELECT @DepartmentId = DepartmentId, @Sla = SlaBusinessDays, @DefaultPriority = DefaultPriority
    FROM core.RequestCategory
    WHERE CategoryId = @CategoryId AND IsActive = 1 AND DepartmentId IS NOT NULL;

    IF @DepartmentId IS NULL                       THROW 50005, 'Please choose a specific request category.', 1;
    IF LEN(LTRIM(ISNULL(@Description, N''))) < 10  THROW 50005, 'Please describe the problem (at least 10 characters).', 1;
    IF LEN(LTRIM(ISNULL(@LocationText, N''))) < 3  THROW 50005, 'Please give the location.', 1;
    IF NOT EXISTS (SELECT 1 FROM core.Municipality WHERE MunicipalityId = @MunicipalityId)
                                                   THROW 50005, 'Unknown municipality.', 1;

    -- Residents can only file as themselves, on the web channel, at the category's default priority.
    IF @Role = 'RESIDENT'
        SELECT @Channel = 'WEB', @Priority = NULL;

    SELECT @DueDate = ResultDate
    FROM core.fn_LocalToday() t
    CROSS APPLY core.fn_AddBusinessDays(t.Today, @Sla);

    BEGIN TRY
        BEGIN TRAN;
            IF @Role <> 'RESIDENT'
            BEGIN
                SET @ResidentId = NULL;
                IF @CallerEmail IS NOT NULL
                    SELECT @ResidentId = ResidentId FROM core.Resident WITH (UPDLOCK, HOLDLOCK) WHERE Email = @CallerEmail;

                IF @ResidentId IS NULL AND @CallerLastName IS NOT NULL
                BEGIN
                    INSERT core.Resident (FirstName, LastName, Email, Phone, MunicipalityId)
                    VALUES (ISNULL(@CallerFirstName, N''), @CallerLastName, @CallerEmail, @CallerPhone, @MunicipalityId);
                    SET @ResidentId = SCOPE_IDENTITY();
                END
            END

            INSERT core.ServiceRequest (CategoryId, DepartmentId, MunicipalityId, ResidentId, Channel, Priority,
                                        Description, LocationText, Latitude, Longitude, DueDate)
            VALUES (@CategoryId, @DepartmentId, @MunicipalityId, @ResidentId, @Channel, ISNULL(@Priority, @DefaultPriority),
                    @Description, @LocationText, @Latitude, @Longitude, @DueDate);
            SET @RequestId = SCOPE_IDENTITY();

            INSERT core.ServiceRequestEvent (RequestId, FromStatus, ToStatus, ChangedByUserId, Note)
            VALUES (@RequestId, NULL, 'SUBMITTED', @UserId, CONCAT(N'Submitted via ', @Channel));
        COMMIT;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        THROW;
    END CATCH

    SELECT RequestId, RequestNumber, DueDate FROM core.ServiceRequest WHERE RequestId = @RequestId;
END
GO

/* Catch-all search with paging. OPTION (RECOMPILE) gives each filter combination its own plan,
   avoiding the parameter-sniffing trap typical of optional-parameter queries. */
CREATE OR ALTER PROCEDURE app.usp_ServiceRequest_Search
    @StatusCode     varchar(20)   = NULL,   -- 'OPEN' = any non-terminal status
    @DepartmentId   int           = NULL,
    @MunicipalityId tinyint       = NULL,
    @SearchText     nvarchar(100) = NULL,
    @OverdueOnly    bit           = 0,
    @PageNumber     int           = 1,
    @PageSize       int           = 25
AS
BEGIN
    SET NOCOUNT ON;
    IF CAST(SESSION_CONTEXT(N'RoleCode') AS varchar(20)) IS NULL
        THROW 50001, 'Access denied: no user session.', 1;

    DECLARE @Today date = (SELECT Today FROM core.fn_LocalToday());
    SET @PageSize   = CASE WHEN @PageSize BETWEEN 1 AND 200 THEN @PageSize ELSE 25 END;
    SET @PageNumber = CASE WHEN @PageNumber >= 1 THEN @PageNumber ELSE 1 END;

    SELECT r.RequestId, r.RequestNumber, cp.PathName AS Category, d.Name AS Department,
           m.Name AS Municipality, r.LocationText, r.Priority, r.StatusCode, s.DisplayName AS StatusName,
           r.SubmittedAtUtc, r.DueDate,
           CAST(CASE WHEN s.IsTerminal = 0 AND r.DueDate < @Today THEN 1 ELSE 0 END AS bit) AS IsOverdue,
           COUNT(*) OVER () AS TotalRows
    FROM core.ServiceRequest r
    JOIN core.RequestStatus s     ON s.StatusCode = r.StatusCode
    JOIN core.vw_CategoryPath cp  ON cp.CategoryId = r.CategoryId
    JOIN core.Department d        ON d.DepartmentId = r.DepartmentId
    JOIN core.Municipality m      ON m.MunicipalityId = r.MunicipalityId
    WHERE (@StatusCode IS NULL OR (@StatusCode = 'OPEN' AND s.IsTerminal = 0) OR r.StatusCode = @StatusCode)
      AND (@DepartmentId IS NULL OR r.DepartmentId = @DepartmentId)
      AND (@MunicipalityId IS NULL OR r.MunicipalityId = @MunicipalityId)
      AND (@OverdueOnly = 0 OR (s.IsTerminal = 0 AND r.DueDate < @Today))
      AND (@SearchText IS NULL
           OR r.RequestNumber = @SearchText
           OR r.LocationText LIKE N'%' + @SearchText + N'%'
           OR r.Description  LIKE N'%' + @SearchText + N'%')
    ORDER BY CASE WHEN s.IsTerminal = 0 AND r.DueDate < @Today THEN 0 ELSE 1 END, r.Priority, r.DueDate, r.RequestId
    OFFSET (@PageNumber - 1) * @PageSize ROWS FETCH NEXT @PageSize ROWS ONLY
    OPTION (RECOMPILE);
END
GO

/* Three result sets: request, timeline, transitions the current role may perform. */
CREATE OR ALTER PROCEDURE app.usp_ServiceRequest_Get
    @RequestId int
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Role varchar(20) = CAST(SESSION_CONTEXT(N'RoleCode') AS varchar(20));
    IF @Role IS NULL THROW 50001, 'Access denied: no user session.', 1;
    IF @Role <> 'RESIDENT' EXEC ops.usp_AssertScreen 'REQUEST_DETAIL';

    DECLARE @Today date = (SELECT Today FROM core.fn_LocalToday());

    IF NOT EXISTS (SELECT 1 FROM core.ServiceRequest WHERE RequestId = @RequestId)   -- RLS-filtered
        THROW 50002, 'Request not found.', 1;

    -- Contact columns come back MASKED (Dynamic Data Masking) for every application role.
    SELECT r.RequestId, r.RequestNumber, r.CategoryId, cp.PathName AS Category,
           r.DepartmentId, d.Name AS Department, d.CostCentre AS DepartmentCostCentre,
           m.Name AS Municipality, r.Channel, r.Priority, r.StatusCode, s.DisplayName AS StatusName, s.IsTerminal,
           r.Description, r.LocationText, r.Latitude, r.Longitude,
           r.AssignedCrewId, c.Name AS AssignedCrew,
           r.SubmittedAtUtc, r.DueDate, r.ClosedAtUtc, r.Resolution,
           r.CostAmount, r.CostCentre, r.ErpPostedAtUtc, r.ErpDocumentNo,
           r.ResidentId, res.FirstName + N' ' + res.LastName AS ResidentName, res.Email AS ResidentEmail, res.Phone AS ResidentPhone,
           bd.BusinessDays AS BusinessDaysOpen,
           CAST(CASE WHEN s.IsTerminal = 0 AND r.DueDate < @Today THEN 1 ELSE 0 END AS bit) AS IsOverdue,
           r.RowVer
    FROM core.ServiceRequest r
    JOIN core.RequestStatus s    ON s.StatusCode = r.StatusCode
    JOIN core.vw_CategoryPath cp ON cp.CategoryId = r.CategoryId
    JOIN core.Department d       ON d.DepartmentId = r.DepartmentId
    JOIN core.Municipality m     ON m.MunicipalityId = r.MunicipalityId
    LEFT JOIN core.Crew c        ON c.CrewId = r.AssignedCrewId
    LEFT JOIN core.Resident res  ON res.ResidentId = r.ResidentId
    OUTER APPLY core.fn_BusinessDaysBetween(
        CAST(r.SubmittedAtUtc AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS date),
        COALESCE(CAST(r.ClosedAtUtc AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS date), @Today)) bd
    WHERE r.RequestId = @RequestId;

    SELECT e.EventId, e.FromStatus, e.ToStatus, e.ChangedAtUtc, e.Note, ISNULL(u.DisplayName, N'System') AS ChangedBy
    FROM core.ServiceRequestEvent e
    LEFT JOIN sec.AppUser u ON u.UserId = e.ChangedByUserId
    WHERE e.RequestId = @RequestId
    ORDER BY e.ChangedAtUtc, e.EventId;

    SELECT t.ToStatus, s.DisplayName
    FROM core.ServiceRequest r
    JOIN core.StatusTransition t ON t.FromStatus = r.StatusCode AND t.RoleCode = @Role
    JOIN core.RequestStatus s    ON s.StatusCode = t.ToStatus
    WHERE r.RequestId = @RequestId
    ORDER BY s.SortOrder;
END
GO

/* Workflow engine: validates the transition for the caller's role, enforces
   optimistic concurrency, and records the event - all in one transaction. */
CREATE OR ALTER PROCEDURE app.usp_ServiceRequest_Transition
    @RequestId  int,
    @ToStatus   varchar(20),
    @RowVer     binary(8),
    @Note       nvarchar(1000) = NULL,
    @CrewId     int            = NULL,   -- required for ASSIGNED
    @Resolution nvarchar(1000) = NULL,   -- required for CLOSED
    @Priority   tinyint        = NULL    -- optional re-prioritisation at triage
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Role varchar(20) = CAST(SESSION_CONTEXT(N'RoleCode') AS varchar(20)),
            @UserId int       = CAST(SESSION_CONTEXT(N'UserId') AS int),
            @From varchar(20), @Dept int, @CurrentVer binary(8);

    IF @Role IS NULL THROW 50001, 'Access denied: no user session.', 1;
    IF @Role <> 'RESIDENT' EXEC ops.usp_AssertScreen 'REQUEST_DETAIL';

    BEGIN TRY
        BEGIN TRAN;
            SELECT @From = StatusCode, @Dept = DepartmentId, @CurrentVer = RowVer
            FROM core.ServiceRequest WITH (UPDLOCK)
            WHERE RequestId = @RequestId;

            IF @From IS NULL           THROW 50002, 'Request not found.', 1;
            IF @CurrentVer <> @RowVer  THROW 50004, 'This request was changed by someone else. Reload and try again.', 1;

            IF NOT EXISTS (SELECT 1 FROM core.StatusTransition WHERE FromStatus = @From AND ToStatus = @ToStatus AND RoleCode = @Role)
            BEGIN
                DECLARE @msg nvarchar(200) = CONCAT(N'Your role cannot move a request from ', @From, N' to ', @ToStatus, N'.');
                THROW 50003, @msg, 1;
            END

            IF @ToStatus = 'ASSIGNED' AND NOT EXISTS (
                SELECT 1 FROM core.Crew c
                JOIN core.Department cd ON cd.DepartmentId = c.DepartmentId
                JOIN core.Department rd ON rd.DepartmentId = @Dept
                WHERE c.CrewId = @CrewId AND c.IsActive = 1 AND cd.OrgNode.IsDescendantOf(rd.OrgNode) = 1)
                THROW 50005, 'Choose an active crew from the responsible department.', 1;

            IF @ToStatus = 'CLOSED' AND LEN(LTRIM(ISNULL(@Resolution, N''))) < 5
                THROW 50005, 'A resolution description is required to close a request.', 1;

            IF @Priority IS NOT NULL AND @Priority NOT BETWEEN 1 AND 4
                THROW 50005, 'Priority must be between 1 and 4.', 1;

            UPDATE core.ServiceRequest
            SET StatusCode     = @ToStatus,
                AssignedCrewId = CASE WHEN @ToStatus = 'ASSIGNED' THEN @CrewId ELSE AssignedCrewId END,
                Priority       = COALESCE(CASE WHEN @Role = 'RESIDENT' THEN NULL ELSE @Priority END, Priority),
                ClosedAtUtc    = CASE WHEN @ToStatus IN ('CLOSED','CANCELLED') THEN SYSUTCDATETIME() ELSE NULL END,
                Resolution     = CASE WHEN @ToStatus = 'CLOSED' THEN @Resolution
                                      WHEN @ToStatus = 'CANCELLED' THEN COALESCE(@Note, N'Cancelled')
                                      ELSE NULL END
            WHERE RequestId = @RequestId AND RowVer = @RowVer;

            IF @@ROWCOUNT = 0 THROW 50004, 'This request was changed by someone else. Reload and try again.', 1;

            INSERT core.ServiceRequestEvent (RequestId, FromStatus, ToStatus, ChangedByUserId, Note)
            VALUES (@RequestId, @From, @ToStatus, @UserId, @Note);
        COMMIT;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        THROW;
    END CATCH
END
GO

/* Work-order cost, later posted to the ERP (finance) system by the integration worker. */
CREATE OR ALTER PROCEDURE app.usp_ServiceRequest_RecordCost
    @RequestId  int,
    @CostAmount decimal(12,2),
    @RowVer     binary(8)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    EXEC ops.usp_AssertRole 'SUPERVISOR,ADMIN';

    IF @CostAmount < 0 OR @CostAmount > 1000000
        THROW 50005, 'Cost must be between $0 and $1,000,000.', 1;

    BEGIN TRAN;
        IF EXISTS (SELECT 1 FROM core.ServiceRequest WITH (UPDLOCK) WHERE RequestId = @RequestId AND ErpPostedAtUtc IS NOT NULL)
            THROW 50005, 'Cost has already been posted to Finance and can no longer be edited.', 1;

        UPDATE r
        SET CostAmount = @CostAmount, CostCentre = d.CostCentre, ErpAttempts = 0
        FROM core.ServiceRequest r
        JOIN core.Department d ON d.DepartmentId = r.DepartmentId
        WHERE r.RequestId = @RequestId AND r.RowVer = @RowVer;

        IF @@ROWCOUNT = 0
        BEGIN
            IF NOT EXISTS (SELECT 1 FROM core.ServiceRequest WHERE RequestId = @RequestId)
                THROW 50002, 'Request not found.', 1;
            THROW 50004, 'This request was changed by someone else. Reload and try again.', 1;
        END

        INSERT core.ServiceRequestEvent (RequestId, FromStatus, ToStatus, ChangedByUserId, Note)
        SELECT RequestId, StatusCode, StatusCode, CAST(SESSION_CONTEXT(N'UserId') AS int),
               CONCAT(N'Cost recorded: $', FORMAT(@CostAmount, 'N2'))
        FROM core.ServiceRequest WHERE RequestId = @RequestId;
    COMMIT;
END
GO

/* MFIPPA: unmasked personal information is only released here - role-checked,
   purpose required, and every access is written to audit.PersonalInfoAccess.
   EXECUTE AS OWNER is what allows the unmasked read (the app login has no UNMASK). */
CREATE OR ALTER PROCEDURE app.usp_Resident_GetContact
    @ResidentId int,
    @Purpose    nvarchar(200)
WITH EXECUTE AS OWNER
AS
BEGIN
    SET NOCOUNT ON;
    EXEC ops.usp_AssertScreen 'RESIDENT_CONTACT';

    IF LEN(LTRIM(ISNULL(@Purpose, N''))) < 10
        THROW 50005, 'State the business purpose for viewing this information (at least 10 characters).', 1;

    -- Supervisors may only reveal residents linked to a request they can see (RLS applies here too).
    IF NOT EXISTS (SELECT 1 FROM core.ServiceRequest WHERE ResidentId = @ResidentId)
       AND CAST(SESSION_CONTEXT(N'RoleCode') AS varchar(20)) <> 'ADMIN'
        THROW 50001, 'You have no open business with this resident.', 1;

    INSERT audit.PersonalInfoAccess (UserId, ResidentId, Purpose)
    VALUES (CAST(SESSION_CONTEXT(N'UserId') AS int), @ResidentId, @Purpose);

    SELECT ResidentId, FirstName, LastName, Email, Phone, StreetAddress
    FROM core.Resident WHERE ResidentId = @ResidentId;
END
GO

/* ---------- Permits ---------- */
CREATE OR ALTER PROCEDURE app.usp_Permit_CalculateFee
    @PermitTypeCode varchar(20),
    @ProjectValue   decimal(14,2)
AS
BEGIN
    SET NOCOUNT ON;
    IF @ProjectValue < 0 THROW 50005, 'Project value cannot be negative.', 1;
    SELECT PermitTypeCode, DisplayName, BaseFee, RatePerThousand, MinFee, MaxFee, Fee
    FROM core.fn_PermitFee(@PermitTypeCode, @ProjectValue);
    IF @@ROWCOUNT = 0 THROW 50005, 'Unknown permit type.', 1;
END
GO

CREATE OR ALTER PROCEDURE app.usp_Permit_Submit
    @PermitTypeCode  varchar(20),
    @PropertyAddress nvarchar(200),
    @WorkDescription nvarchar(1000),
    @ProjectValue    decimal(14,2)
AS
BEGIN
    SET NOCOUNT ON;
    EXEC ops.usp_AssertScreen 'PERMIT_SUBMIT';

    DECLARE @ResidentId int = CAST(SESSION_CONTEXT(N'ResidentId') AS int), @Fee decimal(10,2), @PermitId int;
    IF @ResidentId IS NULL THROW 50005, 'Only resident accounts can apply for permits online.', 1;
    IF LEN(LTRIM(ISNULL(@PropertyAddress, N''))) < 5  THROW 50005, 'Property address is required.', 1;
    IF LEN(LTRIM(ISNULL(@WorkDescription, N''))) < 10 THROW 50005, 'Describe the proposed work.', 1;
    IF @ProjectValue < 0 OR @ProjectValue > 100000000  THROW 50005, 'Project value is out of range.', 1;

    -- Fee is always computed server-side; a value sent by the browser is never trusted.
    SELECT @Fee = Fee FROM core.fn_PermitFee(@PermitTypeCode, @ProjectValue);
    IF @Fee IS NULL THROW 50005, 'Unknown permit type.', 1;

    INSERT core.Permit (PermitTypeCode, ResidentId, PropertyAddress, WorkDescription, ProjectValue, Fee)
    VALUES (@PermitTypeCode, @ResidentId, @PropertyAddress, @WorkDescription, @ProjectValue, @Fee);
    SET @PermitId = SCOPE_IDENTITY();

    SELECT PermitId, PermitNumber, Fee FROM core.Permit WHERE PermitId = @PermitId;
END
GO

CREATE OR ALTER PROCEDURE app.usp_Permit_Search
    @StatusCode varchar(20) = NULL,
    @PageNumber int = 1,
    @PageSize   int = 25
AS
BEGIN
    SET NOCOUNT ON;
    IF CAST(SESSION_CONTEXT(N'RoleCode') AS varchar(20)) IS NULL THROW 50001, 'Access denied: no user session.', 1;
    SET @PageSize   = CASE WHEN @PageSize BETWEEN 1 AND 200 THEN @PageSize ELSE 25 END;
    SET @PageNumber = CASE WHEN @PageNumber >= 1 THEN @PageNumber ELSE 1 END;

    SELECT p.PermitId, p.PermitNumber, pt.DisplayName AS PermitType, p.PropertyAddress, p.WorkDescription,
           p.ProjectValue, p.Fee, p.StatusCode, p.SubmittedAtUtc, p.DecidedAtUtc, p.DecisionNote,
           r.FirstName + N' ' + r.LastName AS Applicant, p.RowVer,
           COUNT(*) OVER () AS TotalRows
    FROM core.Permit p
    JOIN core.PermitType pt ON pt.PermitTypeCode = p.PermitTypeCode
    JOIN core.Resident r    ON r.ResidentId = p.ResidentId
    WHERE @StatusCode IS NULL OR p.StatusCode = @StatusCode
    ORDER BY CASE p.StatusCode WHEN 'SUBMITTED' THEN 0 WHEN 'UNDER_REVIEW' THEN 1 ELSE 2 END, p.SubmittedAtUtc DESC
    OFFSET (@PageNumber - 1) * @PageSize ROWS FETCH NEXT @PageSize ROWS ONLY
    OPTION (RECOMPILE);
END
GO

CREATE OR ALTER PROCEDURE app.usp_Permit_Decide
    @PermitId   int,
    @Decision   varchar(20),     -- UNDER_REVIEW | APPROVED | REJECTED
    @RowVer     binary(8),
    @Note       nvarchar(500) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    EXEC ops.usp_AssertScreen 'PERMIT_QUEUE';
    DECLARE @Role varchar(20) = CAST(SESSION_CONTEXT(N'RoleCode') AS varchar(20)), @Current varchar(20);

    SELECT @Current = StatusCode FROM core.Permit WHERE PermitId = @PermitId;
    IF @Current IS NULL THROW 50002, 'Permit not found.', 1;

    IF NOT ((@Current = 'SUBMITTED' AND @Decision = 'UNDER_REVIEW')
         OR (@Current = 'UNDER_REVIEW' AND @Decision IN ('APPROVED','REJECTED')))
        THROW 50003, 'That decision is not valid for the permit''s current status.', 1;

    IF @Decision IN ('APPROVED','REJECTED') AND @Role NOT IN ('SUPERVISOR','ADMIN')
        THROW 50001, 'Only a supervisor can approve or reject a permit.', 1;

    IF @Decision = 'REJECTED' AND LEN(LTRIM(ISNULL(@Note, N''))) < 5
        THROW 50005, 'A reason is required when rejecting a permit.', 1;

    UPDATE core.Permit
    SET StatusCode = @Decision,
        DecisionNote = COALESCE(@Note, DecisionNote),
        DecidedAtUtc    = CASE WHEN @Decision IN ('APPROVED','REJECTED') THEN SYSUTCDATETIME() ELSE NULL END,
        DecidedByUserId = CAST(SESSION_CONTEXT(N'UserId') AS int)
    WHERE PermitId = @PermitId AND RowVer = @RowVer;

    IF @@ROWCOUNT = 0 THROW 50004, 'This permit was changed by someone else. Reload and try again.', 1;
END
GO

/* ---------- Dashboard (live, RLS-filtered) ---------- */
CREATE OR ALTER PROCEDURE app.usp_Dashboard_Summary
AS
BEGIN
    SET NOCOUNT ON;
    EXEC ops.usp_AssertScreen 'DASHBOARD';
    DECLARE @Today date = (SELECT Today FROM core.fn_LocalToday()),
            @Since90 datetime2(0) = DATEADD(day, -90, SYSUTCDATETIME()),
            @Since7  datetime2(0) = DATEADD(day, -7,  SYSUTCDATETIME());

    -- 1. KPI tiles
    SELECT
        (SELECT COUNT(*) FROM core.ServiceRequest r JOIN core.RequestStatus s ON s.StatusCode = r.StatusCode
          WHERE s.IsTerminal = 0)                                                     AS OpenCount,
        (SELECT COUNT(*) FROM core.ServiceRequest r JOIN core.RequestStatus s ON s.StatusCode = r.StatusCode
          WHERE s.IsTerminal = 0 AND r.DueDate < @Today)                              AS OverdueCount,
        (SELECT COUNT(*) FROM core.ServiceRequest WHERE SubmittedAtUtc >= @Since7)    AS SubmittedLast7Days,
        (SELECT COUNT(*) FROM core.ServiceRequest WHERE ClosedAtUtc >= @Since7 AND StatusCode = 'CLOSED') AS ClosedLast7Days,
        (SELECT CAST(100.0 * SUM(CASE WHEN CAST(ClosedAtUtc AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS date) <= DueDate THEN 1 ELSE 0 END)
                     / NULLIF(COUNT(*), 0) AS decimal(5,1))
           FROM core.ServiceRequest WHERE ClosedAtUtc >= @Since90 AND StatusCode = 'CLOSED') AS SlaCompliancePct90Days;

    -- 2. Open work by status
    SELECT s.StatusCode, s.DisplayName, COUNT(r.RequestId) AS RequestCount
    FROM core.RequestStatus s
    LEFT JOIN core.ServiceRequest r ON r.StatusCode = s.StatusCode
    WHERE s.IsTerminal = 0
    GROUP BY s.StatusCode, s.DisplayName, s.SortOrder
    ORDER BY s.SortOrder;

    -- 3. Open and overdue by department
    SELECT d.Name AS Department, COUNT(*) AS OpenCount,
           SUM(CASE WHEN r.DueDate < @Today THEN 1 ELSE 0 END) AS OverdueCount
    FROM core.ServiceRequest r
    JOIN core.RequestStatus s ON s.StatusCode = r.StatusCode AND s.IsTerminal = 0
    JOIN core.Department d ON d.DepartmentId = r.DepartmentId
    GROUP BY d.Name
    ORDER BY OverdueCount DESC, OpenCount DESC;

    -- 4. Top categories in the last 30 days
    SELECT TOP (5) cp.PathName AS Category, COUNT(*) AS RequestCount
    FROM core.ServiceRequest r
    JOIN core.vw_CategoryPath cp ON cp.CategoryId = r.CategoryId
    WHERE r.SubmittedAtUtc >= DATEADD(day, -30, SYSUTCDATETIME())
    GROUP BY cp.PathName
    ORDER BY RequestCount DESC;
END
GO

/* ---------- Reports (Excel exports in the app; same data as the SSRS reports) ---------- */
-- Supervisors are limited to their own branch of the org chart even on the
-- warehouse tables, which are outside RLS.
CREATE OR ALTER FUNCTION ops.fn_ReportScopeNode ()
RETURNS TABLE
AS RETURN
    SELECT COALESCE(
             (SELECT d.OrgNode FROM core.Department d
              WHERE CAST(SESSION_CONTEXT(N'RoleCode') AS varchar(20)) = 'SUPERVISOR'
                AND d.DepartmentId = CAST(SESSION_CONTEXT(N'DepartmentId') AS int)),
             hierarchyid::GetRoot()) AS ScopeNode;
GO

CREATE OR ALTER PROCEDURE app.usp_Report_SlaByMonth
    @FromDate date,
    @ToDate   date
AS
BEGIN
    SET NOCOUNT ON;
    EXEC ops.usp_AssertScreen 'REPORTS';
    DECLARE @Scope hierarchyid = (SELECT ScopeNode FROM ops.fn_ReportScopeNode());

    SELECT dd.YearMonth, dep.DepartmentName,
           COUNT(*) AS ClosedRequests,
           SUM(CASE WHEN f.MetSla = 1 THEN 1 ELSE 0 END) AS MetSla,
           CAST(100.0 * SUM(CASE WHEN f.MetSla = 1 THEN 1 ELSE 0 END) / COUNT(*) AS decimal(5,1)) AS SlaPct,
           CAST(AVG(CAST(f.BusinessDaysOpen AS decimal(9,2))) AS decimal(9,1)) AS AvgBusinessDays
    FROM rpt.FactServiceRequest f
    JOIN rpt.DimDate dd        ON dd.DateKey = f.ClosedDateKey
    JOIN rpt.DimDepartment dep ON dep.DepartmentKey = f.DepartmentKey
    WHERE f.StatusCode = 'CLOSED'
      AND dd.FullDate BETWEEN @FromDate AND @ToDate
      AND dep.OrgNode.IsDescendantOf(@Scope) = 1
    GROUP BY dd.YearMonth, dep.DepartmentName
    ORDER BY dd.YearMonth, dep.DepartmentName;
END
GO

CREATE OR ALTER PROCEDURE app.usp_Report_OpenByDepartment
AS
BEGIN
    SET NOCOUNT ON;
    EXEC ops.usp_AssertScreen 'REPORTS';
    DECLARE @Today date = (SELECT Today FROM core.fn_LocalToday());

    SELECT d.Name AS Department, cp.PathName AS Category, s.DisplayName AS Status,
           COUNT(*) AS OpenRequests,
           SUM(CASE WHEN r.DueDate < @Today THEN 1 ELSE 0 END) AS Overdue,
           MIN(r.SubmittedAtUtc) AS OldestSubmittedUtc
    FROM core.ServiceRequest r                      -- RLS limits supervisors automatically
    JOIN core.RequestStatus s    ON s.StatusCode = r.StatusCode AND s.IsTerminal = 0
    JOIN core.Department d       ON d.DepartmentId = r.DepartmentId
    JOIN core.vw_CategoryPath cp ON cp.CategoryId = r.CategoryId
    GROUP BY d.Name, cp.PathName, s.DisplayName, s.SortOrder
    ORDER BY d.Name, cp.PathName, s.SortOrder;
END
GO

CREATE OR ALTER PROCEDURE app.usp_Report_PermitRevenue
    @Year smallint
AS
BEGIN
    SET NOCOUNT ON;
    EXEC ops.usp_AssertScreen 'REPORTS';
    SELECT dd.[Quarter], f.PermitTypeName,
           COUNT(*) AS PermitsIssued,
           SUM(f.ProjectValue) AS ConstructionValue,
           SUM(f.Fee) AS FeeRevenue
    FROM rpt.FactPermit f
    JOIN rpt.DimDate dd ON dd.DateKey = f.DecidedDateKey
    WHERE f.StatusCode = 'APPROVED' AND dd.[Year] = @Year
    GROUP BY dd.[Quarter], f.PermitTypeName
    ORDER BY dd.[Quarter], f.PermitTypeName;
END
GO

/* ---------- Support / administration ---------- */
-- Called by the app's global error handler; needs no user session.
CREATE OR ALTER PROCEDURE app.usp_Error_Log
    @Source        varchar(100),
    @Message       nvarchar(1000),
    @Detail        nvarchar(max) = NULL,
    @UserName      nvarchar(100) = NULL,
    @CorrelationId varchar(64)   = NULL
AS
BEGIN
    SET NOCOUNT ON;
    INSERT ops.ErrorLog (Source, Message, Detail, UserName, CorrelationId)
    VALUES (@Source, LEFT(@Message, 1000), @Detail, @UserName, @CorrelationId);
END
GO

CREATE OR ALTER PROCEDURE app.usp_Error_List
    @Top int = 100
AS
BEGIN
    SET NOCOUNT ON;
    EXEC ops.usp_AssertScreen 'ADMIN_ERRORS';
    SELECT TOP (@Top) ErrorId, Source, Message, Detail, UserName, CorrelationId, LoggedAtUtc
    FROM ops.ErrorLog ORDER BY LoggedAtUtc DESC, ErrorId DESC;
END
GO

CREATE OR ALTER PROCEDURE app.usp_Audit_PersonalInfoAccess_List
    @ResidentId int = NULL,
    @Top        int = 200
AS
BEGIN
    SET NOCOUNT ON;
    EXEC ops.usp_AssertScreen 'ADMIN_AUDIT';
    SELECT TOP (@Top) a.AccessId, a.AccessedAtUtc, u.UserName, u.DisplayName, u.RoleCode,
           a.ResidentId, a.Purpose, a.HostName
    FROM audit.PersonalInfoAccess a
    JOIN sec.AppUser u ON u.UserId = a.UserId
    WHERE @ResidentId IS NULL OR a.ResidentId = @ResidentId
    ORDER BY a.AccessedAtUtc DESC, a.AccessId DESC;
END
GO

/* Change history straight from the temporal table: who changed what, and when. */
CREATE OR ALTER PROCEDURE app.usp_ServiceRequest_History
    @RequestId int
AS
BEGIN
    SET NOCOUNT ON;
    EXEC ops.usp_AssertScreen 'ADMIN_AUDIT';
    SELECT RequestNumber, StatusCode, Priority, AssignedCrewId, CostAmount, ErpDocumentNo, ValidFrom, ValidTo
    FROM core.ServiceRequest FOR SYSTEM_TIME ALL
    WHERE RequestId = @RequestId
    ORDER BY ValidFrom;
END
GO

CREATE OR ALTER PROCEDURE app.usp_Integration_Status
AS
BEGIN
    SET NOCOUNT ON;
    EXEC ops.usp_AssertScreen 'ADMIN_INTEGRATION';

    SELECT
        SUM(CASE WHEN ErpPostedAtUtc IS NULL AND ErpAttempts < 5  THEN 1 ELSE 0 END) AS Pending,
        SUM(CASE WHEN ErpPostedAtUtc IS NULL AND ErpAttempts >= 5 THEN 1 ELSE 0 END) AS FailedPermanently,
        SUM(CASE WHEN ErpPostedAtUtc >= DATEADD(hour, -24, SYSUTCDATETIME()) THEN 1 ELSE 0 END) AS PostedLast24h
    FROM core.ServiceRequest
    WHERE StatusCode = 'CLOSED' AND CostAmount IS NOT NULL;

    SELECT TOP (50) l.LogId, l.RequestId, r.RequestNumber, l.AttemptNo, l.Succeeded, l.ErrorMessage, l.DurationMs,
           l.LoggedAtUtc, CAST(l.RequestPayload AS nvarchar(max)) AS RequestXml, CAST(l.ResponsePayload AS nvarchar(max)) AS ResponseXml
    FROM integ.ErpPostingLog l
    JOIN core.ServiceRequest r ON r.RequestId = l.RequestId
    ORDER BY l.LoggedAtUtc DESC, l.LogId DESC;
END
GO

CREATE OR ALTER PROCEDURE app.usp_Integration_Retry
    @RequestId int
AS
BEGIN
    SET NOCOUNT ON;
    EXEC ops.usp_AssertScreen 'ADMIN_INTEGRATION';
    UPDATE core.ServiceRequest SET ErpAttempts = 0
    WHERE RequestId = @RequestId AND ErpPostedAtUtc IS NULL;
    IF @@ROWCOUNT = 0 THROW 50002, 'Nothing to retry for that request.', 1;
END
GO
