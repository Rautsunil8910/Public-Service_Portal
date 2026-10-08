using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Identity;
using Microsoft.AspNetCore.Mvc;
using ServicePortal.Shared;
using ServicePortal.Web.Data;
using ServicePortal.Web.Models;
using ServicePortal.Web.Security;

namespace ServicePortal.Web.Controllers;

/// <summary>Access administration, privacy audit, error log and integration monitoring.</summary>
[Authorize]
public sealed class AdminController(SqlDb db) : Controller
{
    private static readonly PasswordHasher<object> Hasher = new();

    // ---------- Users & passwords ----------
    [HttpGet, Authorize(Policy = Policies.AdminUsers)]
    public async Task<IActionResult> Users(int? edit)
    {
        var users = await db.QueryAsync<StaffUser>("app.usp_User_List");
        var editing = edit is null ? null : users.FirstOrDefault(u => u.UserId == edit);
        var form = editing is null ? new UserForm() : new UserForm
        {
            UserId = editing.UserId,
            UserName = editing.UserName,
            DisplayName = editing.DisplayName,
            RoleCode = editing.RoleCode,
            DepartmentId = editing.DepartmentId,
            IsActive = editing.IsActive,
        };
        return View(new UsersViewModel { Users = users, Departments = await db.QueryAsync<Department>("app.usp_Lookup_Departments"), Form = form });
    }

    [HttpPost, Authorize(Policy = Policies.AdminUsers)]
    public async Task<IActionResult> SaveUser([Bind(Prefix = "Form")] UserForm form)
    {
        if (form.UserId is null && string.IsNullOrEmpty(form.NewPassword))
            ModelState.AddModelError("Form.NewPassword", "A password is required for a new account.");
        if (!string.IsNullOrEmpty(form.NewPassword))
            foreach (var problem in PasswordPolicy.Validate(form.NewPassword, form.UserName))
                ModelState.AddModelError("Form.NewPassword", problem);

        if (ModelState.IsValid)
        {
            try
            {
                await db.QuerySingleAsync<int>("app.usp_User_Save", new
                {
                    form.UserId,
                    UserName = form.UserName.Trim(),
                    DisplayName = form.DisplayName.Trim(),
                    form.RoleCode,
                    form.DepartmentId,
                    form.IsActive,
                    PasswordHash = string.IsNullOrEmpty(form.NewPassword) ? null : Hasher.HashPassword(new object(), form.NewPassword),
                });
                TempData["Success"] = $"Saved {form.UserName}. Role changes apply at the user's next sign-in.";
                return RedirectToAction(nameof(Users));
            }
            catch (DbRuleException ex) when (ex.IsUserFixable)
            {
                ModelState.AddModelError("", ex.Message);
            }
        }

        return View(nameof(Users), new UsersViewModel
        {
            Users = await db.QueryAsync<StaffUser>("app.usp_User_List"),
            Departments = await db.QueryAsync<Department>("app.usp_Lookup_Departments"),
            Form = form,
        });
    }

    [HttpPost, Authorize(Policy = Policies.AdminUsers)]
    public async Task<IActionResult> Unlock(int userId)
    {
        await db.ExecuteAsync("app.usp_User_Unlock", new { UserId = userId });
        TempData["Success"] = "Account unlocked.";
        return RedirectToAction(nameof(Users));
    }

    // ---------- Screen permissions matrix ----------
    [HttpGet, Authorize(Policy = Policies.AdminScreens)]
    public async Task<IActionResult> Screens() => View(await db.QueryAsync<RoleScreenCell>("app.usp_RoleScreen_Matrix"));

    [HttpPost, Authorize(Policy = Policies.AdminScreens)]
    public async Task<IActionResult> SetScreen(string roleCode, string screenCode, bool granted)
    {
        try
        {
            await db.ExecuteAsync("app.usp_RoleScreen_Set", new { RoleCode = roleCode, ScreenCode = screenCode, Granted = granted });
            TempData["Success"] = $"{(granted ? "Granted" : "Removed")} {screenCode} for {roleCode}. Users get the change at next sign-in.";
        }
        catch (DbRuleException ex) when (ex.IsUserFixable)
        {
            TempData["Error"] = ex.Message;
        }
        return RedirectToAction(nameof(Screens));
    }

    // ---------- Privacy (MFIPPA) audit + change history ----------
    [HttpGet, Authorize(Policy = Policies.AdminAudit)]
    public async Task<IActionResult> Audit(int? residentId)
    {
        ViewBag.ResidentId = residentId;
        return View(await db.QueryAsync<AccessAuditRow>("app.usp_Audit_PersonalInfoAccess_List", new { ResidentId = residentId, Top = 200 }));
    }

    [HttpGet, Authorize(Policy = Policies.AdminAudit)]
    public async Task<IActionResult> History(int id)
    {
        ViewBag.RequestId = id;
        return View(await db.QueryAsync<RequestVersionRow>("app.usp_ServiceRequest_History", new { RequestId = id }));
    }

    // ---------- Support ----------
    [HttpGet, Authorize(Policy = Policies.AdminErrors)]
    public async Task<IActionResult> Errors() => View(await db.QueryAsync<ErrorRow>("app.usp_Error_List", new { Top = 100 }));

    [HttpGet, Authorize(Policy = Policies.AdminIntegration)]
    public async Task<IActionResult> Integration()
    {
        var model = await db.QueryMultipleAsync("app.usp_Integration_Status", null, async grid => new IntegrationViewModel
        {
            Summary = await grid.ReadFirstOrDefaultAsync<IntegrationSummary>() ?? new IntegrationSummary(),
            Log = (await grid.ReadAsync<IntegrationLogRow>()).ToList(),
        });
        return View(model);
    }

    [HttpPost, Authorize(Policy = Policies.AdminIntegration)]
    public async Task<IActionResult> Retry(int requestId)
    {
        try
        {
            await db.ExecuteAsync("app.usp_Integration_Retry", new { RequestId = requestId });
            TempData["Success"] = "Re-queued for the next integration cycle.";
        }
        catch (DbRuleException ex) when (ex.Kind == DbRuleKind.NotFound)
        {
            TempData["Error"] = ex.Message;
        }
        return RedirectToAction(nameof(Integration));
    }
}
