/* =====================================================================
   R02 - Authentication, session and access-administration procedures
   (JD duty 10: "Administer access rights and passwords")
   ===================================================================== */

/* Called by the web app immediately after opening a connection for a signed-in user.
   Values are read-only for the life of the connection, so later SQL cannot escalate. */
CREATE OR ALTER PROCEDURE app.usp_Session_Set
    @UserId int
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Role varchar(20), @Dept int, @Res int;

    SELECT @Role = RoleCode, @Dept = DepartmentId, @Res = ResidentId
    FROM sec.AppUser
    WHERE UserId = @UserId AND IsActive = 1;

    IF @Role IS NULL
        THROW 50001, 'Unknown or inactive user.', 1;

    EXEC sys.sp_set_session_context @key = N'UserId',       @value = @UserId, @read_only = 1;
    EXEC sys.sp_set_session_context @key = N'RoleCode',     @value = @Role,   @read_only = 1;
    EXEC sys.sp_set_session_context @key = N'DepartmentId', @value = @Dept,   @read_only = 1;
    EXEC sys.sp_set_session_context @key = N'ResidentId',   @value = @Res,    @read_only = 1;
END
GO

/* Returns the stored hash; verification happens in the app with PBKDF2 (ASP.NET Core PasswordHasher). */
CREATE OR ALTER PROCEDURE app.usp_User_GetForLogin
    @UserName nvarchar(100)
AS
BEGIN
    SET NOCOUNT ON;
    SELECT UserId, UserName, DisplayName, PasswordHash, RoleCode, IsActive,
           CAST(CASE WHEN LockedUntilUtc > SYSUTCDATETIME() THEN 1 ELSE 0 END AS bit) AS IsLocked,
           LockedUntilUtc
    FROM sec.AppUser
    WHERE UserName = @UserName;
END
GO

/* Lockout policy: 5 consecutive failures lock the account for 15 minutes. */
CREATE OR ALTER PROCEDURE app.usp_User_RecordLogin
    @UserId    int,
    @Succeeded bit
AS
BEGIN
    SET NOCOUNT ON;
    IF @Succeeded = 1
        UPDATE sec.AppUser
        SET FailedLoginCount = 0, LockedUntilUtc = NULL, LastLoginUtc = SYSUTCDATETIME()
        WHERE UserId = @UserId;
    ELSE
        UPDATE sec.AppUser
        SET FailedLoginCount = CASE WHEN FailedLoginCount + 1 >= 5 THEN 0 ELSE FailedLoginCount + 1 END,
            LockedUntilUtc   = CASE WHEN FailedLoginCount + 1 >= 5 THEN DATEADD(minute, 15, SYSUTCDATETIME()) ELSE LockedUntilUtc END
        WHERE UserId = @UserId;
END
GO

CREATE OR ALTER PROCEDURE app.usp_Screen_ListForRole
    @RoleCode varchar(20)
AS
BEGIN
    SET NOCOUNT ON;
    SELECT ScreenCode FROM sec.RoleScreen WHERE RoleCode = @RoleCode;
END
GO

/* First-run only: creates the initial administrator when none exists. */
CREATE OR ALTER PROCEDURE app.usp_User_Bootstrap
    @UserName     nvarchar(100),
    @DisplayName  nvarchar(100),
    @PasswordHash varchar(200)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    BEGIN TRAN;
        IF EXISTS (SELECT 1 FROM sec.AppUser WITH (UPDLOCK, HOLDLOCK) WHERE RoleCode = 'ADMIN')
            THROW 50001, 'An administrator already exists; bootstrap is disabled.', 1;

        INSERT sec.AppUser (UserName, DisplayName, PasswordHash, RoleCode, DepartmentId)
        SELECT @UserName, @DisplayName, @PasswordHash, 'ADMIN', DepartmentId
        FROM core.Department WHERE Code = 'IT';
    COMMIT;
    SELECT CAST(SCOPE_IDENTITY() AS int) AS UserId;
END
GO

/* Public self-registration for residents. Links to an existing resident record
   (e.g. one created when they phoned in a request) when the email matches. */
