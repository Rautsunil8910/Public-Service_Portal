using System.Data;
using System.Security.Claims;
using Dapper;
using Microsoft.Data.SqlClient;
using ServicePortal.Shared;

namespace ServicePortal.Web.Data;

/// <summary>
/// The only way the web app talks to SQL Server: stored procedures, executed as the
/// low-privilege portal_app login. After opening a connection for a signed-in user it calls
/// app.usp_Session_Set, which pins that user's identity into read-only SESSION_CONTEXT
/// so Row-Level Security and the procedures' screen checks apply to them.
/// </summary>
public sealed class SqlDb
{
    private readonly string _connectionString;
    private readonly IHttpContextAccessor _http;

    public SqlDb(IConfiguration configuration, IHttpContextAccessor http)
    {
        _connectionString = configuration.GetConnectionString("Portal")
            ?? throw new InvalidOperationException("Connection string 'Portal' is not configured.");
        _http = http;
    }

    public async Task<SqlConnection> OpenAsync(int? actingUserId = null, CancellationToken ct = default)
    {
        var connection = new SqlConnection(_connectionString);
        try
        {
            await connection.OpenAsync(ct);
            var userId = actingUserId ?? CurrentUserId();
            if (userId is int id)
            {
                await Guard(() => connection.ExecuteAsync(new CommandDefinition(
                    "app.usp_Session_Set", new { UserId = id }, commandType: CommandType.StoredProcedure, cancellationToken: ct)));
            }
            return connection;
        }
        catch
        {
            await connection.DisposeAsync();
            throw;
        }
    }

    public async Task<List<T>> QueryAsync<T>(string procedure, object? args = null, int? actingUserId = null)
    {
        await using var connection = await OpenAsync(actingUserId);
        var rows = await Guard(() => connection.QueryAsync<T>(procedure, args, commandType: CommandType.StoredProcedure));
        return rows.AsList();
    }

    public async Task<T?> QuerySingleAsync<T>(string procedure, object? args = null, int? actingUserId = null)
    {
        await using var connection = await OpenAsync(actingUserId);
        return await Guard(() => connection.QueryFirstOrDefaultAsync<T>(procedure, args, commandType: CommandType.StoredProcedure));
    }

    public async Task ExecuteAsync(string procedure, object? args = null, int? actingUserId = null)
    {
        await using var connection = await OpenAsync(actingUserId);
        await Guard(() => connection.ExecuteAsync(procedure, args, commandType: CommandType.StoredProcedure));
    }

    /// <summary>For procedures returning several result sets.</summary>
    public async Task<T> QueryMultipleAsync<T>(string procedure, object? args, Func<SqlMapper.GridReader, Task<T>> read)
    {
        await using var connection = await OpenAsync();
        return await Guard(async () =>
        {
            using var grid = await connection.QueryMultipleAsync(procedure, args, commandType: CommandType.StoredProcedure);
            return await read(grid);
        });
    }

    private int? CurrentUserId()
    {
        var value = _http.HttpContext?.User.FindFirstValue(ClaimTypes.NameIdentifier);
        return int.TryParse(value, out var id) ? id : null;
    }

    /// <summary>Turns THROW 5000x from procedures into typed exceptions the controllers understand.</summary>
    private static async Task<T> Guard<T>(Func<Task<T>> action)
    {
        try
        {
            return await action();
        }
        catch (SqlException ex) when (DbRuleException.KindFromSqlErrorNumber(ex.Number) is DbRuleKind kind)
        {
            throw new DbRuleException(kind, ex.Message, ex);
        }
    }
}
