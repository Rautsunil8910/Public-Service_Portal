using System.Security.Claims;
using Microsoft.AspNetCore.Authentication;
using Microsoft.AspNetCore.Authentication.Cookies;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Identity;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.RateLimiting;
using ServicePortal.Shared;
using ServicePortal.Web.Data;
using ServicePortal.Web.Models;
using ServicePortal.Web.Security;

namespace ServicePortal.Web.Controllers;

[AllowAnonymous]
public sealed class AccountController(SqlDb db, ILogger<AccountController> log) : Controller
{
    private static readonly PasswordHasher<object> Hasher = new();
    private static readonly object HashUser = new();
    // Verifying against a dummy hash when the user does not exist keeps response times
    // the same, so attackers cannot discover valid user names by timing.
    private static readonly string DummyHash = Hasher.HashPassword(HashUser, Guid.NewGuid().ToString());

    [HttpGet]
    public IActionResult Login(string? returnUrl) => View(new LoginModel { ReturnUrl = returnUrl });

    [HttpPost, EnableRateLimiting("login")]
    public async Task<IActionResult> Login(LoginModel model)
    {
        if (!ModelState.IsValid) return View(model);

        var user = await db.QuerySingleAsync<LoginUser>("app.usp_User_GetForLogin", new { UserName = model.UserName.Trim() });
        if (user is null)
        {
            Hasher.VerifyHashedPassword(HashUser, DummyHash, model.Password);
            return LoginFailed(model);
        }

        if (user.IsLocked)
        {
            ModelState.AddModelError("", "This account is temporarily locked after repeated failed sign-ins. Try again in 15 minutes or call the IT service desk.");
            return View(model);
        }

        var result = Hasher.VerifyHashedPassword(HashUser, user.PasswordHash, model.Password);
        if (result == PasswordVerificationResult.Failed || !user.IsActive)
        {
            if (user.IsActive) await db.ExecuteAsync("app.usp_User_RecordLogin", new { user.UserId, Succeeded = false });
            log.LogWarning("Failed sign-in for {UserName}", user.UserName);
            return LoginFailed(model);
        }

        await db.ExecuteAsync("app.usp_User_RecordLogin", new { user.UserId, Succeeded = true });
        var screens = await db.QueryAsync<string>("app.usp_Screen_ListForRole", new { user.RoleCode });

        var claims = new List<Claim>
        {
            new(ClaimTypes.NameIdentifier, user.UserId.ToString()),
            new(ClaimTypes.Name, user.UserName),
            new(ClaimTypes.Role, user.RoleCode),
            new("display", user.DisplayName),
        };
        claims.AddRange(screens.Select(s => new Claim(Screens.ClaimType, s)));

        await HttpContext.SignInAsync(CookieAuthenticationDefaults.AuthenticationScheme,
            new ClaimsPrincipal(new ClaimsIdentity(claims, CookieAuthenticationDefaults.AuthenticationScheme)));
        log.LogInformation("{UserName} signed in as {Role}", user.UserName, user.RoleCode);

        return Url.IsLocalUrl(model.ReturnUrl) ? LocalRedirect(model.ReturnUrl!) : RedirectToAction("Index", "Home");
    }

    private ViewResult LoginFailed(LoginModel model)
    {
        ModelState.AddModelError("", "Incorrect user name or password.");
        model.Password = "";
        return View(model);
    }

    [HttpGet]
    public async Task<IActionResult> Register() =>
        View(new RegisterModel { Municipalities = await db.QueryAsync<Municipality>("app.usp_Lookup_Municipalities") });

    [HttpPost, EnableRateLimiting("login")]
    public async Task<IActionResult> Register(RegisterModel model)
    {
        foreach (var problem in PasswordPolicy.Validate(model.Password, model.Email))
            ModelState.AddModelError(nameof(model.Password), problem);

        if (ModelState.IsValid)
        {
            try
            {
                await db.QuerySingleAsync<int>("app.usp_Resident_Register", new
                {
                    model.FirstName,
                    model.LastName,
                    Email = model.Email.Trim().ToLowerInvariant(),
                    model.Phone,
                    model.StreetAddress,
                    model.MunicipalityId,
                    PasswordHash = Hasher.HashPassword(HashUser, model.Password),
                });
                TempData["Success"] = "Your account has been created. Please sign in.";
                return RedirectToAction(nameof(Login));
            }
            catch (DbRuleException ex) when (ex.IsUserFixable)
            {
                ModelState.AddModelError("", ex.Message);
            }
        }

        model.Municipalities = await db.QueryAsync<Municipality>("app.usp_Lookup_Municipalities");
        return View(model);
    }

    [HttpPost, Authorize]
    public async Task<IActionResult> Logout()
    {
        await HttpContext.SignOutAsync(CookieAuthenticationDefaults.AuthenticationScheme);
        return RedirectToAction(nameof(Login));
    }

    [HttpGet]
    public IActionResult AccessDenied() => View("AccessDenied");
}
