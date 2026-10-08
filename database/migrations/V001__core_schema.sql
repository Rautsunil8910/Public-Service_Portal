/* =====================================================================
   V001 - Core schema
   Public Service Portal: service requests, permits, security, audit.
   Versioned migration: runs once per environment (tracked in ops.SchemaVersion).
   ===================================================================== */
SET XACT_ABORT ON;
GO

-- Schemas separate concerns and are the unit of permission (see V003).
IF SCHEMA_ID('core')  IS NULL EXEC('CREATE SCHEMA core');   -- operational data
IF SCHEMA_ID('sec')   IS NULL EXEC('CREATE SCHEMA sec');    -- users, roles, screen permissions, RLS
IF SCHEMA_ID('app')   IS NULL EXEC('CREATE SCHEMA app');    -- stored procedures the web app may call
IF SCHEMA_ID('integ') IS NULL EXEC('CREATE SCHEMA integ');  -- ERP integration procedures + logs
IF SCHEMA_ID('rpt')   IS NULL EXEC('CREATE SCHEMA rpt');    -- reporting star schema (BI)
IF SCHEMA_ID('audit') IS NULL EXEC('CREATE SCHEMA audit');  -- temporal history + MFIPPA access log
GO

/* ---------- Security reference ---------- */
CREATE TABLE sec.Role (
    RoleCode     varchar(20)   NOT NULL CONSTRAINT PK_Role PRIMARY KEY,
    DisplayName  nvarchar(60)  NOT NULL
);

CREATE TABLE sec.Screen (
    ScreenCode   varchar(40)   NOT NULL CONSTRAINT PK_Screen PRIMARY KEY,
    DisplayName  nvarchar(80)  NOT NULL
);

-- Screen-level security is data-driven: admins change it without a code deploy.
CREATE TABLE sec.RoleScreen (
    RoleCode     varchar(20)   NOT NULL CONSTRAINT FK_RoleScreen_Role   REFERENCES sec.Role(RoleCode),
    ScreenCode   varchar(40)   NOT NULL CONSTRAINT FK_RoleScreen_Screen REFERENCES sec.Screen(ScreenCode),
    CONSTRAINT PK_RoleScreen PRIMARY KEY (RoleCode, ScreenCode)
);
GO

/* ---------- Organisation (hierarchical) ---------- */
CREATE TABLE core.Department (
    DepartmentId  int IDENTITY(1,1) NOT NULL CONSTRAINT PK_Department PRIMARY KEY,
    OrgNode       hierarchyid   NOT NULL CONSTRAINT UQ_Department_OrgNode UNIQUE,
    OrgLevel      AS OrgNode.GetLevel() PERSISTED,
    Code          varchar(20)   NOT NULL CONSTRAINT UQ_Department_Code UNIQUE,
    Name          nvarchar(100) NOT NULL,
    CostCentre    varchar(20)   NULL,
    IsActive      bit           NOT NULL CONSTRAINT DF_Department_IsActive DEFAULT (1)
);
-- Breadth-first index supports "all children of X" queries.
CREATE INDEX IX_Department_Breadth ON core.Department (OrgLevel, OrgNode);

CREATE TABLE core.Crew (
    CrewId        int IDENTITY(1,1) NOT NULL CONSTRAINT PK_Crew PRIMARY KEY,
    DepartmentId  int           NOT NULL CONSTRAINT FK_Crew_Department REFERENCES core.Department(DepartmentId),
    Name          nvarchar(80)  NOT NULL,
    IsActive      bit           NOT NULL CONSTRAINT DF_Crew_IsActive DEFAULT (1)
);

CREATE TABLE core.Municipality (
    MunicipalityId tinyint      NOT NULL CONSTRAINT PK_Municipality PRIMARY KEY,
    Name           nvarchar(60) NOT NULL CONSTRAINT UQ_Municipality_Name UNIQUE
);
GO

