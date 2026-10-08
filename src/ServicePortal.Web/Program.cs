using System.Threading.RateLimiting;
using Microsoft.AspNetCore.Authentication.Cookies;
using Microsoft.AspNetCore.Mvc;
using ServicePortal.Web.Data;
using ServicePortal.Web.Infrastructure;
using ServicePortal.Web.Integration;
using ServicePortal.Web.Security;

var builder = WebApplication.CreateBuilder(args);

// ---------- MVC with global anti-forgery + DB rule error handling ----------
builder.Services.AddControllersWithViews(options =>
{
    options.Filters.Add(new AutoValidateAntiforgeryTokenAttribute());
    options.Filters.Add<DbRuleExceptionFilter>();
});

builder.Services.AddHttpContextAccessor();
builder.Services.AddSingleton<SqlDb>();
builder.Services.AddSingleton<ErrorLogger>();

// ---------- Authentication: cookie, hardened ----------
builder.Services.AddAuthentication(CookieAuthenticationDefaults.AuthenticationScheme)
    .AddCookie(options =>
    {
        options.LoginPath = "/Account/Login";
        options.AccessDeniedPath = "/Account/AccessDenied";
        options.Cookie.Name = "publicservice.portal";
        options.Cookie.HttpOnly = true;
        options.Cookie.SameSite = SameSiteMode.Strict;
        options.Cookie.SecurePolicy = CookieSecurePolicy.SameAsRequest;
        options.ExpireTimeSpan = TimeSpan.FromMinutes(30);
        options.SlidingExpiration = true;
    });

// ---------- Authorization: one policy per screen (screen-level security) ----------
builder.Services.AddAuthorization(options =>
{
    foreach (var screen in Screens.All)
        options.AddPolicy(Screens.PolicyPrefix + screen, policy =>
            policy.RequireAuthenticatedUser().RequireClaim(Screens.ClaimType, screen));
});

// ---------- Brute-force protection on sign-in ----------
builder.Services.AddRateLimiter(options =>
{
    options.RejectionStatusCode = StatusCodes.Status429TooManyRequests;
    options.AddPolicy("login", context => RateLimitPartition.GetFixedWindowLimiter(
        context.Connection.RemoteIpAddress?.ToString() ?? "unknown",
        _ => new FixedWindowRateLimiterOptions { PermitLimit = 10, Window = TimeSpan.FromMinutes(1) }));
});

// ---------- ERP integration ----------
builder.Services.Configure<ErpOptions>(builder.Configuration.GetSection("Erp"));
builder.Services.AddHttpClient("erp", (sp, client) =>
{
    var erp = builder.Configuration.GetSection("Erp").Get<ErpOptions>() ?? new ErpOptions();
    client.BaseAddress = new Uri(erp.BaseUrl.TrimEnd('/') + "/");
    client.Timeout = TimeSpan.FromSeconds(15);
    if (!string.IsNullOrEmpty(erp.ApiKey)) client.DefaultRequestHeaders.Add("X-Api-Key", erp.ApiKey);
});
builder.Services.AddHostedService<ErpPostingWorker>();
builder.Services.AddHostedService<DemoSeeder>();

builder.Services.AddHealthChecks();

var app = builder.Build();

if (!app.Environment.IsDevelopment())
{
    app.UseHsts();
}
app.UseExceptionHandler("/Home/Error");
app.UseStatusCodePagesWithReExecute("/Home/Status/{0}");
app.UseSecurityHeaders();
app.UseStaticFiles();
app.UseRouting();
app.UseRateLimiter();
app.UseAuthentication();
app.UseAuthorization();

app.MapHealthChecks("/health");
app.MapControllerRoute("default", "{controller=Home}/{action=Index}/{id?}");

app.Run();
