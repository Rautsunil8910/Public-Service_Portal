/* Table-level permissions and Dynamic Data Masking, tested by impersonating role members. */
SET NOCOUNT ON;

IF DATABASE_PRINCIPAL_ID('test_app_user') IS NULL CREATE USER test_app_user WITHOUT LOGIN;
ALTER ROLE app_executor ADD MEMBER test_app_user;
IF DATABASE_PRINCIPAL_ID('test_masked_user') IS NULL CREATE USER test_masked_user WITHOUT LOGIN;
GRANT SELECT ON core.Resident TO test_masked_user;

IF NOT EXISTS (SELECT 1 FROM core.Resident WHERE Email = N'mask.check@example.com')
    INSERT core.Resident (FirstName, LastName, Email, Phone, StreetAddress) VALUES (N'Mask', N'Check', N'mask.check@example.com', '705-555-0199', N'99 Hidden Rd');

-- 1. The application account cannot read tables directly...
DECLARE @denied bit = 0;
EXECUTE AS USER = 'test_app_user';
BEGIN TRY
    DECLARE @x int = (SELECT COUNT(*) FROM core.Resident);
END TRY
BEGIN CATCH
    IF ERROR_NUMBER() = 229 SET @denied = 1;   -- permission denied
END CATCH
-- ...but can execute the procedures it is meant to use.
EXEC app.usp_Lookup_Municipalities;
REVERT;
IF @denied = 0 THROW 50100, 'FAIL: app_executor could SELECT from core.Resident', 1;

-- 2. A user without UNMASK sees masked contact details.
DECLARE @email nvarchar(254), @phone varchar(25), @addr nvarchar(200);
EXECUTE AS USER = 'test_masked_user';
SELECT @email = Email, @phone = Phone, @addr = StreetAddress FROM core.Resident WHERE FirstName = N'Mask' AND LastName = N'Check';
REVERT;
IF @email = N'mask.check@example.com' THROW 50100, 'FAIL: email not masked', 1;
IF @phone NOT LIKE 'XXX-XXX-0199'        THROW 50100, 'FAIL: phone mask should keep last 4 digits', 1;
IF @addr = N'99 Hidden Rd'               THROW 50100, 'FAIL: address not masked', 1;

PRINT 'PASS T04_permissions_and_masking';