/* ---------- Business-day calendar (SLA maths) ---------- */
-- BusinessDaySeq is a running count of business days, so
-- "business days between A and B" = seq(B) - seq(A): O(1), no loops.
CREATE TABLE core.Calendar (
    CalendarDate    date         NOT NULL CONSTRAINT PK_Calendar PRIMARY KEY,
    IsBusinessDay   bit          NOT NULL,
    BusinessDaySeq  int          NOT NULL,
    HolidayName     nvarchar(60) NULL
);
-- UX_Calendar_BusinessDaySeq is created in V002 after the sequence is calculated.
GO

/* ---------- Service request reference ---------- */
CREATE TABLE core.RequestCategory (
    CategoryId        int IDENTITY(1,1) NOT NULL CONSTRAINT PK_RequestCategory PRIMARY KEY,
    ParentCategoryId  int           NULL CONSTRAINT FK_RequestCategory_Parent REFERENCES core.RequestCategory(CategoryId),
    Name              nvarchar(80)  NOT NULL,
    DepartmentId      int           NULL CONSTRAINT FK_RequestCategory_Department REFERENCES core.Department(DepartmentId),
    SlaBusinessDays   tinyint       NULL,
    DefaultPriority   tinyint       NOT NULL CONSTRAINT DF_RequestCategory_Priority DEFAULT (3),
    IsActive          bit           NOT NULL CONSTRAINT DF_RequestCategory_IsActive DEFAULT (1),
    -- Leaf categories (the ones residents pick) must route to a department with an SLA.
    CONSTRAINT CK_RequestCategory_LeafRouting CHECK (
        (DepartmentId IS NULL AND SlaBusinessDays IS NULL) OR
        (DepartmentId IS NOT NULL AND SlaBusinessDays IS NOT NULL))
);

CREATE TABLE core.RequestStatus (
    StatusCode   varchar(20)  NOT NULL CONSTRAINT PK_RequestStatus PRIMARY KEY,
    DisplayName  nvarchar(40) NOT NULL,
    SortOrder    tinyint      NOT NULL,
    IsTerminal   bit          NOT NULL
);

-- The workflow lives in data: which role may move a request from which status to which.
CREATE TABLE core.StatusTransition (
    FromStatus  varchar(20) NOT NULL CONSTRAINT FK_StatusTransition_From REFERENCES core.RequestStatus(StatusCode),
    ToStatus    varchar(20) NOT NULL CONSTRAINT FK_StatusTransition_To   REFERENCES core.RequestStatus(StatusCode),
    RoleCode    varchar(20) NOT NULL CONSTRAINT FK_StatusTransition_Role REFERENCES sec.Role(RoleCode),
    CONSTRAINT PK_StatusTransition PRIMARY KEY (FromStatus, ToStatus, RoleCode)
);
GO

/* ---------- Residents (personal information: masked + versioned) ---------- */
CREATE TABLE core.Resident (
    ResidentId     int IDENTITY(1,1) NOT NULL CONSTRAINT PK_Resident PRIMARY KEY,
    FirstName      nvarchar(60)  NOT NULL,
    LastName       nvarchar(60)  NOT NULL,
    Email          nvarchar(254) NULL,
    Phone          varchar(25)   NULL,
    StreetAddress  nvarchar(200) NULL,
    MunicipalityId tinyint       NULL CONSTRAINT FK_Resident_Municipality REFERENCES core.Municipality(MunicipalityId),
    CreatedAtUtc   datetime2(0)  NOT NULL CONSTRAINT DF_Resident_CreatedAt DEFAULT (SYSUTCDATETIME()),
    ValidFrom      datetime2(3)  GENERATED ALWAYS AS ROW START HIDDEN NOT NULL,
    ValidTo        datetime2(3)  GENERATED ALWAYS AS ROW END   HIDDEN NOT NULL,
    PERIOD FOR SYSTEM_TIME (ValidFrom, ValidTo)
) WITH (SYSTEM_VERSIONING = ON (HISTORY_TABLE = audit.ResidentHistory));
CREATE UNIQUE INDEX UX_Resident_Email ON core.Resident (Email) WHERE Email IS NOT NULL;
GO

