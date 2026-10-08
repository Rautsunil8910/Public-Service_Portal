namespace ServicePortal.Shared;

/// <summary>
/// Business-rule errors raised by stored procedures with THROW 5000x.
/// The numbers are the contract between the database and the web tier.
/// </summary>
public enum DbRuleKind
{
    AccessDenied = 50001,
    NotFound = 50002,
    InvalidTransition = 50003,
    Conflict = 50004,
    Validation = 50005,
}

public sealed class DbRuleException : Exception
{
    public DbRuleException(DbRuleKind kind, string message, Exception? inner = null) : base(message, inner) => Kind = kind;

    public DbRuleKind Kind { get; }

    /// <summary>Errors the user can fix by changing their input or reloading the page.</summary>
    public bool IsUserFixable => Kind is DbRuleKind.Validation or DbRuleKind.InvalidTransition or DbRuleKind.Conflict;

    /// <summary>Maps a SQL Server error number to a rule kind; null for unexpected errors.</summary>
    public static DbRuleKind? KindFromSqlErrorNumber(int number) =>
        Enum.IsDefined(typeof(DbRuleKind), number) ? (DbRuleKind)number : null;
}
