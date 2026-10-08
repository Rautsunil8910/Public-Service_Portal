/* Row-Level Security: a Transportation supervisor sees Roads + Traffic (sub-units), not Waste. */
SET NOCOUNT ON;

DECLARE @Trans int = (SELECT DepartmentId FROM core.Department WHERE Code = 'TRANS'),
        @Roads int = (SELECT DepartmentId FROM core.Department WHERE Code = 'ROADS'),
        @Traffic int = (SELECT DepartmentId FROM core.Department WHERE Code = 'TRAFFIC'),
        @Waste int = (SELECT DepartmentId FROM core.Department WHERE Code = 'WASTE'),
        @Cat int = (SELECT CategoryId FROM core.RequestCategory WHERE Name = N'Pothole');

IF NOT EXISTS (SELECT 1 FROM sec.AppUser WHERE UserName = 'test.sup.trans')
    INSERT sec.AppUser (UserName, DisplayName, PasswordHash, RoleCode, DepartmentId) VALUES ('test.sup.trans', 'Test Sup', 'x', 'SUPERVISOR', @Trans);

INSERT core.Resident (FirstName, LastName, Email, Phone, StreetAddress) VALUES (N'Rls', N'Tester', N'rls.tester@example.com', '705-555-0100', N'1 Test St');
DECLARE @Res int = SCOPE_IDENTITY();

-- Seed one request per department (as dbo, before the session is restricted)
INSERT core.ServiceRequest (CategoryId, DepartmentId, MunicipalityId, ResidentId, Channel, Priority, Description, LocationText, DueDate)
VALUES (@Cat, @Roads,   1, @Res,  'WEB', 3, N'RLS test roads',   N'RLS-TEST', '2030-01-01'),
       (@Cat, @Traffic, 1, NULL,  'WEB', 3, N'RLS test traffic', N'RLS-TEST', '2030-01-01'),
       (@Cat, @Waste,   1, NULL,  'WEB', 3, N'RLS test waste',   N'RLS-TEST', '2030-01-01');

DECLARE @Sup int = (SELECT UserId FROM sec.AppUser WHERE UserName = 'test.sup.trans');
EXEC app.usp_Session_Set @UserId = @Sup;

IF (SELECT COUNT(*) FROM core.ServiceRequest WHERE LocationText = N'RLS-TEST') <> 2
    THROW 50100, 'FAIL: supervisor should see exactly Roads + Traffic rows', 1;
IF EXISTS (SELECT 1 FROM core.ServiceRequest WHERE LocationText = N'RLS-TEST' AND DepartmentId = @Waste)
    THROW 50100, 'FAIL: supervisor can see another department''s request', 1;

-- Session context is read-only: cannot be changed to escalate
BEGIN TRY
    EXEC sys.sp_set_session_context @key = N'RoleCode', @value = 'ADMIN';
    THROW 50100, 'FAIL: session context was writable', 1;
END TRY
BEGIN CATCH
    IF ERROR_NUMBER() = 50100 THROW;
END CATCH

-- Audited unmasking: purpose required, then logged
BEGIN TRY
    EXEC app.usp_Resident_GetContact @ResidentId = @Res, @Purpose = N'';
    THROW 50100, 'FAIL: contact revealed without a purpose', 1;
END TRY
BEGIN CATCH
    IF ERROR_NUMBER() <> 50005 THROW;
END CATCH

DECLARE @contact TABLE (ResidentId int, FirstName nvarchar(60), LastName nvarchar(60), Email nvarchar(254), Phone varchar(25), StreetAddress nvarchar(200));
INSERT @contact EXEC app.usp_Resident_GetContact @ResidentId = @Res, @Purpose = N'Calling back about pothole repair schedule';
IF (SELECT Email FROM @contact) <> N'rls.tester@example.com' THROW 50100, 'FAIL: unmasked email not returned', 1;
IF NOT EXISTS (SELECT 1 FROM audit.PersonalInfoAccess WHERE ResidentId = @Res AND UserId = @Sup)
    THROW 50100, 'FAIL: personal info access was not audited', 1;

PRINT 'PASS T03_row_level_security';