CREATE OR ALTER PROCEDURE app.usp_Resident_Register
    @FirstName      nvarchar(60),
    @LastName       nvarchar(60),
    @Email          nvarchar(254),
    @Phone          varchar(25),
    @StreetAddress  nvarchar(200),
    @MunicipalityId tinyint,
    @PasswordHash   varchar(200)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @Email IS NULL OR @Email NOT LIKE '%_@_%._%'
        THROW 50005, 'A valid email address is required.', 1;
    IF LEN(LTRIM(@FirstName)) = 0 OR LEN(LTRIM(@LastName)) = 0
        THROW 50005, 'First and last name are required.', 1;

    BEGIN TRY
        BEGIN TRAN;
            IF EXISTS (SELECT 1 FROM sec.AppUser WITH (UPDLOCK, HOLDLOCK) WHERE UserName = @Email)
                THROW 50005, 'An account with this email already exists.', 1;

            DECLARE @ResidentId int = (SELECT ResidentId FROM core.Resident WITH (UPDLOCK, HOLDLOCK) WHERE Email = @Email);

            IF @ResidentId IS NULL
            BEGIN
                INSERT core.Resident (FirstName, LastName, Email, Phone, StreetAddress, MunicipalityId)
                VALUES (@FirstName, @LastName, @Email, @Phone, @StreetAddress, @MunicipalityId);
                SET @ResidentId = SCOPE_IDENTITY();
            END
            ELSE
                UPDATE core.Resident
                SET FirstName = @FirstName, LastName = @LastName, Phone = @Phone,
                    StreetAddress = @StreetAddress, MunicipalityId = @MunicipalityId
                WHERE ResidentId = @ResidentId;

            INSERT sec.AppUser (UserName, DisplayName, PasswordHash, RoleCode, ResidentId)
            VALUES (@Email, CONCAT(@FirstName, N' ', @LastName), @PasswordHash, 'RESIDENT', @ResidentId);
        COMMIT;
        SELECT CAST(SCOPE_IDENTITY() AS int) AS UserId;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        THROW;
    END CATCH
END
GO

CREATE OR ALTER PROCEDURE app.usp_User_List
AS
BEGIN
    SET NOCOUNT ON;
    EXEC ops.usp_AssertScreen 'ADMIN_USERS';

    SELECT u.UserId, u.UserName, u.DisplayName, u.RoleCode, r.DisplayName AS RoleName,
           u.DepartmentId, d.Name AS DepartmentName, u.IsActive,
           CAST(CASE WHEN u.LockedUntilUtc > SYSUTCDATETIME() THEN 1 ELSE 0 END AS bit) AS IsLocked,
           u.LastLoginUtc, u.PasswordChangedUtc
    FROM sec.AppUser u
    JOIN sec.Role r ON r.RoleCode = u.RoleCode
    LEFT JOIN core.Department d ON d.DepartmentId = u.DepartmentId
    WHERE u.RoleCode <> 'RESIDENT'
    ORDER BY u.RoleCode, u.UserName;
END
GO

/* Create (@UserId NULL) or update a staff account. */
CREATE OR ALTER PROCEDURE app.usp_User_Save
    @UserId       int = NULL,
    @UserName     nvarchar(100),
    @DisplayName  nvarchar(100),
    @RoleCode     varchar(20),
    @DepartmentId int = NULL,
    @IsActive     bit = 1,
    @PasswordHash varchar(200) = NULL   -- required when creating; when updating, NULL keeps the current password
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    EXEC ops.usp_AssertScreen 'ADMIN_USERS';

    DECLARE @Me int = CAST(SESSION_CONTEXT(N'UserId') AS int);

    IF @RoleCode NOT IN ('CLERK', 'SUPERVISOR', 'ADMIN')
        THROW 50005, 'Staff accounts must be Clerk, Supervisor or Admin. Residents self-register.', 1;
    IF @RoleCode = 'SUPERVISOR' AND @DepartmentId IS NULL
        THROW 50005, 'Supervisors must belong to a department.', 1;
    IF @UserId = @Me AND (@IsActive = 0 OR @RoleCode <> 'ADMIN')
        THROW 50005, 'You cannot deactivate or demote your own account.', 1;

    IF @UserId IS NULL
    BEGIN
        IF @PasswordHash IS NULL THROW 50005, 'A password is required for new accounts.', 1;
        IF EXISTS (SELECT 1 FROM sec.AppUser WHERE UserName = @UserName)
            THROW 50005, 'That user name is already taken.', 1;

        INSERT sec.AppUser (UserName, DisplayName, PasswordHash, RoleCode, DepartmentId, IsActive)
        VALUES (@UserName, @DisplayName, @PasswordHash, @RoleCode, @DepartmentId, @IsActive);
        SELECT CAST(SCOPE_IDENTITY() AS int) AS UserId;
    END
    ELSE
    BEGIN
        UPDATE sec.AppUser
        SET UserName = @UserName, DisplayName = @DisplayName, RoleCode = @RoleCode,
            DepartmentId = @DepartmentId, IsActive = @IsActive,
            PasswordHash       = COALESCE(@PasswordHash, PasswordHash),
            PasswordChangedUtc = CASE WHEN @PasswordHash IS NULL THEN PasswordChangedUtc ELSE SYSUTCDATETIME() END,
            FailedLoginCount   = CASE WHEN @PasswordHash IS NULL THEN FailedLoginCount ELSE 0 END,
            LockedUntilUtc     = CASE WHEN @PasswordHash IS NULL THEN LockedUntilUtc ELSE NULL END
        WHERE UserId = @UserId AND RoleCode <> 'RESIDENT';
        IF @@ROWCOUNT = 0 THROW 50002, 'Staff user not found.', 1;
        SELECT @UserId AS UserId;
    END