/* ---------- Application users ---------- */
CREATE TABLE sec.AppUser (
    UserId             int IDENTITY(1,1) NOT NULL CONSTRAINT PK_AppUser PRIMARY KEY,
    UserName           nvarchar(100) NOT NULL CONSTRAINT UQ_AppUser_UserName UNIQUE,
    DisplayName        nvarchar(100) NOT NULL,
    PasswordHash       varchar(200)  NOT NULL,   -- ASP.NET Core Identity PBKDF2 hash; never plaintext
    RoleCode           varchar(20)   NOT NULL CONSTRAINT FK_AppUser_Role REFERENCES sec.Role(RoleCode),
    DepartmentId       int           NULL CONSTRAINT FK_AppUser_Department REFERENCES core.Department(DepartmentId),
    ResidentId         int           NULL CONSTRAINT FK_AppUser_Resident   REFERENCES core.Resident(ResidentId),
    IsActive           bit           NOT NULL CONSTRAINT DF_AppUser_IsActive DEFAULT (1),
    FailedLoginCount   tinyint       NOT NULL CONSTRAINT DF_AppUser_Failed DEFAULT (0),
    LockedUntilUtc     datetime2(0)  NULL,
    LastLoginUtc       datetime2(0)  NULL,
    PasswordChangedUtc datetime2(0)  NOT NULL CONSTRAINT DF_AppUser_PwdChanged DEFAULT (SYSUTCDATETIME()),
    CreatedAtUtc       datetime2(0)  NOT NULL CONSTRAINT DF_AppUser_CreatedAt DEFAULT (SYSUTCDATETIME()),
    CONSTRAINT CK_AppUser_SupervisorHasDept CHECK (RoleCode <> 'SUPERVISOR' OR DepartmentId IS NOT NULL),
    CONSTRAINT CK_AppUser_ResidentLinked    CHECK (RoleCode <> 'RESIDENT'   OR ResidentId   IS NOT NULL)
);
GO

/* ---------- Service requests ---------- */
CREATE TABLE core.ServiceRequest (
    RequestId       int IDENTITY(1,1) NOT NULL CONSTRAINT PK_ServiceRequest PRIMARY KEY,
    RequestNumber   AS ('SR-' + RIGHT('0000000' + CAST(RequestId AS varchar(10)), 7)) PERSISTED,
    CategoryId      int            NOT NULL CONSTRAINT FK_ServiceRequest_Category     REFERENCES core.RequestCategory(CategoryId),
    DepartmentId    int            NOT NULL CONSTRAINT FK_ServiceRequest_Department   REFERENCES core.Department(DepartmentId),
    MunicipalityId  tinyint        NOT NULL CONSTRAINT FK_ServiceRequest_Municipality REFERENCES core.Municipality(MunicipalityId),
    ResidentId      int            NULL     CONSTRAINT FK_ServiceRequest_Resident     REFERENCES core.Resident(ResidentId),
    Channel         varchar(10)    NOT NULL CONSTRAINT CK_ServiceRequest_Channel CHECK (Channel IN ('WEB','PHONE','EMAIL','COUNTER')),
    Priority        tinyint        NOT NULL CONSTRAINT CK_ServiceRequest_Priority CHECK (Priority BETWEEN 1 AND 4),
    StatusCode      varchar(20)    NOT NULL CONSTRAINT FK_ServiceRequest_Status REFERENCES core.RequestStatus(StatusCode)
                                            CONSTRAINT DF_ServiceRequest_Status DEFAULT ('SUBMITTED'),
    Description     nvarchar(2000) NOT NULL,
    LocationText    nvarchar(200)  NOT NULL,
    Latitude        decimal(9,6)   NULL,
    Longitude       decimal(9,6)   NULL,
    AssignedCrewId  int            NULL CONSTRAINT FK_ServiceRequest_Crew REFERENCES core.Crew(CrewId),
    SubmittedAtUtc  datetime2(0)   NOT NULL CONSTRAINT DF_ServiceRequest_Submitted DEFAULT (SYSUTCDATETIME()),
    DueDate         date           NOT NULL,
    ClosedAtUtc     datetime2(0)   NULL,
    Resolution      nvarchar(1000) NULL,
    CostAmount      decimal(12,2)  NULL CONSTRAINT CK_ServiceRequest_Cost CHECK (CostAmount >= 0),
    CostCentre      varchar(20)    NULL,
    ErpAttempts     tinyint        NOT NULL CONSTRAINT DF_ServiceRequest_ErpAttempts DEFAULT (0),
    ErpPostedAtUtc  datetime2(0)   NULL,
    ErpDocumentNo   varchar(30)    NULL,
    RowVer          rowversion     NOT NULL,       -- optimistic concurrency
    ValidFrom       datetime2(3)   GENERATED ALWAYS AS ROW START HIDDEN NOT NULL,
    ValidTo         datetime2(3)   GENERATED ALWAYS AS ROW END   HIDDEN NOT NULL,
    PERIOD FOR SYSTEM_TIME (ValidFrom, ValidTo),
    CONSTRAINT CK_ServiceRequest_ClosedHasResolution CHECK (ClosedAtUtc IS NULL OR Resolution IS NOT NULL)
) WITH (SYSTEM_VERSIONING = ON (HISTORY_TABLE = audit.ServiceRequestHistory));

