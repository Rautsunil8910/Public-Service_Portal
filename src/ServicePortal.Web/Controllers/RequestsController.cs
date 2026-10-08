using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using ServicePortal.Shared;
using ServicePortal.Web.Data;
using ServicePortal.Web.Models;
using ServicePortal.Web.Security;

namespace ServicePortal.Web.Controllers;

[Authorize]
public sealed class RequestsController(SqlDb db) : Controller
{
    private const int PageSize = 25;

    // ---------- Submit ----------
    [HttpGet, Authorize(Policy = Policies.RequestSubmit)]
    public async Task<IActionResult> New() => View(await FillLookups(new NewRequestModel()));

    [HttpPost, Authorize(Policy = Policies.RequestSubmit)]
    public async Task<IActionResult> New(NewRequestModel model)
    {
        var isResident = User.IsInRole("RESIDENT");
        if (!isResident && string.IsNullOrWhiteSpace(model.CallerLastName) && !string.IsNullOrWhiteSpace(model.CallerEmail))
            ModelState.AddModelError(nameof(model.CallerLastName), "Enter the caller's last name with their email.");

        if (ModelState.IsValid)
        {
            try
            {
                var created = await db.QuerySingleAsync<CreatedRequest>("app.usp_ServiceRequest_Create", new
                {
                    model.CategoryId,
                    model.MunicipalityId,
                    model.Description,
                    model.LocationText,
                    model.Latitude,
                    model.Longitude,
                    Channel = isResident ? "WEB" : model.Channel,
                    model.Priority,
                    CallerFirstName = isResident ? null : model.CallerFirstName,
                    CallerLastName = isResident ? null : model.CallerLastName,
                    CallerEmail = isResident ? null : model.CallerEmail,
                    CallerPhone = isResident ? null : model.CallerPhone,
                });
                TempData["Success"] = $"Request {created!.RequestNumber} received. Target completion: {created.DueDate:dddd, MMMM d}.";
                return isResident ? RedirectToAction(nameof(Mine)) : RedirectToAction(nameof(Details), new { id = created.RequestId });
            }
            catch (DbRuleException ex) when (ex.IsUserFixable)
            {
                ModelState.AddModelError("", ex.Message);
            }
        }
        return View(await FillLookups(model));
    }

    private async Task<NewRequestModel> FillLookups(NewRequestModel model)
    {
        model.Categories = await db.QueryAsync<CategoryOption>("app.usp_Lookup_Categories");
        model.Municipalities = await db.QueryAsync<Municipality>("app.usp_Lookup_Municipalities");
        return model;
    }

    // ---------- Lists ----------
    [HttpGet, Authorize(Policy = Policies.RequestMy)]
    public async Task<IActionResult> Mine(int page = 1)
    {
        var rows = await db.QueryAsync<RequestRow>("app.usp_ServiceRequest_Search",
            new { StatusCode = (string?)null, PageNumber = page, PageSize });
        return View(new QueueViewModel { Rows = rows, Filter = new QueueFilter { Page = page, Status = null }, PageSize = PageSize });
    }

    [HttpGet, Authorize(Policy = Policies.RequestQueue)]
    public async Task<IActionResult> Queue([FromQuery] QueueFilter filter)
    {
        var rows = await db.QueryAsync<RequestRow>("app.usp_ServiceRequest_Search", new
        {
            StatusCode = string.IsNullOrEmpty(filter.Status) ? null : filter.Status,
            filter.DepartmentId,
            filter.MunicipalityId,
            SearchText = string.IsNullOrWhiteSpace(filter.Search) ? null : filter.Search.Trim(),
            filter.OverdueOnly,
            PageNumber = Math.Max(1, filter.Page),
            PageSize,
        });

        return View(new QueueViewModel
        {
            Filter = filter,
            Rows = rows,
            PageSize = PageSize,
            Statuses = await db.QueryAsync<StatusOption>("app.usp_Lookup_Statuses"),
            Departments = await db.QueryAsync<Department>("app.usp_Lookup_Departments"),
            Municipalities = await db.QueryAsync<Municipality>("app.usp_Lookup_Municipalities"),
        });
    }

