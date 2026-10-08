/* =====================================================================
   V002 - Reference data: roles, screens, workflow, org hierarchy,
          municipalities, categories, permit fees, business calendar.
   ===================================================================== */
SET XACT_ABORT ON;
SET NOCOUNT ON;
GO

/* ---------- Roles & screens ---------- */
INSERT sec.Role (RoleCode, DisplayName) VALUES
 ('RESIDENT',   N'Resident'),
 ('CLERK',      N'Customer Service Clerk'),
 ('SUPERVISOR', N'Department Supervisor'),
 ('ADMIN',      N'Application Administrator');

INSERT sec.Screen (ScreenCode, DisplayName) VALUES
 ('DASHBOARD',         N'Dashboard'),
 ('REQUEST_SUBMIT',    N'Submit service request'),
 ('REQUEST_MY',        N'My requests'),
 ('REQUEST_QUEUE',     N'Request queue'),
 ('REQUEST_DETAIL',    N'Request details & workflow'),
 ('RESIDENT_CONTACT',  N'Reveal resident contact info'),
 ('PERMIT_SUBMIT',     N'Apply for a permit'),
 ('PERMIT_QUEUE',      N'Permit review queue'),
 ('REPORTS',           N'Reports & exports'),
 ('ADMIN_USERS',       N'User administration'),
 ('ADMIN_SCREENS',     N'Screen permissions'),
 ('ADMIN_AUDIT',       N'Privacy access audit'),
 ('ADMIN_ERRORS',      N'Error log'),
 ('ADMIN_INTEGRATION', N'ERP integration monitor');

INSERT sec.RoleScreen (RoleCode, ScreenCode) VALUES
 ('RESIDENT','REQUEST_SUBMIT'), ('RESIDENT','REQUEST_MY'), ('RESIDENT','PERMIT_SUBMIT'),
 ('CLERK','DASHBOARD'), ('CLERK','REQUEST_SUBMIT'), ('CLERK','REQUEST_QUEUE'), ('CLERK','REQUEST_DETAIL'), ('CLERK','PERMIT_QUEUE'),
 ('SUPERVISOR','DASHBOARD'), ('SUPERVISOR','REQUEST_QUEUE'), ('SUPERVISOR','REQUEST_DETAIL'),
 ('SUPERVISOR','RESIDENT_CONTACT'), ('SUPERVISOR','PERMIT_QUEUE'), ('SUPERVISOR','REPORTS');

INSERT sec.RoleScreen (RoleCode, ScreenCode)
SELECT 'ADMIN', ScreenCode FROM sec.Screen WHERE ScreenCode NOT IN ('REQUEST_MY','PERMIT_SUBMIT');
GO

/* ---------- Workflow ---------- */
INSERT core.RequestStatus (StatusCode, DisplayName, SortOrder, IsTerminal) VALUES
 ('SUBMITTED',   N'Submitted',   1, 0),
 ('TRIAGED',     N'Triaged',     2, 0),
 ('ASSIGNED',    N'Assigned',    3, 0),
 ('IN_PROGRESS', N'In progress', 4, 0),
 ('ON_HOLD',     N'On hold',     5, 0),
 ('CLOSED',      N'Closed',      6, 1),
 ('CANCELLED',   N'Cancelled',   7, 1);

INSERT core.StatusTransition (FromStatus, ToStatus, RoleCode)
SELECT t.FromStatus, t.ToStatus, r.RoleCode
FROM (VALUES
    ('SUBMITTED',  'TRIAGED',     'CLERK,SUPERVISOR,ADMIN'),
    ('SUBMITTED',  'CANCELLED',   'RESIDENT,CLERK,SUPERVISOR,ADMIN'),
    ('TRIAGED',    'ASSIGNED',    'SUPERVISOR,ADMIN'),
    ('TRIAGED',    'CANCELLED',   'SUPERVISOR,ADMIN'),
    ('ASSIGNED',   'IN_PROGRESS', 'SUPERVISOR,ADMIN'),
    ('IN_PROGRESS','ON_HOLD',     'SUPERVISOR,ADMIN'),
    ('ON_HOLD',    'IN_PROGRESS', 'SUPERVISOR,ADMIN'),
    ('IN_PROGRESS','CLOSED',      'SUPERVISOR,ADMIN'),
    ('CLOSED',     'IN_PROGRESS', 'ADMIN')            -- re-open is an admin-only correction
) AS t (FromStatus, ToStatus, Roles)
CROSS APPLY STRING_SPLIT(t.Roles, ',') s
JOIN sec.Role r ON r.RoleCode = s.value;
GO