END
GO

CREATE OR ALTER PROCEDURE app.usp_User_Unlock
    @UserId int
AS
BEGIN
    SET NOCOUNT ON;
    EXEC ops.usp_AssertScreen 'ADMIN_USERS';
    UPDATE sec.AppUser SET FailedLoginCount = 0, LockedUntilUtc = NULL WHERE UserId = @UserId;
END
GO

CREATE OR ALTER PROCEDURE app.usp_RoleScreen_Matrix
AS
BEGIN
    SET NOCOUNT ON;
    EXEC ops.usp_AssertScreen 'ADMIN_SCREENS';
    SELECT r.RoleCode, r.DisplayName AS RoleName, s.ScreenCode, s.DisplayName AS ScreenName,
           CAST(CASE WHEN rs.RoleCode IS NULL THEN 0 ELSE 1 END AS bit) AS Granted
    FROM sec.Role r
    CROSS JOIN sec.Screen s
    LEFT JOIN sec.RoleScreen rs ON rs.RoleCode = r.RoleCode AND rs.ScreenCode = s.ScreenCode
    ORDER BY s.ScreenCode, r.RoleCode;
END
GO

CREATE OR ALTER PROCEDURE app.usp_RoleScreen_Set
    @RoleCode   varchar(20),
    @ScreenCode varchar(40),
    @Granted    bit
AS
BEGIN
    SET NOCOUNT ON;
    EXEC ops.usp_AssertScreen 'ADMIN_SCREENS';

    IF @RoleCode = 'ADMIN' AND @ScreenCode IN ('ADMIN_SCREENS', 'ADMIN_USERS') AND @Granted = 0
        THROW 50005, 'Refusing to remove administration screens from the ADMIN role (would lock everyone out).', 1;

    IF @Granted = 1 AND NOT EXISTS (SELECT 1 FROM sec.RoleScreen WHERE RoleCode = @RoleCode AND ScreenCode = @ScreenCode)
        INSERT sec.RoleScreen (RoleCode, ScreenCode) VALUES (@RoleCode, @ScreenCode);
    ELSE IF @Granted = 0
        DELETE sec.RoleScreen WHERE RoleCode = @RoleCode AND ScreenCode = @ScreenCode;
END
GO

/* ---------- Lookups (reference data for drop-downs) ---------- */
CREATE OR ALTER PROCEDURE app.usp_Lookup_Categories
AS
BEGIN
    SET NOCOUNT ON;
    SELECT CategoryId, PathName, SlaBusinessDays, DefaultPriority
    FROM core.vw_CategoryPath
    WHERE DepartmentId IS NOT NULL AND IsActive = 1
    ORDER BY PathName;
END
GO

CREATE OR ALTER PROCEDURE app.usp_Lookup_Municipalities
AS
BEGIN
    SET NOCOUNT ON;
    SELECT MunicipalityId, Name FROM core.Municipality ORDER BY Name;
END
GO

/* Org chart in depth-first order with indentation level (hierarchyid). */
CREATE OR ALTER PROCEDURE app.usp_Lookup_Departments
AS
BEGIN
    SET NOCOUNT ON;
    SELECT DepartmentId, Code, Name, CostCentre, OrgLevel, OrgNode.ToString() AS OrgPath
    FROM core.Department
    WHERE IsActive = 1
    ORDER BY OrgNode;
END
GO

/* Crews belonging to the request's department or any of its sub-units. */
CREATE OR ALTER PROCEDURE app.usp_Lookup_Crews
    @DepartmentId int
AS
BEGIN
    SET NOCOUNT ON;
    SELECT c.CrewId, c.Name, d.Name AS DepartmentName
    FROM core.Crew c
    JOIN core.Department d ON d.DepartmentId = c.DepartmentId
    JOIN core.Department root ON root.DepartmentId = @DepartmentId
    WHERE c.IsActive = 1 AND d.OrgNode.IsDescendantOf(root.OrgNode) = 1
    ORDER BY c.Name;
END
GO

CREATE OR ALTER PROCEDURE app.usp_Lookup_Statuses
AS
BEGIN
    SET NOCOUNT ON;
    SELECT StatusCode, DisplayName, IsTerminal FROM core.RequestStatus ORDER BY SortOrder;
END
GO

CREATE OR ALTER PROCEDURE app.usp_Lookup_PermitTypes
AS
BEGIN
    SET NOCOUNT ON;
    SELECT PermitTypeCode, DisplayName, BaseFee, RatePerThousand, MinFee, MaxFee
    FROM core.PermitType ORDER BY DisplayName;
END
GO
