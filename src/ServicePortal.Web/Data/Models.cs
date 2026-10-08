namespace ServicePortal.Web.Data;

// Row shapes returned by stored procedures (Dapper maps columns to properties by name).

public sealed class LoginUser
{
    public int UserId { get; init; }
    public string UserName { get; init; } = "";
    public string DisplayName { get; init; } = "";
    public string PasswordHash { get; init; } = "";
    public string RoleCode { get; init; } = "";
    public bool IsActive { get; init; }
    public bool IsLocked { get; init; }
    public DateTime? LockedUntilUtc { get; init; }
}

public sealed record Lookup(int Id, string Name);

public sealed class CategoryOption
{
    public int CategoryId { get; init; }
    public string PathName { get; init; } = "";
    public byte SlaBusinessDays { get; init; }
}

public sealed class Municipality
{
    public byte MunicipalityId { get; init; }
    public string Name { get; init; } = "";
}

public sealed class Department
{
    public int DepartmentId { get; init; }
    public string Code { get; init; } = "";
    public string Name { get; init; } = "";
    public string? CostCentre { get; init; }
    public short OrgLevel { get; init; }
    public string OrgPath { get; init; } = "";
}

public sealed class Crew
{
    public int CrewId { get; init; }
    public string Name { get; init; } = "";
    public string DepartmentName { get; init; } = "";
}

public sealed class StatusOption
{
    public string StatusCode { get; init; } = "";
    public string DisplayName { get; init; } = "";
    public bool IsTerminal { get; init; }
}

public sealed class CreatedRequest
{
    public int RequestId { get; init; }
    public string RequestNumber { get; init; } = "";
    public DateTime DueDate { get; init; }
}

public sealed class RequestRow
{
    public int RequestId { get; init; }
    public string RequestNumber { get; init; } = "";
    public string Category { get; init; } = "";
    public string Department { get; init; } = "";
    public string Municipality { get; init; } = "";
    public string LocationText { get; init; } = "";
    public byte Priority { get; init; }
    public string StatusCode { get; init; } = "";
    public string StatusName { get; init; } = "";
    public DateTime SubmittedAtUtc { get; init; }
    public DateTime DueDate { get; init; }
    public bool IsOverdue { get; init; }
    public int TotalRows { get; init; }
}

public sealed class RequestDetail
{
    public int RequestId { get; init; }
    public string RequestNumber { get; init; } = "";
    public string Category { get; init; } = "";
    public int DepartmentId { get; init; }
    public string Department { get; init; } = "";
    public string Municipality { get; init; } = "";
    public string Channel { get; init; } = "";
    public byte Priority { get; init; }
    public string StatusCode { get; init; } = "";
    public string StatusName { get; init; } = "";
    public bool IsTerminal { get; init; }
    public string Description { get; init; } = "";
    public string LocationText { get; init; } = "";
    public string? AssignedCrew { get; init; }
    public DateTime SubmittedAtUtc { get; init; }
    public DateTime DueDate { get; init; }
    public DateTime? ClosedAtUtc { get; init; }
    public string? Resolution { get; init; }
    public decimal? CostAmount { get; init; }
    public string? CostCentre { get; init; }
    public DateTime? ErpPostedAtUtc { get; init; }
    public string? ErpDocumentNo { get; init; }
    public int? ResidentId { get; init; }
    public string? ResidentName { get; init; }
    public string? ResidentEmail { get; init; }   // masked by SQL Server Dynamic Data Masking
    public string? ResidentPhone { get; init; }   // masked
    public int? BusinessDaysOpen { get; init; }
    public bool IsOverdue { get; init; }
    public byte[] RowVer { get; init; } = [];
}

public sealed class RequestEvent
{
    public string? FromStatus { get; init; }
    public string ToStatus { get; init; } = "";
    public DateTime ChangedAtUtc { get; init; }
    public string? Note { get; init; }
    public string ChangedBy { get; init; } = "";
}

public sealed class TransitionOption
{
    public string ToStatus { get; init; } = "";
    public string DisplayName { get; init; } = "";
}

public sealed class ResidentContact
{
    public int ResidentId { get; init; }
    public string FirstName { get; init; } = "";
    public string LastName { get; init; } = "";
    public string? Email { get; init; }
    public string? Phone { get; init; }
    public string? StreetAddress { get; init; }
}

public sealed class PermitType
{
    public string PermitTypeCode { get; init; } = "";
    public string DisplayName { get; init; } = "";
    public decimal BaseFee { get; init; }
    public decimal RatePerThousand { get; init; }
    public decimal MinFee { get; init; }
    public decimal? MaxFee { get; init; }
}

public sealed class FeeQuote
{
    public string PermitTypeCode { get; init; } = "";
    public string DisplayName { get; init; } = "";
    public decimal BaseFee { get; init; }
    public decimal RatePerThousand { get; init; }
    public decimal MinFee { get; init; }
    public decimal? MaxFee { get; init; }
    public decimal Fee { get; init; }
}

