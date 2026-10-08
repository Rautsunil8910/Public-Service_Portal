using System.ComponentModel.DataAnnotations;
using ServicePortal.Web.Data;

namespace ServicePortal.Web.Models;

public sealed class LoginModel
{
    [Required, Display(Name = "User name or email")] public string UserName { get; set; } = "";
    [Required, DataType(DataType.Password)] public string Password { get; set; } = "";
    public string? ReturnUrl { get; set; }
}

public sealed class RegisterModel
{
    [Required, StringLength(60), Display(Name = "First name")] public string FirstName { get; set; } = "";
    [Required, StringLength(60), Display(Name = "Last name")] public string LastName { get; set; } = "";
    [Required, EmailAddress, StringLength(254)] public string Email { get; set; } = "";
    [Phone, StringLength(25)] public string? Phone { get; set; }
    [StringLength(200), Display(Name = "Street address")] public string? StreetAddress { get; set; }
    [Required, Display(Name = "Municipality")] public byte? MunicipalityId { get; set; }
    [Required, DataType(DataType.Password)] public string Password { get; set; } = "";
    [Required, DataType(DataType.Password), Compare(nameof(Password)), Display(Name = "Confirm password")]
    public string ConfirmPassword { get; set; } = "";
    public List<Municipality> Municipalities { get; set; } = [];
}

public sealed class NewRequestModel
{
    [Required, Display(Name = "What is the problem?")] public int? CategoryId { get; set; }
    [Required, Display(Name = "Municipality")] public byte? MunicipalityId { get; set; }
    [Required, StringLength(200, MinimumLength = 3), Display(Name = "Location (address, intersection or landmark)")]
    public string LocationText { get; set; } = "";
    [Required, StringLength(2000, MinimumLength = 10), Display(Name = "Description")]
    public string Description { get; set; } = "";
    [Range(-90, 90)] public decimal? Latitude { get; set; }
    [Range(-180, 180)] public decimal? Longitude { get; set; }

    // Staff-only fields (phone / counter intake)
    public string Channel { get; set; } = "PHONE";
    [Range(1, 4)] public byte? Priority { get; set; }
    [StringLength(60), Display(Name = "Caller first name")] public string? CallerFirstName { get; set; }
    [StringLength(60), Display(Name = "Caller last name")] public string? CallerLastName { get; set; }
    [EmailAddress, StringLength(254), Display(Name = "Caller email")] public string? CallerEmail { get; set; }
    [Phone, StringLength(25), Display(Name = "Caller phone")] public string? CallerPhone { get; set; }

    public List<CategoryOption> Categories { get; set; } = [];
    public List<Municipality> Municipalities { get; set; } = [];
}

public sealed class QueueFilter
{
    public string? Status { get; set; } = "OPEN";
    public int? DepartmentId { get; set; }
    public byte? MunicipalityId { get; set; }
    public string? Search { get; set; }
    public bool OverdueOnly { get; set; }
    public int Page { get; set; } = 1;
}

public sealed class QueueViewModel
{
    public QueueFilter Filter { get; init; } = new();
    public List<RequestRow> Rows { get; init; } = [];
    public List<StatusOption> Statuses { get; init; } = [];
    public List<Department> Departments { get; init; } = [];
    public List<Municipality> Municipalities { get; init; } = [];
    public int PageSize { get; init; } = 25;
    public int TotalRows => Rows.FirstOrDefault()?.TotalRows ?? 0;
    public int TotalPages => Math.Max(1, (int)Math.Ceiling(TotalRows / (double)PageSize));
}

public sealed class RequestDetailViewModel
{
    public RequestDetail Request { get; init; } = new();
    public List<RequestEvent> Events { get; init; } = [];
    public List<TransitionOption> Transitions { get; init; } = [];
    public List<Crew> Crews { get; init; } = [];
    public string RowVersion => Convert.ToBase64String(Request.RowVer);
}

public sealed class TransitionForm
{
    public int RequestId { get; set; }
    [Required] public string ToStatus { get; set; } = "";
    [Required] public string RowVersion { get; set; } = "";
    [StringLength(1000)] public string? Note { get; set; }
    public int? CrewId { get; set; }
    [StringLength(1000)] public string? Resolution { get; set; }
    [Range(1, 4)] public byte? Priority { get; set; }
}

public sealed class CostForm
{
    public int RequestId { get; set; }
    [Required, Range(0, 1_000_000)] public decimal CostAmount { get; set; }
    [Required] public string RowVersion { get; set; } = "";
}

public sealed class ContactRequest
{
    public int ResidentId { get; set; }
    [Required, StringLength(200, MinimumLength = 10)] public string Purpose { get; set; } = "";
}

public sealed class NewPermitModel
{
    [Required, Display(Name = "Permit type")] public string PermitTypeCode { get; set; } = "";
    [Required, StringLength(200, MinimumLength = 5), Display(Name = "Property address")] public string PropertyAddress { get; set; } = "";
    [Required, StringLength(1000, MinimumLength = 10), Display(Name = "Describe the work")] public string WorkDescription { get; set; } = "";
    [Required, Range(0, 100_000_000), Display(Name = "Estimated construction value ($)")] public decimal? ProjectValue { get; set; }
    public List<PermitType> PermitTypes { get; set; } = [];
}

public sealed class PermitListViewModel
{
    public string? Status { get; init; }
    public List<PermitRow> Rows { get; init; } = [];
    public int Page { get; init; } = 1;
    public int PageSize { get; init; } = 25;
    public bool IsReviewer { get; init; }
    public int TotalPages => Math.Max(1, (int)Math.Ceiling((Rows.FirstOrDefault()?.TotalRows ?? 0) / (double)PageSize));
}

public sealed class PermitDecisionForm
{
    public int PermitId { get; set; }
    [Required] public string Decision { get; set; } = "";
    [Required] public string RowVersion { get; set; } = "";
    [StringLength(500)] public string? Note { get; set; }
}

public sealed class DashboardViewModel
{
    public DashboardKpis Kpis { get; init; } = new();
    public List<StatusCount> ByStatus { get; init; } = [];
    public List<DepartmentLoad> ByDepartment { get; init; } = [];
    public List<CategoryCount> TopCategories { get; init; } = [];
}

public sealed class ReportsViewModel
{
    public DateOnly From { get; init; }
    public DateOnly To { get; init; }
    public int Year { get; init; }
    public List<SlaMonthRow> Sla { get; init; } = [];
}

public sealed class UserForm
{
    public int? UserId { get; set; }
    [Required, StringLength(100), Display(Name = "User name")] public string UserName { get; set; } = "";
    [Required, StringLength(100), Display(Name = "Display name")] public string DisplayName { get; set; } = "";
    [Required, Display(Name = "Role")] public string RoleCode { get; set; } = "CLERK";
    [Display(Name = "Department")] public int? DepartmentId { get; set; }
    [Display(Name = "Active")] public bool IsActive { get; set; } = true;
    [DataType(DataType.Password), Display(Name = "New password")] public string? NewPassword { get; set; }
}

public sealed class UsersViewModel
{
    public List<StaffUser> Users { get; init; } = [];
    public List<Department> Departments { get; init; } = [];
    public UserForm Form { get; init; } = new();
}

public sealed class IntegrationViewModel
{
    public IntegrationSummary Summary { get; init; } = new();
    public List<IntegrationLogRow> Log { get; init; } = [];
}