/* ---------- Organisation hierarchy (hierarchyid) ---------- */
INSERT core.Department (OrgNode, Code, Name, CostCentre) VALUES
 (hierarchyid::Parse('/'),       'COUNTY',   N'Public Services (demo)',         NULL),
 (hierarchyid::Parse('/1/'),     'TRANS',    N'Transportation & Engineering',    'CC-4000'),
 (hierarchyid::Parse('/1/1/'),   'ROADS',    N'Roads Operations',                'CC-4100'),
 (hierarchyid::Parse('/1/2/'),   'TRAFFIC',  N'Traffic & Signals',               'CC-4200'),
 (hierarchyid::Parse('/2/'),     'ENV',      N'Environmental Services',          'CC-5000'),
 (hierarchyid::Parse('/2/1/'),   'WASTE',    N'Waste Collection',                'CC-5100'),
 (hierarchyid::Parse('/3/'),     'PLAN',     N'Planning & Development',          'CC-6000'),
 (hierarchyid::Parse('/3/1/'),   'BUILDING', N'Building Services',               'CC-6100'),
 (hierarchyid::Parse('/3/2/'),   'BYLAW',    N'By-law Enforcement',              'CC-6200'),
 (hierarchyid::Parse('/4/'),     'IT',       N'Information Technology',          'CC-9000');

INSERT core.Crew (DepartmentId, Name)
SELECT d.DepartmentId, c.Name
FROM (VALUES ('ROADS', N'North Patrol Crew'), ('ROADS', N'South Patrol Crew'), ('ROADS', N'Winter Control'),
             ('TRAFFIC', N'Signals Technicians'), ('TRAFFIC', N'Sign Shop'),
             ('WASTE', N'Collection Contractor A'), ('WASTE', N'Collection Contractor B'),
             ('BYLAW', N'By-law Officers – North'), ('BYLAW', N'By-law Officers – South')) c (DeptCode, Name)
JOIN core.Department d ON d.Code = c.DeptCode;
GO

/* ---------- Member municipalities ---------- */
INSERT core.Municipality (MunicipalityId, Name) VALUES
 (1, N'Adjala-Tosorontio'), (2, N'Bradford West Gwillimbury'), (3, N'Clearview'), (4, N'Collingwood'),
 (5, N'Essa'), (6, N'Innisfil'), (7, N'Midland'), (8, N'New Tecumseth'), (9, N'Oro-Medonte'),
 (10, N'Penetanguishene'), (11, N'Ramara'), (12, N'Severn'), (13, N'Springwater'), (14, N'Tay'),
 (15, N'Tiny'), (16, N'Wasaga Beach');
GO

/* ---------- Request category tree ---------- */
INSERT core.RequestCategory (ParentCategoryId, Name) VALUES
 (NULL, N'Roads'), (NULL, N'Traffic'), (NULL, N'Waste'), (NULL, N'By-law');

INSERT core.RequestCategory (ParentCategoryId, Name, DepartmentId, SlaBusinessDays, DefaultPriority)
SELECT p.CategoryId, c.Name, d.DepartmentId, c.Sla, c.Pri
FROM (VALUES
    (N'Roads',   N'Pothole',                   'ROADS',   5,  3),
    (N'Roads',   N'Debris on road',            'ROADS',   1,  2),
    (N'Roads',   N'Missed snow plowing',       'ROADS',   1,  2),
    (N'Roads',   N'Shoulder / ditch damage',   'ROADS',   10, 4),
    (N'Traffic', N'Signal malfunction',        'TRAFFIC', 1,  1),
    (N'Traffic', N'Damaged or missing sign',   'TRAFFIC', 3,  2),
    (N'Traffic', N'Streetlight out',           'TRAFFIC', 10, 4),
    (N'Waste',   N'Missed garbage collection', 'WASTE',   2,  3),
    (N'Waste',   N'Damaged green bin',         'WASTE',   10, 4),
    (N'Waste',   N'Illegal dumping',           'WASTE',   5,  3),
    (N'By-law',  N'Noise complaint',           'BYLAW',   10, 4),
    (N'By-law',  N'Property standards',        'BYLAW',   15, 4),
    (N'By-law',  N'Parking complaint',         'BYLAW',   3,  3)
) c (Parent, Name, DeptCode, Sla, Pri)
JOIN core.RequestCategory p ON p.Name = c.Parent AND p.ParentCategoryId IS NULL
JOIN core.Department d ON d.Code = c.DeptCode;
GO

/* ---------- Permit fee schedule (illustrative, not any real municipality's fees) ---------- */
INSERT core.PermitType (PermitTypeCode, DisplayName, BaseFee, RatePerThousand, MinFee, MaxFee, DepartmentId)
SELECT v.Code, v.Name, v.BaseFee, v.Rate, v.MinFee, v.MaxFee, d.DepartmentId
FROM (VALUES
    ('BUILD_RES', N'Building – residential',  150.00,  9.50, 200.00, NULL),
    ('BUILD_COM', N'Building – commercial',   400.00, 14.00, 500.00, NULL),
    ('DEMOLITION',N'Demolition',              250.00,  0.00, 250.00, 250.00),
    ('POOL',      N'Pool enclosure',          200.00,  0.00, 200.00, 200.00),
    ('SIGN',      N'Sign',                    100.00,  2.00, 100.00, 750.00)
) v (Code, Name, BaseFee, Rate, MinFee, MaxFee)
CROSS JOIN core.Department d WHERE d.Code = 'BUILDING';
GO

