using System.Diagnostics;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Diagnostics;
using Microsoft.AspNetCore.Mvc;
using ServicePortal.Web.Infrastructure;
using ServicePortal.Web.Security;

namespace ServicePortal.Web.Controllers;

[AllowAnonymous]
public sealed class HomeController(ErrorLogger errorLogger) : Controller
{
    public IActionResult Index()
    {
        if (User.Identity?.IsAuthenticated != true) return View();
        if (User.CanSee(Screens.Dashboard)) return RedirectToAction("Index", "Dashboard");
        if (User.CanSee(Screens.RequestMy)) return RedirectToAction("Mine", "Requests");
        return View();
    }

    [IgnoreAntiforgeryToken]
    public async Task<IActionResult> Error()
    {
        var correlationId = Activity.Current?.Id ?? HttpContext.TraceIdentifier;
        var feature = HttpContext.Features.Get<IExceptionHandlerPathFeature>();
        if (feature?.Error is { } ex)
            await errorLogger.LogAsync(feature.Path, ex, User.Identity?.Name, correlationId);

        Response.StatusCode = StatusCodes.Status500InternalServerError;
        return View("Error", correlationId);
    }

    [IgnoreAntiforgeryToken]
    public IActionResult Status(int id) => id switch
    {
        StatusCodes.Status404NotFound => View("NotFound"),
        StatusCodes.Status403Forbidden => View("AccessDenied"),
        StatusCodes.Status429TooManyRequests => View("RuleError", "Too many attempts. Please wait a minute and try again."),
        _ => View("RuleError", $"The request could not be completed (HTTP {id})."),
    };
}