public sealed class PermitRow
{
    public int PermitId { get; init; }
    public string PermitNumber { get; init; } = "";
    public string PermitType { get; init; } = "";
    public string PropertyAddress { get; init; } = "";
    public string WorkDescription { get; init; } = "";
    public decimal ProjectValue { get; init; }
    public decimal Fee { get; init; }
    public string StatusCode { get; init; } = "";
    public DateTime SubmittedAtUtc { get; init; }
    public DateTime? DecidedAtUtc { get; init; }
    public string? DecisionNote { get; init; }
    public string Applicant { get; init; } = "";
    public byte[] RowVer { get; init; } = [];
    public int TotalRows { get; init; }
}

public sealed class DashboardKpis
{
    public int OpenCount { get; init; }
    public int OverdueCount { get; init; }
    public int SubmittedLast7Days { get; init; }
    public int ClosedLast7Days { get; init; }
    public decimal? SlaCompliancePct90Days { get; init; }
}

public sealed class StatusCount
{
    public string StatusCode { get; init; } = "";
    public string DisplayName { get; init; } = "";
    public int RequestCount { get; init; }
}

public sealed class DepartmentLoad
{
    public string Department { get; init; } = "";
    public int OpenCount { get; init; }
    public int OverdueCount { get; init; }
}

public sealed class CategoryCount
{
    public string Category { get; init; } = "";
    public int RequestCount { get; init; }
}

public sealed class StaffUser
{
    public int UserId { get; init; }
    public string UserName { get; init; } = "";
    public string DisplayName { get; init; } = "";
    public string RoleCode { get; init; } = "";
    public string RoleName { get; init; } = "";
    public int? DepartmentId { get; init; }
    public string? DepartmentName { get; init; }
    public bool IsActive { get; init; }
    public bool IsLocked { get; init; }
    public DateTime? LastLoginUtc { get; init; }
    public DateTime PasswordChangedUtc { get; init; }
}

public sealed class RoleScreenCell
{
    public string RoleCode { get; init; } = "";
    public string RoleName { get; init; } = "";
    public string ScreenCode { get; init; } = "";
    public string ScreenName { get; init; } = "";
    public bool Granted { get; init; }
}

public sealed class AccessAuditRow
{
    public long AccessId { get; init; }
    public DateTime AccessedAtUtc { get; init; }
    public string UserName { get; init; } = "";
    public string DisplayName { get; init; } = "";
    public string RoleCode { get; init; } = "";
    public int ResidentId { get; init; }
    public string Purpose { get; init; } = "";
    public string? HostName { get; init; }
}

public sealed class ErrorRow
{
    public long ErrorId { get; init; }
    public string Source { get; init; } = "";
    public string Message { get; init; } = "";
    public string? Detail { get; init; }
    public string? UserName { get; init; }
    public string? CorrelationId { get; init; }
    public DateTime LoggedAtUtc { get; init; }
}

public sealed class IntegrationSummary
{
    public int? Pending { get; init; }
    public int? FailedPermanently { get; init; }
    public int? PostedLast24h { get; init; }
}

public sealed class IntegrationLogRow
{
    public long LogId { get; init; }
    public int RequestId { get; init; }
    public string RequestNumber { get; init; } = "";
    public byte AttemptNo { get; init; }
    public bool Succeeded { get; init; }
    public string? ErrorMessage { get; init; }
    public int? DurationMs { get; init; }
    public DateTime LoggedAtUtc { get; init; }
    public string? RequestXml { get; init; }
    public string? ResponseXml { get; init; }
}

public sealed class PendingPosting
{
    public int RequestId { get; init; }
    public string RequestNumber { get; init; } = "";
    public byte ErpAttempts { get; init; }
    public string PayloadXml { get; init; } = "";
}

// Report rows (also exported to Excel)
public sealed class SlaMonthRow
{
    public string YearMonth { get; init; } = "";
    public string DepartmentName { get; init; } = "";
    public int ClosedRequests { get; init; }
    public int MetSla { get; init; }
    public decimal SlaPct { get; init; }
    public decimal AvgBusinessDays { get; init; }
}

public sealed class OpenByDepartmentRow
{
    public string Department { get; init; } = "";
    public string Category { get; init; } = "";
    public string Status { get; init; } = "";
    public int OpenRequests { get; init; }
    public int Overdue { get; init; }
    public DateTime OldestSubmittedUtc { get; init; }
}

public sealed class PermitRevenueRow
{
    public byte Quarter { get; init; }
    public string PermitTypeName { get; init; } = "";
    public int PermitsIssued { get; init; }
    public decimal ConstructionValue { get; init; }
    public decimal FeeRevenue { get; init; }
}

public sealed class RequestVersionRow
{
    public string RequestNumber { get; init; } = "";
    public string StatusCode { get; init; } = "";
    public byte Priority { get; init; }
    public int? AssignedCrewId { get; init; }
    public decimal? CostAmount { get; init; }
    public string? ErpDocumentNo { get; init; }
    public DateTime ValidFrom { get; init; }
    public DateTime ValidTo { get; init; }
}
