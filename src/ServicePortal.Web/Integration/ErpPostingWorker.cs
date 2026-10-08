using System.Data;
using System.Diagnostics;
using System.Text;
using Dapper;
using Microsoft.Data.SqlClient;
using ServicePortal.Shared;
using ServicePortal.Web.Data;

namespace ServicePortal.Web.Integration;

public sealed class ErpOptions
{
    public bool Enabled { get; set; }
    public string BaseUrl { get; set; } = "http://localhost:5080";
    public string ApiKey { get; set; } = "";
    public int IntervalSeconds { get; set; } = 60;
    public int BatchSize { get; set; } = 50;
    public int MaxAttempts { get; set; } = 5;
}

/// <summary>
/// Background integration job: pushes the cost of closed work orders to the Finance/ERP system.
/// - Runs under its own SQL login (portal_integration) that can only execute integ.* procedures.
/// - The XML message is produced by SQL Server (FOR XML) and sent as-is.
/// - Every attempt (request + response XML, timing, error) is logged to integ.ErpPostingLog.
/// - Failures are retried on later cycles up to MaxAttempts; then they surface on the
///   Admin > ERP integration screen for a person to investigate and re-queue.
/// - The ERP treats SourceReference as an idempotency key, so a retry after an
///   ambiguous failure cannot double-post.
/// </summary>
public sealed class ErpPostingWorker(
    IConfiguration configuration,
    IHttpClientFactory httpClientFactory,
    Microsoft.Extensions.Options.IOptions<ErpOptions> options,
    ILogger<ErpPostingWorker> logger) : BackgroundService
{
    private readonly ErpOptions _options = options.Value;

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        if (!_options.Enabled)
        {
            logger.LogInformation("ERP posting worker disabled (Erp:Enabled = false).");
            return;
        }

        using var timer = new PeriodicTimer(TimeSpan.FromSeconds(Math.Max(10, _options.IntervalSeconds)));
        do
        {
            try
            {
                await RunCycleAsync(stoppingToken);
            }
            catch (Exception ex) when (ex is not OperationCanceledException)
            {
                logger.LogError(ex, "ERP posting cycle failed");
                await TryLogErrorAsync(ex);
            }
        }
        while (await timer.WaitForNextTickAsync(stoppingToken));
    }

    private async Task RunCycleAsync(CancellationToken ct)
    {
        await using var connection = await OpenAsync(ct);
        var pending = (await connection.QueryAsync<PendingPosting>(new CommandDefinition(
            "integ.usp_ErpPosting_GetPending",
            new { _options.BatchSize, MaxAttempts = (byte)_options.MaxAttempts },
            commandType: CommandType.StoredProcedure, cancellationToken: ct))).AsList();

        if (pending.Count == 0) return;
        logger.LogInformation("Posting {Count} work-order costs to ERP", pending.Count);

        var client = httpClientFactory.CreateClient("erp");
        foreach (var item in pending)
        {
            ct.ThrowIfCancellationRequested();
            var stopwatch = Stopwatch.StartNew();
            string? responseXml = null;
            string? error = null;
            string? documentNo = null;

            try
            {
                using var content = new StringContent(item.PayloadXml, Encoding.UTF8, "application/xml");
                using var response = await client.PostAsync("api/cost-postings", content, ct);
                responseXml = await response.Content.ReadAsStringAsync(ct);
                documentNo = CostPostingXml.ReadDocumentNo(responseXml);
                if (!response.IsSuccessStatusCode || documentNo is null)
                    error = $"ERP returned HTTP {(int)response.StatusCode} {response.ReasonPhrase}";
            }
            catch (Exception ex) when (ex is HttpRequestException or TaskCanceledException && !ct.IsCancellationRequested)
            {
                error = $"ERP unreachable: {ex.Message}";
            }

            stopwatch.Stop();
            await connection.ExecuteAsync(new CommandDefinition("integ.usp_ErpPosting_Record", new
            {
                item.RequestId,
                Succeeded = error is null,
                RequestPayload = item.PayloadXml,
                ResponsePayload = IsXml(responseXml) ? responseXml : null,
                ErpDocumentNo = documentNo,
                ErrorMessage = error,
                DurationMs = (int)stopwatch.ElapsedMilliseconds,
            }, commandType: CommandType.StoredProcedure, cancellationToken: ct));

            if (error is null)
                logger.LogInformation("{Request} posted as {DocumentNo}", item.RequestNumber, documentNo);
            else
                logger.LogWarning("{Request} attempt {Attempt} failed: {Error}", item.RequestNumber, item.ErpAttempts + 1, error);
        }
    }

    private async Task<SqlConnection> OpenAsync(CancellationToken ct)
    {
        var connection = new SqlConnection(configuration.GetConnectionString("Integration")
            ?? throw new InvalidOperationException("Connection string 'Integration' is not configured."));
        await connection.OpenAsync(ct);
        return connection;
    }

    private async Task TryLogErrorAsync(Exception ex)
    {
        try
        {
            await using var connection = await OpenAsync(CancellationToken.None);
            await connection.ExecuteAsync("integ.usp_Error_Log",
                new { Source = "ErpPostingWorker", Message = ex.Message, Detail = ex.ToString() },
                commandType: CommandType.StoredProcedure);
        }
        catch (Exception logEx)
        {
            logger.LogWarning(logEx, "Could not record integration error in the database");
        }
    }

    private static bool IsXml(string? text)
    {
        if (string.IsNullOrWhiteSpace(text)) return false;
        try { CostPostingXml.SafeParse(text); return true; }
        catch (System.Xml.XmlException) { return false; }
    }
}
