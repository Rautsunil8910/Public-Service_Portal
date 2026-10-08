# Performance tuning record

Fill in this page with **your own measurements** from `database/ops/performance_tuning.sql`. Real numbers you measured are what make this a credible interview story; do not copy example figures.

## Setup

| Item | Value |
|---|---|
| Machine | (CPU / RAM / disk) |
| SQL Server version | `SELECT @@VERSION` |
| Rows in `core.ServiceRequest` | `SELECT COUNT(*) FROM core.ServiceRequest` |
| Query measured | `app.usp_Dashboard_Summary` as a Roads supervisor (RLS applied) |

## Before

The dashboard's "received last 7 days", "closed last 7 days" and "on time, last 90 days" tiles filter on `SubmittedAtUtc` and `ClosedAtUtc`, which have no index.

| Statement | Logical reads | CPU ms | Elapsed ms | Plan operator on ServiceRequest |
|---|---|---|---|---|
| Submitted last 7 days | | | | |
| Closed last 7 days | | | | |
| SLA % last 90 days | | | | |

Screenshot of the actual plan: `docs/img/plan-before.png`

## Change

```sql
CREATE INDEX IX_ServiceRequest_Closed ON core.ServiceRequest (ClosedAtUtc)
    INCLUDE (StatusCode, DueDate, DepartmentId, ResidentId) WHERE ClosedAtUtc IS NOT NULL;
CREATE INDEX IX_ServiceRequest_Submitted ON core.ServiceRequest (SubmittedAtUtc)
    INCLUDE (CategoryId, DepartmentId, ResidentId);
```

Why these columns: the key column is the range filter; the INCLUDE columns are everything the statements read **plus `DepartmentId` and `ResidentId`, because the Row-Level Security predicate reads them too**. Without them, every seek would need a key lookup. The filtered index on `ClosedAtUtc` skips the open requests, which never match the filter.

Cost: two more indexes to maintain on insert/update. The write rate here (a few thousand requests a day) makes that negligible. Check `user_updates` versus `user_seeks` in step 5 of the script after a week.

## After

| Statement | Logical reads | CPU ms | Elapsed ms | Plan operator |
|---|---|---|---|---|
| Submitted last 7 days | | | | |
| Closed last 7 days | | | | |
| SLA % last 90 days | | | | |

## Promotion

Saved as migration `V005__dashboard_indexes.sql` and promoted through Test to Prod by the pipeline, with the same review as any code change.

## Other performance choices already in the design

- `READ_COMMITTED_SNAPSHOT` on: report queries don't block clerks' updates.
- Business-day maths uses a running `BusinessDaySeq`, so "days between" is a subtraction, not a loop.
- Catch-all search uses `OPTION (RECOMPILE)` to avoid parameter-sniffing plans.
- Reporting reads a columnstore-indexed fact table, not the live tables.
- Query Store is enabled by `deploy.sh` to catch plan regressions.
