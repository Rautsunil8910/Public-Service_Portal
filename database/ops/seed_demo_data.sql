/* =====================================================================
   Demo data generator - realistic volume for performance work.
   Usage: sqlcmd ... -d PublicServicePortal -i seed_demo_data.sql -v RequestCount=500000
   Set-based (no loops): 500,000 requests load in well under a few minutes on a laptop.
   All names, emails and phone numbers are fictitious (example.com / 555 numbers).
   Demo LOGIN accounts are created by the web app on first start (passwords must be hashed by the app).
   ===================================================================== */
SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @RequestCount  int = $(RequestCount);
DECLARE @ResidentCount int = CASE WHEN @RequestCount / 10 < 500 THEN 500 WHEN @RequestCount / 10 > 50000 THEN 50000 ELSE @RequestCount / 10 END;
DECLARE @PermitCount   int = CASE WHEN @RequestCount / 25 < 200 THEN 200 ELSE @RequestCount / 25 END;
DECLARE @Max int = (SELECT MAX(v) FROM (VALUES (@RequestCount), (@ResidentCount), (@PermitCount)) x(v));
DECLARE @Now datetime2(0) = SYSUTCDATETIME();

PRINT CONCAT('Seeding ', @ResidentCount, ' residents, ', @RequestCount, ' requests, ', @PermitCount, ' permits...');

DROP TABLE IF EXISTS #n, #r, #cat, #crew;

SELECT TOP (@Max) CAST(ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS int) AS n
INTO #n
FROM sys.all_objects a CROSS JOIN sys.all_objects b CROSS JOIN sys.all_objects c;

/* ---------- Residents ---------- */
INSERT core.Resident (FirstName, LastName, Email, Phone, StreetAddress, MunicipalityId)
SELECT CHOOSE(n % 20 + 1, N'Liam', N'Olivia', N'Noah', N'Emma', N'Ethan', N'Charlotte', N'Lucas', N'Amelia', N'Mason', N'Ava',
                          N'Logan', N'Sophia', N'Benjamin', N'Chloe', N'Jacob', N'Maya', N'Arjun', N'Priya', N'Wei', N'Fatima'),
       CHOOSE((n / 20) % 20 + 1, N'Smith', N'Brown', N'Tremblay', N'Martin', N'Roy', N'Wilson', N'MacDonald', N'Gagnon', N'Taylor', N'Campbell',
                          N'Anderson', N'Patel', N'Singh', N'Nguyen', N'Chen', N'Leblanc', N'Thompson', N'White', N'Ahmed', N'Kaur'),
       CONCAT('resident', n, '@example.com'),
       CONCAT('705-555-', RIGHT(CONCAT('0000', n % 10000), 4)),
       CONCAT(n % 900 + 1, N' ', CHOOSE(n % 10 + 1, N'Bayfield St', N'Penetanguishene Rd', N'Yonge St', N'Mill St', N'Queen St',
                                                    N'Line 4 N', N'Concession 7', N'County Rd 90', N'Hurontario St', N'King St')),
       CAST(n % 16 + 1 AS tinyint)
FROM #n WHERE n <= @ResidentCount;

DECLARE @FirstResident int = (SELECT MIN(ResidentId) FROM core.Resident);
DECLARE @ResidentTotal int = (SELECT COUNT(*) FROM core.Resident);

/* ---------- Random numbers, materialised once so each row's values are stable ---------- */
SELECT n,
       ABS(CHECKSUM(NEWID())) AS r1, ABS(CHECKSUM(NEWID())) AS r2, ABS(CHECKSUM(NEWID())) AS r3,
       ABS(CHECKSUM(NEWID())) AS r4, ABS(CHECKSUM(NEWID())) AS r5
INTO #r
FROM #n WHERE n <= @RequestCount;

SELECT CategoryId, DepartmentId, SlaBusinessDays, DefaultPriority, Name,
       ROW_NUMBER() OVER (ORDER BY CategoryId) - 1 AS idx
