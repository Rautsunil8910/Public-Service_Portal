using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using ServicePortal.Shared;
using ServicePortal.Web.Data;
using ServicePortal.Web.Models;
using ServicePortal.Web.Security;

namespace ServicePortal.Web.Controllers;

[Authorize]
public sealed class PermitsController(SqlDb db) : Controller
{
    private const int PageSize = 25;

    [HttpGet, Authorize(Policy = Policies.PermitSubmit)]
    public async Task<IActionResult> New() =>
        View(new NewPermitModel { PermitTypes = await db.QueryAsync<PermitType>("app.usp_Lookup_PermitTypes") });

    [HttpPost, Authorize(Policy = Policies.PermitSubmit)]
    public async Task<IActionResult> New(NewPermitModel model)
    {
        if (ModelState.IsValid)
        {
            try
            {
                // The fee shown in the browser is only an estimate; the database recalculates it.
                var permit = await db.QuerySingleAsync<PermitRow>("app.usp_Permit_Submit", new
                {
                    model.PermitTypeCode,
                    model.PropertyAddress,
                    model.WorkDescription,
                    model.ProjectValue,
                });
                TempData["Success"] = $"Application {permit!.PermitNumber} submitted. Fee due: {permit.Fee:C}.";
                return RedirectToAction(nameof(Index));
            }
            catch (DbRuleException ex) when (ex.IsUserFixable)
            {
                ModelState.AddModelError("", ex.Message);
            }
        }
        model.PermitTypes = await db.QueryAsync<PermitType>("app.usp_Lookup_PermitTypes");
        return View(model);
    }

    /// <summary>Live fee estimate for the application form (JavaScript).</summary>
    [HttpGet]
    public async Task<IActionResult> Fee(string type, decimal value)
    {
        try
        {
            var quote = await db.QuerySingleAsync<FeeQuote>("app.usp_Permit_CalculateFee",
                new { PermitTypeCode = type, ProjectValue = value });
            return quote is null ? NotFound() : Json(quote);
        }
        catch (DbRuleException ex)
        {
            return BadRequest(new { error = ex.Message });
        }
    }

    [HttpGet]
    public async Task<IActionResult> Index(string? status, int page = 1)
    {
        var isReviewer = User.CanSee(Screens.PermitQueue);
        if (!isReviewer && !User.CanSee(Screens.PermitSubmit)) return Forbid();

        var rows = await db.QueryAsync<PermitRow>("app.usp_Permit_Search",
            new { StatusCode = string.IsNullOrEmpty(status) ? null : status, PageNumber = Math.Max(1, page), PageSize });
        return View(new PermitListViewModel { Status = status, Rows = rows, Page = page, PageSize = PageSize, IsReviewer = isReviewer });
    }

    [HttpPost, Authorize(Policy = Policies.PermitQueue)]
    public async Task<IActionResult> Decide(PermitDecisionForm form, string? status, int page = 1)
    {
        if (!ModelState.IsValid || !RequestsController.TryDecode(form.RowVersion, out var rowVer))
        {
            TempData["Error"] = "The form was incomplete.";
        }
        else
        {
            try
            {
                await db.ExecuteAsync("app.usp_Permit_Decide", new { form.PermitId, form.Decision, RowVer = rowVer, form.Note });
                TempData["Success"] = $"Permit updated: {form.Decision.Replace('_', ' ').ToLowerInvariant()}.";
            }
            catch (DbRuleException ex) when (ex.IsUserFixable || ex.Kind == DbRuleKind.AccessDenied)
            {
                TempData["Error"] = ex.Message;
            }
        }
        return RedirectToAction(nameof(Index), new { status, page });
    }
}
