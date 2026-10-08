<#
  Windows equivalent of deploy.sh (same steps, same variables).
  Example:
    $env:SQL_PASSWORD = 'YourStrong!Passw0rd'
    $env:APP_PASSWORD = '...'; $env:INTEG_PASSWORD = '...'; $env:RPT_PASSWORD = '...'
    $env:SEED_ROWS = '500000'
    .\database\deploy.ps1
  Requires sqlcmd (https://learn.microsoft.com/sql/tools/sqlcmd/sqlcmd-utility).
#>
$ErrorActionPreference = 'Stop'

$SqlServer = if ($env:SQL_SERVER) { $env:SQL_SERVER } else { 'localhost,1433' }
$SqlUser   = if ($env:SQL_USER)   { $env:SQL_USER }   else { 'sa' }
$DbName    = if ($env:DB_NAME)    { $env:DB_NAME }    else { 'PublicServicePortal' }
$Extra     = if ($env:SQLCMD_EXTRA) { $env:SQLCMD_EXTRA.Split(' ') } else { @() }
if (-not $env:SQL_PASSWORD) { throw 'SQL_PASSWORD must be set' }
if ($DbName -notmatch '^[A-Za-z0-9_]+$') { throw 'DB_NAME may only contain letters, digits and _' }
$env:SQLCMDPASSWORD = $env:SQL_PASSWORD
$Dir = $PSScriptRoot

function Run([string[]]$SqlArgs) {
    & sqlcmd -S $SqlServer -U $SqlUser -b -I -f 65001 @Extra @SqlArgs
    if ($LASTEXITCODE -ne 0) { throw "sqlcmd failed: $SqlArgs" }
}
function Query([string]$Sql) {
    (& sqlcmd -S $SqlServer -U $SqlUser -b -I @Extra -d $DbName -h -1 -W -Q "SET NOCOUNT ON; $Sql" | Out-String).Trim()
}

Write-Host "==> Target: $SqlServer / $DbName"
Run @('-d','master','-Q', @"
IF DB_ID('$DbName') IS NULL CREATE DATABASE [$DbName];
ALTER DATABASE [$DbName] SET RECOVERY FULL;
ALTER DATABASE [$DbName] SET QUERY_STORE = ON (OPERATION_MODE = READ_WRITE);
IF (SELECT is_read_committed_snapshot_on FROM sys.databases WHERE name = '$DbName') = 0
    ALTER DATABASE [$DbName] SET READ_COMMITTED_SNAPSHOT ON WITH ROLLBACK IMMEDIATE;
"@)

Run @('-d', $DbName, '-Q', @"
IF SCHEMA_ID('ops') IS NULL EXEC('CREATE SCHEMA ops');
IF OBJECT_ID('ops.SchemaVersion') IS NULL
    CREATE TABLE ops.SchemaVersion (
        Version varchar(50) NOT NULL PRIMARY KEY, ScriptName nvarchar(260) NOT NULL,
        AppliedAtUtc datetime2(0) NOT NULL DEFAULT SYSUTCDATETIME(), AppliedBy sysname NOT NULL DEFAULT SUSER_SNAME());
"@)

Write-Host '==> Versioned migrations'
Get-ChildItem "$Dir\migrations\V*.sql" | Sort-Object Name | ForEach-Object {
    $version = $_.Name.Split('__')[0]
    if ((Query "SELECT COUNT(*) FROM ops.SchemaVersion WHERE Version = '$version'") -eq '0') {
        Write-Host "    applying $($_.Name)"
        Run @('-d', $DbName, '-i', $_.FullName)
        Run @('-d', $DbName, '-Q', "INSERT ops.SchemaVersion (Version, ScriptName) VALUES ('$version', '$($_.Name)')")
    } else { Write-Host "    skip     $($_.Name)" }
}

Write-Host '==> Repeatable scripts'
Get-ChildItem "$Dir\programmable\R*.sql" | Sort-Object Name | ForEach-Object {
    Write-Host "    $($_.Name)"; Run @('-d', $DbName, '-i', $_.FullName)
}

if ($env:APP_PASSWORD -and $env:INTEG_PASSWORD -and $env:RPT_PASSWORD) {
    Write-Host '==> Logins and users'
    Run @('-d','master','-i', "$Dir\post-deploy\logins.sql", '-v', "DbName=$DbName",
          "AppPassword=$($env:APP_PASSWORD)", "IntegPassword=$($env:INTEG_PASSWORD)", "RptPassword=$($env:RPT_PASSWORD)")
}

if ($env:SEED_ROWS -and (Query 'SELECT COUNT(*) FROM core.ServiceRequest') -eq '0') {
    Write-Host "==> Seeding $($env:SEED_ROWS) demo requests"
    Run @('-d', $DbName, '-i', "$Dir\ops\seed_demo_data.sql", '-v', "RequestCount=$($env:SEED_ROWS)")
    Run @('-d', $DbName, '-Q', 'EXEC ops.usp_Warehouse_Load')
}
Write-Host "==> Deployed. Schema version: $(Query 'SELECT MAX(Version) FROM ops.SchemaVersion')"
