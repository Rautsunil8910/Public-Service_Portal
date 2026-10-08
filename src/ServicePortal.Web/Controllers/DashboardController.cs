using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using ServicePortal.Web.Data;
using ServicePortal.Web.Models;
using ServicePortal.Web.Security;

namespace ServicePortal.Web.Controllers;

[Authorize(Policy = Policies.Dashboard)]
public sealed class DashboardController(SqlDb db) : Controller
{
    public async Task<IActionResult> Index()
    {
        var model = await db.QueryMultipleAsync("app.usp_Dashboard_Summary", null, async grid => new DashboardViewModel
        {
            Kpis = await grid.ReadFirstOrDefaultAsync<DashboardKpis>() ?? new DashboardKpis(),
            ByStatus = (await grid.ReadAsync<StatusCount>()).ToList(),
            ByDepartment = (await grid.ReadAsync<DepartmentLoad>()).ToList(),
            TopCategories = (await grid.ReadAsync<CategoryCount>()).ToList(),
        });
        return View(model);
    }
}
