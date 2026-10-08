/* =====================================================================
   Post-deploy: environment-specific logins and users.
   Passwords are sqlcmd variables supplied by the pipeline from secrets -
   they are never committed to source control.
     sqlcmd ... -v DbName="PublicServicePortal_Test" AppPassword="..." IntegPassword="..." RptPassword="..."
   ===================================================================== */
:on error exit
SET NOCOUNT ON;
USE master;
GO

IF SUSER_ID('portal_app') IS NULL
    CREATE LOGIN portal_app WITH PASSWORD = N'$(AppPassword)', CHECK_POLICY = ON, DEFAULT_DATABASE = [$(DbName)];
ELSE
    ALTER LOGIN portal_app WITH PASSWORD = N'$(AppPassword)';

IF SUSER_ID('portal_integration') IS NULL
    CREATE LOGIN portal_integration WITH PASSWORD = N'$(IntegPassword)', CHECK_POLICY = ON, DEFAULT_DATABASE = [$(DbName)];
ELSE
    ALTER LOGIN portal_integration WITH PASSWORD = N'$(IntegPassword)';

IF SUSER_ID('portal_reports') IS NULL
    CREATE LOGIN portal_reports WITH PASSWORD = N'$(RptPassword)', CHECK_POLICY = ON, DEFAULT_DATABASE = [$(DbName)];
ELSE
    ALTER LOGIN portal_reports WITH PASSWORD = N'$(RptPassword)';
GO

USE [$(DbName)];
GO

IF DATABASE_PRINCIPAL_ID('portal_app') IS NULL         CREATE USER portal_app FOR LOGIN portal_app;
IF DATABASE_PRINCIPAL_ID('portal_integration') IS NULL CREATE USER portal_integration FOR LOGIN portal_integration;
IF DATABASE_PRINCIPAL_ID('portal_reports') IS NULL     CREATE USER portal_reports FOR LOGIN portal_reports;

ALTER ROLE app_executor   ADD MEMBER portal_app;
ALTER ROLE integ_executor ADD MEMBER portal_integration;
ALTER ROLE rpt_reader     ADD MEMBER portal_reports;
GO
