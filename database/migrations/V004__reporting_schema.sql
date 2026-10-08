/* =====================================================================
   V004 - Reporting star schema (Business Intelligence)
   Loaded nightly by ops.usp_Warehouse_Load (SQL Agent job). Contains no
   personal information, so the reporting login can read it freely.
   ===================================================================== */
SET XACT_ABORT ON;
GO

CREATE TABLE rpt.DimDate (
    DateKey        int          NOT NULL CONSTRAINT PK_DimDate PRIMARY KEY,   -- yyyymmdd
    FullDate       date         NOT NULL,
    [Year]         smallint     NOT NULL,
    [Quarter]      tinyint      NOT NULL,
    [Month]        tinyint      NOT NULL,
    MonthName      nvarchar(12) NOT NULL,
    YearMonth      char(7)      NOT NULL,   -- 2026-10
    IsBusinessDay  bit          NOT NULL
);

CREATE TABLE rpt.DimDepartment (
    DepartmentKey   int           NOT NULL CONSTRAINT PK_DimDepartment PRIMARY KEY,
    DepartmentCode  varchar(20)   NOT NULL,
    DepartmentName  nvarchar(100) NOT NULL,
    DivisionName    nvarchar(100) NULL,    -- parent in the org hierarchy
    OrgPath         nvarchar(400) NOT NULL,
    OrgNode         hierarchyid   NOT NULL
);

CREATE TABLE rpt.DimCategory (
    CategoryKey     int          NOT NULL CONSTRAINT PK_DimCategory PRIMARY KEY,
    CategoryName    nvarchar(80) NOT NULL,
    CategoryGroup   nvarchar(80) NOT NULL,
    SlaBusinessDays tinyint      NOT NULL
);

CREATE TABLE rpt.DimMunicipality (
    MunicipalityKey  tinyint      NOT NULL CONSTRAINT PK_DimMunicipality PRIMARY KEY,
    MunicipalityName nvarchar(60) NOT NULL
);

CREATE TABLE rpt.FactServiceRequest (
    RequestId         int           NOT NULL CONSTRAINT PK_FactServiceRequest PRIMARY KEY,
    SubmittedDateKey  int           NOT NULL,
    ClosedDateKey     int           NULL,
    DueDateKey        int           NOT NULL,
    DepartmentKey     int           NOT NULL,
    CategoryKey       int           NOT NULL,
    MunicipalityKey   tinyint       NOT NULL,
    StatusCode        varchar(20)   NOT NULL,
    IsOpen            bit           NOT NULL,
    Priority          tinyint       NOT NULL,
    Channel           varchar(10)   NOT NULL,
    BusinessDaysOpen  int           NOT NULL,   -- to close date, or to load date if still open
    IsOverdue         bit           NOT NULL,
    MetSla            bit           NULL,       -- NULL while open
    CostAmount        decimal(12,2) NULL
);
-- Columnstore: aggregate queries over hundreds of thousands of rows stay fast.
CREATE NONCLUSTERED COLUMNSTORE INDEX NCCI_FactServiceRequest ON rpt.FactServiceRequest
    (SubmittedDateKey, ClosedDateKey, DepartmentKey, CategoryKey, MunicipalityKey, StatusCode, IsOpen,
     Priority, Channel, BusinessDaysOpen, IsOverdue, MetSla, CostAmount);

CREATE TABLE rpt.FactPermit (
    PermitId          int           NOT NULL CONSTRAINT PK_FactPermit PRIMARY KEY,
    SubmittedDateKey  int           NOT NULL,
    DecidedDateKey    int           NULL,
    PermitTypeCode    varchar(20)   NOT NULL,
    PermitTypeName    nvarchar(80)  NOT NULL,
    StatusCode        varchar(20)   NOT NULL,
    ProjectValue      decimal(14,2) NOT NULL,
    Fee               decimal(10,2) NOT NULL
);
GO
