namespace ServicePortal.Web.Infrastructure;

/// <summary>Formatting helpers for views. The database stores UTC; staff see Eastern time.</summary>
public static class Display
{
    private static readonly TimeZoneInfo Eastern = TimeZoneInfo.FindSystemTimeZoneById("America/Toronto");

    public static DateTime ToLocal(this DateTime utc) =>
        TimeZoneInfo.ConvertTimeFromUtc(DateTime.SpecifyKind(utc, DateTimeKind.Utc), Eastern);

    public static string Local(this DateTime utc) => utc.ToLocal().ToString("yyyy-MM-dd HH:mm");

    public static string Local(this DateTime? utc) => utc is null ? "" : utc.Value.Local();

    public static string StatusCss(string status) => "status status-" + status.ToLowerInvariant().Replace('_', '-');

    public static string PriorityLabel(byte priority) => priority switch
    {
        1 => "1 – Urgent",
        2 => "2 – High",
        3 => "3 – Normal",
        _ => "4 – Low",
    };
}