    // ---------- Detail + workflow ----------
    [HttpGet]
    public async Task<IActionResult> Details(int id)
    {
        var model = await db.QueryMultipleAsync("app.usp_ServiceRequest_Get", new { RequestId = id }, async grid =>
        {
            var request = await grid.ReadFirstOrDefaultAsync<RequestDetail>();
            var events = (await grid.ReadAsync<RequestEvent>()).ToList();
            var transitions = (await grid.ReadAsync<TransitionOption>()).ToList();
            return (request, events, transitions);
        });

        if (model.request is null) return NotFound();

        var crews = model.transitions.Any(t => t.ToStatus == "ASSIGNED")
            ? await db.QueryAsync<Crew>("app.usp_Lookup_Crews", new { model.request.DepartmentId })
            : new List<Crew>();

        return View(new RequestDetailViewModel
        {
            Request = model.request,
            Events = model.events,
            Transitions = model.transitions,
            Crews = crews,
        });
    }

    [HttpPost]
    public async Task<IActionResult> Transition(TransitionForm form)
    {
        if (!ModelState.IsValid || !TryDecodeRowVersion(form.RowVersion, out var rowVer))
        {
            TempData["Error"] = "The form was incomplete. Please try again.";
            return RedirectToAction(nameof(Details), new { id = form.RequestId });
        }

        try
        {
            await db.ExecuteAsync("app.usp_ServiceRequest_Transition", new
            {
                form.RequestId,
                form.ToStatus,
                RowVer = rowVer,
                form.Note,
                form.CrewId,
                form.Resolution,
                form.Priority,
            });
            TempData["Success"] = $"Status changed to {form.ToStatus.Replace('_', ' ').ToLowerInvariant()}.";
        }
        catch (DbRuleException ex) when (ex.IsUserFixable)
        {
            TempData["Error"] = ex.Message;
        }
        return RedirectToAction(nameof(Details), new { id = form.RequestId });
    }

    [HttpPost, Authorize(Policy = Policies.RequestQueue)]
    public async Task<IActionResult> RecordCost(CostForm form)
    {
        if (ModelState.IsValid && TryDecodeRowVersion(form.RowVersion, out var rowVer))
        {
            try
            {
                await db.ExecuteAsync("app.usp_ServiceRequest_RecordCost", new { form.RequestId, form.CostAmount, RowVer = rowVer });
                TempData["Success"] = "Cost recorded. It will be posted to Finance after the request is closed.";
            }
            catch (DbRuleException ex) when (ex.IsUserFixable)
            {
                TempData["Error"] = ex.Message;
            }
        }
        else
        {
            TempData["Error"] = "Enter a cost between $0 and $1,000,000.";
        }
        return RedirectToAction(nameof(Details), new { id = form.RequestId });
    }

    /// <summary>
    /// Reveals unmasked contact details (called from JavaScript). The database checks the
    /// screen permission, requires a purpose, and writes the access to the privacy audit log.
    /// </summary>
    [HttpPost, Authorize(Policy = Policies.ResidentContact)]
    public async Task<IActionResult> Contact([FromBody] ContactRequest request)
    {
        if (!ModelState.IsValid)
            return BadRequest(new { error = "State the business purpose (at least 10 characters)." });
        try
        {
            var contact = await db.QuerySingleAsync<ResidentContact>("app.usp_Resident_GetContact",
                new { request.ResidentId, request.Purpose });
            return contact is null ? NotFound() : Json(contact);
        }
        catch (DbRuleException ex)
        {
            return ex.Kind == DbRuleKind.AccessDenied
                ? StatusCode(StatusCodes.Status403Forbidden, new { error = ex.Message })
                : BadRequest(new { error = ex.Message });
        }
    }

    private static bool TryDecodeRowVersion(string? value, out byte[] rowVer)
    {
        rowVer = [];
        if (string.IsNullOrEmpty(value)) return false;
        try
        {
            rowVer = Convert.FromBase64String(value);
            return rowVer.Length == 8;
        }
        catch (FormatException)
        {
            return false;
        }
    }

    internal static bool TryDecode(string? value, out byte[] rowVer) => TryDecodeRowVersion(value, out rowVer);
}