CREATE INDEX IX_ServiceRequest_Status_Department ON core.ServiceRequest (StatusCode, DepartmentId) INCLUDE (DueDate, Priority, MunicipalityId);
CREATE INDEX IX_ServiceRequest_Resident          ON core.ServiceRequest (ResidentId) WHERE ResidentId IS NOT NULL;
CREATE INDEX IX_ServiceRequest_ErpPending        ON core.ServiceRequest (ClosedAtUtc) INCLUDE (CostAmount, ErpAttempts)
    WHERE ErpPostedAtUtc IS NULL AND CostAmount IS NOT NULL;
-- NOTE: the dashboard/SLA covering index is intentionally NOT created here.
-- database/ops/performance_tuning.sql walks through measuring the query first, then adding it.
GO

CREATE TABLE core.ServiceRequestEvent (
    EventId          bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_ServiceRequestEvent PRIMARY KEY,
    RequestId        int            NOT NULL CONSTRAINT FK_SREvent_Request REFERENCES core.ServiceRequest(RequestId),
    FromStatus       varchar(20)    NULL,
    ToStatus         varchar(20)    NOT NULL,
    ChangedByUserId  int            NULL CONSTRAINT FK_SREvent_User REFERENCES sec.AppUser(UserId),
    ChangedAtUtc     datetime2(0)   NOT NULL CONSTRAINT DF_SREvent_ChangedAt DEFAULT (SYSUTCDATETIME()),
    Note             nvarchar(1000) NULL
);
CREATE INDEX IX_ServiceRequestEvent_Request ON core.ServiceRequestEvent (RequestId, ChangedAtUtc);
GO

/* ---------- Permits ---------- */
CREATE TABLE core.PermitType (
    PermitTypeCode   varchar(20)   NOT NULL CONSTRAINT PK_PermitType PRIMARY KEY,
    DisplayName      nvarchar(80)  NOT NULL,
    BaseFee          decimal(10,2) NOT NULL,
    RatePerThousand  decimal(8,2)  NOT NULL,   -- fee per $1,000 of construction value
    MinFee           decimal(10,2) NOT NULL,
    MaxFee           decimal(10,2) NULL,
    DepartmentId     int           NOT NULL CONSTRAINT FK_PermitType_Department REFERENCES core.Department(DepartmentId)
);

