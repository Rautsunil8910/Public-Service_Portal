/* =====================================================================
   V003 - Database security model
   Layers (JD duty 2: "screen, field, table, and process level security"):
     * Table level   : app logins get EXECUTE on procedures only; DENY on tables.
     * Row level     : Row-Level Security limits supervisors to their department subtree
                       and residents to their own records.
     * Field level   : Dynamic Data Masking on resident contact details; unmasked only
                       through an audited, role-checked procedure.
     * Screen level  : sec.RoleScreen, enforced in the web app AND re-checked in procedures.
     * Process level : workflow transitions validated per role (core.StatusTransition).
   ===================================================================== */
SET XACT_ABORT ON;
GO

/* ---------- Database roles (logins/users are created per environment by post-deploy) ---------- */
IF DATABASE_PRINCIPAL_ID('app_executor')   IS NULL CREATE ROLE app_executor;    -- web application
IF DATABASE_PRINCIPAL_ID('integ_executor') IS NULL CREATE ROLE integ_executor;  -- ERP integration worker
IF DATABASE_PRINCIPAL_ID('rpt_reader')     IS NULL CREATE ROLE rpt_reader;      -- SSRS / Excel / Power BI
GO

-- Process-level: each role can only run its own schema's procedures.
GRANT EXECUTE ON SCHEMA::app   TO app_executor;
GRANT EXECUTE ON SCHEMA::integ TO integ_executor;
GRANT SELECT  ON SCHEMA::rpt   TO rpt_reader;

-- Table-level: no direct data access for the application accounts. Procedures still work
-- because of ownership chaining (procedures and tables share the dbo owner).
DENY SELECT, INSERT, UPDATE, DELETE ON SCHEMA::core  TO app_executor, integ_executor, rpt_reader;
DENY SELECT, INSERT, UPDATE, DELETE ON SCHEMA::sec   TO app_executor, integ_executor, rpt_reader;
DENY SELECT, INSERT, UPDATE, DELETE ON SCHEMA::audit TO app_executor, integ_executor, rpt_reader;
DENY SELECT, INSERT, UPDATE, DELETE ON SCHEMA::ops   TO app_executor, integ_executor, rpt_reader;
DENY SELECT, INSERT, UPDATE, DELETE ON SCHEMA::integ TO app_executor, integ_executor, rpt_reader;
DENY SELECT, INSERT, UPDATE, DELETE ON SCHEMA::rpt   TO app_executor, integ_executor;
DENY VIEW DEFINITION TO app_executor, integ_executor, rpt_reader;
GO

/* ---------- Row-Level Security ----------
   The web app calls app.usp_Session_Set after opening each connection, which stores the
   signed-in user's role/department/resident id in read-only SESSION_CONTEXT.            */
CREATE FUNCTION sec.fn_ServiceRequestAccess (@DepartmentId int, @ResidentId int)
RETURNS TABLE
WITH SCHEMABINDING
AS RETURN
    SELECT 1 AS AccessGranted
    WHERE
        CAST(SESSION_CONTEXT(N'RoleCode') AS varchar(20)) IN ('ADMIN', 'CLERK')
     OR (CAST(SESSION_CONTEXT(N'RoleCode') AS varchar(20)) = 'SUPERVISOR'
         AND EXISTS (SELECT 1
                     FROM core.Department target
                     JOIN core.Department mine
                       ON mine.DepartmentId = CAST(SESSION_CONTEXT(N'DepartmentId') AS int)
                     WHERE target.DepartmentId = @DepartmentId
                       AND target.OrgNode.IsDescendantOf(mine.OrgNode) = 1))
     OR (CAST(SESSION_CONTEXT(N'RoleCode') AS varchar(20)) = 'RESIDENT'
         AND @ResidentId = CAST(SESSION_CONTEXT(N'ResidentId') AS int))
        -- No user session: only trusted service principals (DBA jobs, integration, reporting).
     OR (SESSION_CONTEXT(N'RoleCode') IS NULL
         AND (IS_MEMBER('db_owner') = 1 OR IS_MEMBER('integ_executor') = 1 OR IS_MEMBER('rpt_reader') = 1));
GO

CREATE FUNCTION sec.fn_PermitAccess (@ResidentId int)
RETURNS TABLE
WITH SCHEMABINDING
AS RETURN
    SELECT 1 AS AccessGranted
    WHERE
        CAST(SESSION_CONTEXT(N'RoleCode') AS varchar(20)) IN ('ADMIN', 'CLERK', 'SUPERVISOR')
     OR (CAST(SESSION_CONTEXT(N'RoleCode') AS varchar(20)) = 'RESIDENT'
         AND @ResidentId = CAST(SESSION_CONTEXT(N'ResidentId') AS int))
     OR (SESSION_CONTEXT(N'RoleCode') IS NULL
         AND (IS_MEMBER('db_owner') = 1 OR IS_MEMBER('rpt_reader') = 1));
GO

CREATE SECURITY POLICY sec.RowAccessPolicy
    ADD FILTER PREDICATE sec.fn_ServiceRequestAccess(DepartmentId, ResidentId) ON core.ServiceRequest,
    ADD BLOCK  PREDICATE sec.fn_ServiceRequestAccess(DepartmentId, ResidentId) ON core.ServiceRequest AFTER UPDATE,
    ADD FILTER PREDICATE sec.fn_PermitAccess(ResidentId) ON core.Permit
WITH (STATE = ON, SCHEMABINDING = ON);
GO

/* ---------- Dynamic Data Masking (field level) ---------- */
-- A column can't be altered while an index depends on it, so drop and recreate the email index.
DROP INDEX UX_Resident_Email ON core.Resident;
ALTER TABLE core.Resident ALTER COLUMN Email         ADD MASKED WITH (FUNCTION = 'email()');
ALTER TABLE core.Resident ALTER COLUMN Phone         ADD MASKED WITH (FUNCTION = 'partial(0,"XXX-XXX-",4)');
ALTER TABLE core.Resident ALTER COLUMN StreetAddress ADD MASKED WITH (FUNCTION = 'default()');
CREATE UNIQUE INDEX UX_Resident_Email ON core.Resident (Email) WHERE Email IS NOT NULL;
-- No application role is granted UNMASK. Unmasked values are only returned by
-- app.usp_Resident_GetContact (EXECUTE AS OWNER), which checks the screen permission
-- and writes an audit.PersonalInfoAccess row first.
GO
