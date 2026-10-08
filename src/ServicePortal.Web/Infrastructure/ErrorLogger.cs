using System.Data;
using Dapper;
using Microsoft.Data.SqlClient;

namespace ServicePortal.Web.Infrastructure;

/// <summary>
/// Writes unexpected errors to ops.ErrorLog (visible on the Admin > Error log screen) with a
/// correlation id shown to the user, so a support call can be matched to the exact failure.
/// Uses its own connection without a user session so logging still works when the session fails.
/// </summary>
public sealed class ErrorLogger(IConfiguration configuration, ILogger<ErrorLogger> logger)
{
    public async Task LogAsync(string source, Exception exception, string? userName, string correlationId)
    {
        logger.LogError(exception, "Unhandled error {CorrelationId} in {Source}", correlationId, source);
        try
        {
            await using var connection = new SqlConnection(configuration.GetConnectionString("Portal") ?? "");
            await connection.ExecuteAsync("app.usp_Error_Log", new
            {
                Source = source.Length > 100 ? source[..100] : source,
                Message = exception.Message,
                Detail = exception.ToString(),
                UserName = userName,
                CorrelationId = correlationId,
            }, commandType: CommandType.StoredProcedure);
        }
        catch (Exception logFailure)
        {
            // Never let logging failures hide the original error.
            logger.LogWarning(logFailure, "Could not write error {CorrelationId} to ops.ErrorLog", correlationId);
        }
    }
}
