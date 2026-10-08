using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using ServicePortal.Web.Data;
using ServicePortal.Web.Models;
using ServicePortal.Web.Reporting;
using ServicePortal.Web.Security;

namespace ServicePortal.Web.Controllers;

/// <summary>
/// Operational reports read from the rpt star schema (refreshed nightly) and live tables.
/// The same views back the SSRS paginated reports in /reports.
/// Supervisors only ever see their own branch of the organisation.
/// </summary>
[Authorize(Policy = Policies.Reports)]
public sealed class ReportsController(SqlDb db) : Controller
{
    public async Task<IActionResult> Index(DateOnly? from, DateOnly? to, int? year)
    {
        var (f, t) = Range(from, to);
        var rows = await db.QueryAsync<SlaMonthRow>("app.usp_Report_SlaByMonth", new { FromDate = f.ToDateTime(TimeOnly.MinValue), ToDate = t.ToDateTime(TimeOnly.MinValue) });
        return View(new ReportsViewModel { From = f, To = t, Year = year ?? DateTime.Today.Year, Sla = rows });
    }

    public async Task<IActionResult> ExportSla(DateOnly? from, DateOnly? to)
    {
        var (f, t) = Range(from, to);
        var rows = await db.QueryAsync<SlaMonthRow>("app.usp_Report_SlaByMonth", new { FromDate = f.ToDateTime(TimeOnly.MinValue), ToDate = t.ToDateTime(TimeOnly.MinValue) });
        var bytes = ExcelExporter.Build(rows, "SLA Compliance", "Service request SLA compliance by month", $"Closed between {f:yyyy-MM-dd} and {t:yyyy-MM-dd}");
        return File(bytes, ExcelExporter.ContentType, $"sla-compliance-{f:yyyyMMdd}-{t:yyyyMMdd}.xlsx");
    }

    public async Task<IActionResult> ExportOpen()
    {
        var rows = await db.QueryAsync<OpenByDepartmentRow>("app.usp_Report_OpenByDepartment");
        var bytes = ExcelExporter.Build(rows, "Open Requests", "Open service requests by department and category");
        return File(bytes, ExcelExporter.ContentType, $"open-requests-{DateTime.Today:yyyyMMdd}.xlsx");
    }

    public async Task<IActionResult> ExportPermits(int? year)
    {
        var y = year ?? DateTime.Today.Year;
        var rows = await db.QueryAsync<PermitRevenueRow>("app.usp_Report_PermitRevenue", new { Year = (short)y });
        var bytes = ExcelExporter.Build(rows, "Permit Revenue", $"Building permit revenue by quarter, {y}");
        return File(bytes, ExcelExporter.ContentType, $"permit-revenue-{y}.xlsx");
    }

    private static (DateOnly From, DateOnly To) Range(DateOnly? from, DateOnly? to)
    {
        var t = to ?? DateOnly.FromDateTime(DateTime.Today);
        var f = from ?? new DateOnly(t.Year, t.Month, 1).AddMonths(-11);
        return f <= t ? (f, t) : (t, f);
    }
}