/* ---------- Business calendar 2020-2035 with Ontario statutory holidays ---------- */
;WITH n AS (
    SELECT TOP (DATEDIFF(day, '2020-01-01', '2035-12-31') + 1)
           ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) - 1 AS i
    FROM sys.all_objects a CROSS JOIN sys.all_objects b
)
INSERT core.Calendar (CalendarDate, IsBusinessDay, BusinessDaySeq)
SELECT DATEADD(day, i, '2020-01-01'),
       -- 1900-01-01 was a Monday, so (days since then % 7) gives 0=Mon..6=Sun independent of SET DATEFIRST.
       CASE WHEN DATEDIFF(day, '19000101', DATEADD(day, i, '2020-01-01')) % 7 IN (5, 6) THEN 0 ELSE 1 END,
       0
FROM n;

-- Fixed and "nth Monday" holidays.
UPDATE c SET HolidayName = h.Name
FROM core.Calendar c
CROSS APPLY (SELECT MONTH(c.CalendarDate) AS M, DAY(c.CalendarDate) AS D,
                    DATEDIFF(day, '19000101', c.CalendarDate) % 7 AS Dow) x
CROSS APPLY (SELECT CASE
        WHEN x.M = 1  AND x.D = 1                          THEN N'New Year''s Day'
        WHEN x.M = 2  AND x.Dow = 0 AND x.D BETWEEN 15 AND 21 THEN N'Family Day'
        WHEN x.M = 5  AND x.Dow = 0 AND x.D BETWEEN 18 AND 24 THEN N'Victoria Day'
        WHEN x.M = 7  AND x.D = 1                          THEN N'Canada Day'
        WHEN x.M = 8  AND x.Dow = 0 AND x.D BETWEEN 1 AND 7   THEN N'Civic Holiday'
        WHEN x.M = 9  AND x.Dow = 0 AND x.D BETWEEN 1 AND 7   THEN N'Labour Day'
        WHEN x.M = 10 AND x.Dow = 0 AND x.D BETWEEN 8 AND 14  THEN N'Thanksgiving'
        WHEN x.M = 12 AND x.D = 25                         THEN N'Christmas Day'
        WHEN x.M = 12 AND x.D = 26                         THEN N'Boxing Day'
    END AS Name) h
WHERE h.Name IS NOT NULL;

-- Good Friday = Easter Sunday - 2 (Anonymous Gregorian computus).
;WITH y AS (SELECT DISTINCT YEAR(CalendarDate) AS Y FROM core.Calendar),
e AS (
    SELECT Y, a = Y % 19, b = Y / 100, c = Y % 100 FROM y
), e2 AS (
    SELECT Y, a, b, c, d = b / 4, ee = b % 4, f = (b + 8) / 25, i = c / 4, k = c % 4 FROM e
), e3 AS (
    SELECT Y, a, k, i, ee, h = (19 * a + b - d - (b - f + 1) / 3 + 15) % 30 FROM e2
), e4 AS (
    SELECT Y, a, h, l = (32 + 2 * ee + 2 * i - h - k) % 7 FROM e3
), e5 AS (
    SELECT Y, h, l, m = (a + 11 * h + 22 * l) / 451 FROM e4
)
UPDATE c SET HolidayName = N'Good Friday'
FROM core.Calendar c
JOIN e5 ON c.CalendarDate = DATEADD(day, -2,
          DATEFROMPARTS(e5.Y, (h + l - 7 * m + 114) / 31, ((h + l - 7 * m + 114) % 31) + 1));

-- Weekend holidays are observed on the next business day (simplified rule).
UPDATE c SET HolidayName = CONCAT(w.HolidayName, N' (observed)')
FROM core.Calendar w
CROSS APPLY (SELECT MIN(c2.CalendarDate) AS NextDay FROM core.Calendar c2
             WHERE c2.CalendarDate > w.CalendarDate AND c2.IsBusinessDay = 1 AND c2.HolidayName IS NULL) nx
JOIN core.Calendar c ON c.CalendarDate = nx.NextDay
WHERE w.HolidayName IS NOT NULL AND w.IsBusinessDay = 0;

UPDATE core.Calendar SET IsBusinessDay = 0 WHERE HolidayName IS NOT NULL;

-- Running count of business days.
;WITH s AS (
    SELECT CalendarDate, SUM(CAST(IsBusinessDay AS int)) OVER (ORDER BY CalendarDate ROWS UNBOUNDED PRECEDING) AS Seq
    FROM core.Calendar
)
UPDATE c SET BusinessDaySeq = s.Seq
FROM core.Calendar c JOIN s ON s.CalendarDate = c.CalendarDate;

-- Created only now: until the running sequence is filled in, every row has BusinessDaySeq = 0.
CREATE UNIQUE INDEX UX_Calendar_BusinessDaySeq ON core.Calendar (BusinessDaySeq) INCLUDE (CalendarDate) WHERE IsBusinessDay = 1;
GO
