/* Workflow engine tests, run as a CLERK session. */
SET NOCOUNT ON;

IF NOT EXISTS (SELECT 1 FROM sec.AppUser WHERE UserName = 'test.clerk')
    INSERT sec.AppUser (UserName, DisplayName, PasswordHash, RoleCode) VALUES ('test.clerk', 'Test Clerk', 'x', 'CLERK');
DECLARE @Clerk int = (SELECT UserId FROM sec.AppUser WHERE UserName = 'test.clerk');
DECLARE @Pothole int = (SELECT CategoryId FROM core.RequestCategory WHERE Name = N'Pothole');

EXEC app.usp_Session_Set @UserId = @Clerk;

-- Create on behalf of a caller
DECLARE @created TABLE (RequestId int, RequestNumber varchar(20), DueDate date);
INSERT @created EXEC app.usp_ServiceRequest_Create
    @CategoryId = @Pothole, @MunicipalityId = 6, @Description = N'Large pothole in the right lane',
    @LocationText = N'County Rd 90 at Line 4', @Channel = 'PHONE',
    @CallerFirstName = N'Test', @CallerLastName = N'Caller', @CallerEmail = N'test.caller@example.com';

DECLARE @Id int = (SELECT RequestId FROM @created), @Ver binary(8);
IF @Id IS NULL THROW 50100, 'FAIL: request not created', 1;
IF (SELECT DueDate FROM @created) IS NULL THROW 50100, 'FAIL: due date not calculated', 1;

-- Validation: too-short description is rejected
BEGIN TRY
    EXEC app.usp_ServiceRequest_Create @CategoryId = @Pothole, @MunicipalityId = 6, @Description = N'short', @LocationText = N'Somewhere';
    THROW 50100, 'FAIL: short description accepted', 1;
END TRY
BEGIN CATCH
    IF ERROR_NUMBER() <> 50005 THROW;
END CATCH

-- Legal transition: SUBMITTED -> TRIAGED by a clerk
SELECT @Ver = RowVer FROM core.ServiceRequest WHERE RequestId = @Id;
EXEC app.usp_ServiceRequest_Transition @RequestId = @Id, @ToStatus = 'TRIAGED', @RowVer = @Ver, @Note = N'Checked location';
IF (SELECT StatusCode FROM core.ServiceRequest WHERE RequestId = @Id) <> 'TRIAGED' THROW 50100, 'FAIL: triage did not apply', 1;
IF (SELECT COUNT(*) FROM core.ServiceRequestEvent WHERE RequestId = @Id) <> 2 THROW 50100, 'FAIL: events not recorded', 1;

-- Concurrency: the old row version must now be rejected
BEGIN TRY
    EXEC app.usp_ServiceRequest_Transition @RequestId = @Id, @ToStatus = 'CANCELLED', @RowVer = @Ver;
    THROW 50100, 'FAIL: stale row version accepted', 1;
END TRY
BEGIN CATCH
    IF ERROR_NUMBER() <> 50004 THROW;
END CATCH

-- Illegal transition for the role: clerks cannot assign crews
SELECT @Ver = RowVer FROM core.ServiceRequest WHERE RequestId = @Id;
BEGIN TRY
    EXEC app.usp_ServiceRequest_Transition @RequestId = @Id, @ToStatus = 'ASSIGNED', @RowVer = @Ver, @CrewId = 1;
    THROW 50100, 'FAIL: clerk was allowed to assign', 1;
END TRY
BEGIN CATCH
    IF ERROR_NUMBER() <> 50003 THROW;
END CATCH

-- Screen-level security in the database: clerks cannot open the admin user list
BEGIN TRY
    EXEC app.usp_User_List;
    THROW 50100, 'FAIL: clerk reached ADMIN_USERS', 1;
END TRY
BEGIN CATCH
    IF ERROR_NUMBER() <> 50001 THROW;
END CATCH

PRINT 'PASS T02_workflow';