INTO #cat
FROM core.RequestCategory WHERE DepartmentId IS NOT NULL AND IsActive = 1;
DECLARE @CatCount int = (SELECT COUNT(*) FROM #cat);

SELECT CrewId, DepartmentId,
       ROW_NUMBER() OVER (PARTITION BY DepartmentId ORDER BY CrewId) - 1 AS idx,
       COUNT(*) OVER (PARTITION BY DepartmentId) AS cnt
INTO #crew
FROM core.Crew;

/* ---------- Service requests (2 years of history) ---------- */
INSERT core.ServiceRequest (CategoryId, DepartmentId, MunicipalityId, ResidentId, Channel, Priority, StatusCode,
                            Description, LocationText, AssignedCrewId, SubmittedAtUtc, DueDate, ClosedAtUtc, Resolution,
                            CostAmount, CostCentre, ErpAttempts, ErpPostedAtUtc, ErpDocumentNo)
SELECT c.CategoryId, c.DepartmentId, m.MunicipalityId,
       CASE WHEN r.r4 % 10 < 7 THEN @FirstResident + r.r4 % @ResidentTotal END,
       CASE WHEN r.r5 % 10 < 6 THEN 'WEB' WHEN r.r5 % 10 < 9 THEN 'PHONE' ELSE 'EMAIL' END,
       c.DefaultPriority,
       st.StatusCode,
       CONCAT(c.Name, N' reported near ', loc.Street, N'. Caller says the problem has been there for a few days.'),
       CONCAT(loc.HouseNo, N' ', loc.Street, N', ', m.Name),
       CASE WHEN st.StatusCode IN ('ASSIGNED','IN_PROGRESS','ON_HOLD','CLOSED') THEN cr.CrewId END,
       a.SubmittedAtUtc,
       due.CalendarDate,
       CASE WHEN st.StatusCode IN ('CLOSED','CANCELLED') THEN cc.CandidateClose END,
       CASE st.StatusCode WHEN 'CLOSED' THEN N'Work completed by crew; site inspected.'
                          WHEN 'CANCELLED' THEN N'Duplicate of an existing request.' END,
       cost.Amount,
       CASE WHEN cost.Amount IS NOT NULL THEN d.CostCentre END,
       CASE WHEN erp.Posted = 1 THEN 1 ELSE 0 END,
       CASE WHEN erp.Posted = 1 THEN DATEADD(hour, 26, cc.CandidateClose) END,
       CASE WHEN erp.Posted = 1 THEN CONCAT('FI-SEED-', r.n) END
FROM #r r
JOIN #cat c              ON c.idx = r.r1 % @CatCount
JOIN core.Department d   ON d.DepartmentId = c.DepartmentId
JOIN core.Municipality m ON m.MunicipalityId = r.r3 % 16 + 1
CROSS APPLY (SELECT DATEADD(second, -CAST(r.r2 % 63072000 AS int), @Now) AS SubmittedAtUtc) a          -- up to 2 years ago
CROSS APPLY (SELECT CAST(a.SubmittedAtUtc AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS date) AS SubmittedLocal) l
JOIN core.Calendar cs    ON cs.CalendarDate = l.SubmittedLocal
JOIN core.Calendar due   ON due.BusinessDaySeq = cs.BusinessDaySeq + c.SlaBusinessDays AND due.IsBusinessDay = 1
-- Close time: between 2 hours and ~(2*SLA + 3) days, so roughly 60-70% of requests meet SLA.
CROSS APPLY (SELECT DATEADD(hour, CAST(r.r3 / 16 % ((c.SlaBusinessDays * 2 + 3) * 24) + 2 AS int), a.SubmittedAtUtc) AS CandidateClose) cc
CROSS APPLY (SELECT CASE
                 WHEN cc.CandidateClose <= @Now AND (r.r4 % 100 < 85 OR a.SubmittedAtUtc < DATEADD(day, -45, @Now))
                     THEN CASE WHEN r.r5 % 100 < 3 THEN 'CANCELLED' ELSE 'CLOSED' END
                 ELSE CHOOSE(r.r5 % 5 + 1, 'SUBMITTED', 'TRIAGED', 'ASSIGNED', 'IN_PROGRESS', 'ON_HOLD')
             END AS StatusCode) st
CROSS APPLY (SELECT r.r4 % 2000 + 1 AS HouseNo,
                    CHOOSE(r.r2 % 10 + 1, N'Bayfield St', N'Penetanguishene Rd', N'Yonge St', N'Mill St', N'Queen St',
                                          N'Line 4 N', N'Concession 7', N'County Rd 90', N'Hurontario St', N'King St') AS Street) loc
CROSS APPLY (SELECT CASE WHEN st.StatusCode = 'CLOSED' AND r.r1 % 10 < 4
                         THEN CAST(50 + (r.r1 / 10 % 500000) / 100.0 AS decimal(12,2)) END AS Amount) cost
CROSS APPLY (SELECT CASE WHEN cost.Amount IS NOT NULL AND cc.CandidateClose < DATEADD(day, -3, @Now) THEN 1 ELSE 0 END AS Posted) erp
LEFT JOIN #crew cr       ON cr.DepartmentId = c.DepartmentId AND cr.idx = r.r5 % cr.cnt;

PRINT CONCAT('Requests inserted: ', @@ROWCOUNT);

/* ---------- Timeline events ---------- */
INSERT core.ServiceRequestEvent (RequestId, FromStatus, ToStatus, ChangedByUserId, ChangedAtUtc, Note)
SELECT RequestId, NULL, 'SUBMITTED', NULL, SubmittedAtUtc, CONCAT(N'Submitted via ', Channel)
FROM core.ServiceRequest;

INSERT core.ServiceRequestEvent (RequestId, FromStatus, ToStatus, ChangedByUserId, ChangedAtUtc, Note)
SELECT RequestId, 'SUBMITTED', StatusCode, NULL, COALESCE(ClosedAtUtc, DATEADD(hour, 4, SubmittedAtUtc)), N'Seeded status'
FROM core.ServiceRequest
WHERE StatusCode <> 'SUBMITTED';

/* ---------- Permits ---------- */
INSERT core.Permit (PermitTypeCode, ResidentId, PropertyAddress, WorkDescription, ProjectValue, Fee,
                    StatusCode, SubmittedAtUtc, DecidedAtUtc, DecisionNote)
SELECT pt.PermitTypeCode,
       @FirstResident + x.r1 % @ResidentTotal,
       CONCAT(x.r1 % 900 + 1, N' Main St'),
       CHOOSE(x.r2 % 5 + 1, N'Single-storey rear addition', N'Detached garage', N'New deck and stairs',
                            N'Interior renovation, structural wall removal', N'New single detached dwelling'),
       v.ProjectValue, f.Fee,
       s.StatusCode, sub.SubmittedAtUtc,
       CASE WHEN s.StatusCode IN ('APPROVED','REJECTED') THEN DATEADD(day, 5 + x.r3 % 20, sub.SubmittedAtUtc) END,
       CASE WHEN s.StatusCode = 'REJECTED' THEN N'Drawings incomplete; resubmit with site plan.' END
FROM (SELECT n, ABS(CHECKSUM(NEWID())) AS r1, ABS(CHECKSUM(NEWID())) AS r2, ABS(CHECKSUM(NEWID())) AS r3
      FROM #n WHERE n <= @PermitCount) x
CROSS APPLY (SELECT CHOOSE(x.r2 % 10 + 1, 'BUILD_RES','BUILD_RES','BUILD_RES','BUILD_RES','BUILD_COM',
                                          'DEMOLITION','POOL','POOL','SIGN','BUILD_RES') AS PermitTypeCode) pt
CROSS APPLY (SELECT CAST(5000 + x.r3 % 750000 AS decimal(14,2)) AS ProjectValue) v
CROSS APPLY core.fn_PermitFee(pt.PermitTypeCode, v.ProjectValue) f
CROSS APPLY (SELECT DATEADD(minute, -CAST(x.r1 % 1051200 AS int), @Now) AS SubmittedAtUtc) sub
CROSS APPLY (SELECT CASE WHEN sub.SubmittedAtUtc > DATEADD(day, -7, @Now) THEN 'SUBMITTED'
                         WHEN sub.SubmittedAtUtc > DATEADD(day, -20, @Now) THEN 'UNDER_REVIEW'
                         WHEN x.r2 % 10 = 0 THEN 'REJECTED'
                         ELSE 'APPROVED' END AS StatusCode) s;

PRINT CONCAT('Permits inserted: ', @@ROWCOUNT);

UPDATE STATISTICS core.ServiceRequest WITH FULLSCAN;
DROP TABLE IF EXISTS #n, #r, #cat, #crew;
PRINT 'Seed complete. Run: EXEC ops.usp_Warehouse_Load;';
