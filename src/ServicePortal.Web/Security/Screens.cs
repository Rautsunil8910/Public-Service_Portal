using System.Security.Claims;

namespace ServicePortal.Web.Security;

/// <summary>
/// Screen codes match sec.Screen. At sign-in the user's permitted screens (sec.RoleScreen)
/// become "screen" claims; each controller action requires the matching policy. The stored
/// procedures re-check the same permission, so the UI is never the only line of defence.
/// </summary>
public static class Screens
{
    public const string ClaimType = "screen";

    public const string Dashboard = "DASHBOARD";
    public const string RequestSubmit = "REQUEST_SUBMIT";
    public const string RequestMy = "REQUEST_MY";
    public const string RequestQueue = "REQUEST_QUEUE";
    public const string RequestDetail = "REQUEST_DETAIL";
    public const string ResidentContact = "RESIDENT_CONTACT";
    public const string PermitSubmit = "PERMIT_SUBMIT";
    public const string PermitQueue = "PERMIT_QUEUE";
    public const string Reports = "REPORTS";
    public const string AdminUsers = "ADMIN_USERS";
    public const string AdminScreens = "ADMIN_SCREENS";
    public const string AdminAudit = "ADMIN_AUDIT";
    public const string AdminErrors = "ADMIN_ERRORS";
    public const string AdminIntegration = "ADMIN_INTEGRATION";

    public static readonly string[] All =
    [
        Dashboard, RequestSubmit, RequestMy, RequestQueue, RequestDetail, ResidentContact, PermitSubmit,
        PermitQueue, Reports, AdminUsers, AdminScreens, AdminAudit, AdminErrors, AdminIntegration,
    ];

    public const string PolicyPrefix = "Screen:";

    public static bool CanSee(this ClaimsPrincipal user, string screen) => user.HasClaim(ClaimType, screen);

    public static int? UserId(this ClaimsPrincipal user) =>
        int.TryParse(user.FindFirstValue(ClaimTypes.NameIdentifier), out var id) ? id : null;

    public static string DisplayName(this ClaimsPrincipal user) =>
        user.FindFirstValue("display") ?? user.Identity?.Name ?? "";
}

/// <summary>Policy names usable in [Authorize(Policy = ...)] attributes (must be compile-time constants).</summary>
public static class Policies
{
    public const string Dashboard = Screens.PolicyPrefix + Screens.Dashboard;
    public const string RequestSubmit = Screens.PolicyPrefix + Screens.RequestSubmit;
    public const string RequestMy = Screens.PolicyPrefix + Screens.RequestMy;
    public const string RequestQueue = Screens.PolicyPrefix + Screens.RequestQueue;
    public const string ResidentContact = Screens.PolicyPrefix + Screens.ResidentContact;
    public const string PermitSubmit = Screens.PolicyPrefix + Screens.PermitSubmit;
    public const string PermitQueue = Screens.PolicyPrefix + Screens.PermitQueue;
    public const string Reports = Screens.PolicyPrefix + Screens.Reports;
    public const string AdminUsers = Screens.PolicyPrefix + Screens.AdminUsers;
    public const string AdminScreens = Screens.PolicyPrefix + Screens.AdminScreens;
    public const string AdminAudit = Screens.PolicyPrefix + Screens.AdminAudit;
    public const string AdminErrors = Screens.PolicyPrefix + Screens.AdminErrors;
    public const string AdminIntegration = Screens.PolicyPrefix + Screens.AdminIntegration;
}
