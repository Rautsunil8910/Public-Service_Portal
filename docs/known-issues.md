# Known issues and resolutions

Written in the same format used when raising a ticket with a vendor: what was observed, how to reproduce it, evidence, impact, and resolution or workaround.

---

## KI-001 – ERP returns HTTP 503 intermittently

| | |
|---|---|
| **Observed** | Some work-order cost postings fail with `ERP returned HTTP 503 Service Unavailable`. |
| **Reproduce** | Close a request with a recorded cost; watch *Admin > ERP integration*. About 1 in 10 first attempts fails (the mock ERP simulates outages, `Erp:SimulatedFailureRate`). |
| **Evidence** | `integ.ErpPostingLog` holds the exact request XML, the response XML (`<Status>UNAVAILABLE</Status>`), the attempt number and the duration. |
| **Impact** | None to residents or staff. Finance receives the posting on a later cycle. |
| **Resolution** | By design: the worker retries on each cycle up to 5 attempts. The ERP de-duplicates on `SourceReference`, so a retry after a timeout cannot double-post. Items that fail 5 times appear under *Needs attention* with a **Retry** button. |
| **Vendor ask (real system)** | Provide the outage window and the ERP's correlation ID for the listed `SourceReference` values. |

## KI-002 – Posting rejected: "Unknown cost centre"

| | |
|---|---|
| **Observed** | HTTP 422 with `<Error>Unknown cost centre 'CC-xxxx'.</Error>`. |
| **Cause** | A department's `CostCentre` in `core.Department` doesn't exist in Finance's chart of accounts (renamed or retired). |
| **Resolution** | Confirm the correct cost centre with Finance, update `core.Department.CostCentre` through a migration script, then use **Retry** for the affected requests. The cost centre is copied onto the request when the cost is recorded, so also correct `core.ServiceRequest.CostCentre` for requests not yet posted. |

## KI-003 – "This request was changed by someone else"

| | |
|---|---|
| **Observed** | User receives the message when updating a request. |
| **Cause** | Optimistic concurrency: the row's `rowversion` changed since the page loaded, because another user updated it. |
| **Resolution** | Expected behaviour that prevents silent overwrites. User reloads and re-applies their change. If it happens repeatedly for one request, check `core.ServiceRequestEvent` for an automated process updating it. |

## KI-004 – Supervisor can't see a request a clerk can see

| | |
|---|---|
| **Cause** | Row-Level Security: supervisors see their department and the units below it only. Either the request is in another department (wrong category chosen) or the supervisor's `DepartmentId` is wrong. |
| **Check** | `SELECT DepartmentId FROM core.ServiceRequest WHERE RequestId = ...` (as a DBA) and the user's department on *Admin > Users*. |
| **Resolution** | Fix the user's department, or have a clerk re-route the request. |

## KI-005 – Reports show yesterday's numbers

| | |
|---|---|
| **Cause** | Reports read the `rpt` warehouse, loaded nightly at 02:00. The dashboard and the "open requests" export are live. |
| **Check** | `SELECT TOP 5 * FROM ops.JobRun WHERE JobName = 'Warehouse_Load' ORDER BY JobRunId DESC` |
| **Resolution** | If the last run failed, the error is in `ops.JobRun.Message` and `ops.ErrorLog`. Fix the cause and run `EXEC ops.usp_Warehouse_Load` manually. |
