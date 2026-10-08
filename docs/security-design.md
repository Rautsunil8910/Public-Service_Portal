# Security design

The goal: a resident's personal information and each department's work are only visible to the people who need them, and that holds even if one layer has a bug.

## Five layers (JD duty 2)

| Layer | Mechanism | Where |
|---|---|---|
| **Screen** | `sec.RoleScreen` maps roles to screens. At sign-in, permitted screens become claims; each controller action requires a matching authorization policy; menus only show permitted screens. **Every procedure re-checks** with `ops.usp_AssertScreen`, so a crafted HTTP request still fails in the database. Admins change the matrix on the *Screen permissions* page, with no deployment needed. | `V002`, `R01`, `Security/Screens.cs` |
| **Field** | Dynamic Data Masking on `Resident.Email`, `Phone`, `StreetAddress`. No application login has `UNMASK`. The only unmasked path is `app.usp_Resident_GetContact` (`EXECUTE AS OWNER`), which checks the screen permission, requires a written purpose, and writes `audit.PersonalInfoAccess`. | `V003`, `R03` |
| **Table** | Application logins are members of roles with `EXECUTE` on one schema and `DENY SELECT/INSERT/UPDATE/DELETE` on all data schemas. Procedures still work through ownership chaining (same owner, `dbo`). The reporting login can only `SELECT` from the `rpt` star schema, which holds no personal information. | `V003` |
| **Row** | Row-Level Security policy `sec.RowAccessPolicy`. Clerks/admins see all requests; supervisors see their department **and every unit below it** (`hierarchyid.IsDescendantOf`); residents see only their own requests and permits. A BLOCK predicate stops updates that would move a row outside the user's scope. | `V003` |
| **Process** | Workflow transitions are data (`core.StatusTransition`: from, to, role). `usp_ServiceRequest_Transition` rejects anything not listed, checks a `rowversion` for concurrent edits, and records an event, all in one transaction. | `V002`, `R03` |

## How the user's identity reaches the database

The web app connects with one low-privilege login (`portal_app`), so SQL Server would not otherwise know which person is acting. After opening each connection for a signed-in user, the app calls `app.usp_Session_Set @UserId`, which looks up the user's role, department and resident ID and stores them with `sp_set_session_context ... @read_only = 1`. They cannot be changed for the life of that connection (tested in `T03`). Connection pooling resets session context between uses.

Trade-off: the app login is trusted to pass the correct user ID. That is the same trust boundary as any application using a pooled service account. The difference here is that the database still enforces *what that user may do*.

## Separate logins per component

| Login | Role | Can do |
|---|---|---|
| `portal_app` | `app_executor` | Execute `app.*` procedures |
| `portal_integration` | `integ_executor` | Execute `integ.*` procedures (read pending costs, record results) |
| `portal_reports` | `rpt_reader` | `SELECT` on `rpt.*` (warehouse; no personal information) |

Passwords come from pipeline secrets via `post-deploy/logins.sql`, never from source control.

## Authentication

- Passwords hashed with ASP.NET Core Identity's PBKDF2 `PasswordHasher`; the database only ever stores the hash.
- Password policy: 10+ characters, upper, lower, digit, must not contain the user name.
- Lockout: 5 consecutive failures lock the account for 15 minutes (`usp_User_RecordLogin`); admins can unlock.
- Login and registration are rate-limited per IP (10/minute).
- Unknown user names still run a hash verification, so response timing does not reveal which accounts exist.
- Cookies are HttpOnly, SameSite=Strict, 30-minute sliding expiry. All POSTs require an anti-forgery token.
- Security headers on every response, including a Content-Security-Policy with no inline script or style.

## MFIPPA

- Collection notice on registration.
- Masked by default; purpose-logged reveal; *Privacy audit* screen lists who viewed whose information, when and why.
- Temporal tables (`audit.ResidentHistory`, `audit.ServiceRequestHistory`) keep every prior version of a row for accountability and correction requests.
- Reporting warehouse excludes personal information entirely.

## Integration

- ERP calls carry an API key header (a production system would use OAuth client credentials or mutual TLS).
- XML from outside is parsed with DTDs prohibited and no resolver (prevents XXE), covered by a unit test.