CREATE TABLE core.Permit (
    PermitId         int IDENTITY(1,1) NOT NULL CONSTRAINT PK_Permit PRIMARY KEY,
    PermitNumber     AS ('BP-' + RIGHT('000000' + CAST(PermitId AS varchar(10)), 6)) PERSISTED,
    PermitTypeCode   varchar(20)    NOT NULL CONSTRAINT FK_Permit_Type REFERENCES core.PermitType(PermitTypeCode),
    ResidentId       int            NOT NULL CONSTRAINT FK_Permit_Resident REFERENCES core.Resident(ResidentId),
    PropertyAddress  nvarchar(200)  NOT NULL,
    WorkDescription  nvarchar(1000) NOT NULL,
    ProjectValue     decimal(14,2)  NOT NULL CONSTRAINT CK_Permit_ProjectValue CHECK (ProjectValue >= 0),
    Fee              decimal(10,2)  NOT NULL,
    StatusCode       varchar(20)    NOT NULL CONSTRAINT DF_Permit_Status DEFAULT ('SUBMITTED')
                                    CONSTRAINT CK_Permit_Status CHECK (StatusCode IN ('SUBMITTED','UNDER_REVIEW','APPROVED','REJECTED')),
    SubmittedAtUtc   datetime2(0)   NOT NULL CONSTRAINT DF_Permit_Submitted DEFAULT (SYSUTCDATETIME()),
    DecidedAtUtc     datetime2(0)   NULL,
    DecidedByUserId  int            NULL CONSTRAINT FK_Permit_DecidedBy REFERENCES sec.AppUser(UserId),
    DecisionNote     nvarchar(500)  NULL,
    RowVer           rowversion     NOT NULL
);
CREATE INDEX IX_Permit_Status   ON core.Permit (StatusCode, SubmittedAtUtc);
CREATE INDEX IX_Permit_Resident ON core.Permit (ResidentId);
GO

/* ---------- MFIPPA: who looked at whose personal information ---------- */
CREATE TABLE audit.PersonalInfoAccess (
    AccessId       bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_PersonalInfoAccess PRIMARY KEY,
    UserId         int           NOT NULL,
    ResidentId     int           NOT NULL,
    Purpose        nvarchar(200) NOT NULL,
    AccessedAtUtc  datetime2(0)  NOT NULL CONSTRAINT DF_PIA_AccessedAt DEFAULT (SYSUTCDATETIME()),
    HostName       nvarchar(128) NULL CONSTRAINT DF_PIA_Host DEFAULT (HOST_NAME())
);
CREATE INDEX IX_PersonalInfoAccess_Resident ON audit.PersonalInfoAccess (ResidentId, AccessedAtUtc);
GO

/* ---------- Integration + operations logging ---------- */
CREATE TABLE integ.ErpPostingLog (
    LogId            bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_ErpPostingLog PRIMARY KEY,
    RequestId        int            NOT NULL,
    AttemptNo        tinyint        NOT NULL,
    RequestPayload   xml            NOT NULL,
    ResponsePayload  xml            NULL,
    Succeeded        bit            NOT NULL,
    ErrorMessage     nvarchar(1000) NULL,
    DurationMs       int            NULL,
    LoggedAtUtc      datetime2(0)   NOT NULL CONSTRAINT DF_ErpPostingLog_LoggedAt DEFAULT (SYSUTCDATETIME())
);
CREATE INDEX IX_ErpPostingLog_Request ON integ.ErpPostingLog (RequestId, LoggedAtUtc);

CREATE TABLE ops.ErrorLog (
    ErrorId        bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_ErrorLog PRIMARY KEY,
    Source         varchar(100)   NOT NULL,
    Message        nvarchar(1000) NOT NULL,
    Detail         nvarchar(max)  NULL,
    UserName       nvarchar(100)  NULL,
    CorrelationId  varchar(64)    NULL,
    LoggedAtUtc    datetime2(0)   NOT NULL CONSTRAINT DF_ErrorLog_LoggedAt DEFAULT (SYSUTCDATETIME())
);
CREATE INDEX IX_ErrorLog_LoggedAt ON ops.ErrorLog (LoggedAtUtc DESC);

CREATE TABLE ops.JobRun (
    JobRunId      bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_JobRun PRIMARY KEY,
    JobName       varchar(100)   NOT NULL,
    StartedAtUtc  datetime2(0)   NOT NULL,
    EndedAtUtc    datetime2(0)   NULL,
    RowsAffected  int            NULL,
    Succeeded     bit            NULL,
    Message       nvarchar(1000) NULL
);
GO
