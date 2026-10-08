// Mock "Finance / ERP" service. Stands in for an SAP-style system so the portal's
// integration (service interface, XML messages, idempotency, retries) can be demonstrated.
using System.Collections.Concurrent;
using System.Xml.Linq;
using ServicePortal.Shared;

var builder = WebApplication.CreateBuilder(args);
builder.Services.AddSingleton<PostingLedger>();
var app = builder.Build();

var knownCostCentres = new HashSet<string>(
    app.Configuration.GetSection("Erp:CostCentres").Get<string[]>() ?? ["CC-4100", "CC-4200", "CC-5100", "CC-6100", "CC-6200"],
    StringComparer.OrdinalIgnoreCase);
var failureRate = app.Configuration.GetValue("Erp:SimulatedFailureRate", 0.10);
var apiKey = app.Configuration["Erp:ApiKey"];

// Simple shared-key authentication between systems (a real integration would use OAuth/mTLS).
app.Use(async (ctx, next) =>
{
    if (ctx.Request.Path.StartsWithSegments("/api") && !string.IsNullOrEmpty(apiKey) &&
        ctx.Request.Headers["X-Api-Key"] != apiKey)
    {
        ctx.Response.StatusCode = StatusCodes.Status401Unauthorized;
        return;
    }
    await next();
});

app.MapGet("/", () => "Mock ERP is running. POST XML to /api/cost-postings.");
app.MapGet("/health", () => Results.Ok(new { status = "ok" }));

app.MapGet("/api/cost-centres", () =>
    Results.Content(new XElement("CostCentres", knownCostCentres.Order().Select(c => new XElement("CostCentre", c))).ToString(),
                    "application/xml"));

app.MapPost("/api/cost-postings", async (HttpRequest request, PostingLedger ledger, ILogger<Program> log) =>
{
    using var reader = new StreamReader(request.Body);
    var body = await reader.ReadToEndAsync();

    var validation = CostPostingXml.Parse(body, knownCostCentres);
    if (!validation.IsValid)
    {
        log.LogWarning("Rejected posting: {Errors}", string.Join("; ", validation.Errors));
        return Results.Content(CostPostingXml.Error("REJECTED", validation.Errors), "application/xml", statusCode: 422);
    }

    var posting = validation.Posting!;

    // Idempotency: a retry of an already-posted reference returns the original document number,
    // so a network failure after posting can never double-charge a cost centre.
    if (ledger.TryGetExisting(posting.SourceReference, out var existing))
        return Results.Content(CostPostingXml.Result(existing, posting.SourceReference, duplicate: true), "application/xml");

    // Simulated outages so the portal's retry and error logging can be shown.
    if (Random.Shared.NextDouble() < failureRate)
    {
        log.LogWarning("Simulated outage for {Reference}", posting.SourceReference);
        return Results.Content(CostPostingXml.Error("UNAVAILABLE", ["ERP temporarily unavailable (simulated)."]),
                               "application/xml", statusCode: 503);
    }

    var documentNo = ledger.Post(posting);
    log.LogInformation("Posted {Reference} {Amount:C} to {CostCentre} as {DocumentNo}",
        posting.SourceReference, posting.Amount, posting.CostCentre, documentNo);
    return Results.Content(CostPostingXml.Result(documentNo, posting.SourceReference, duplicate: false), "application/xml");
});

app.MapGet("/api/cost-postings", (PostingLedger ledger) =>
    Results.Content(new XElement("CostPostings",
        ledger.All().Select(p => new XElement("CostPosting",
            new XAttribute("documentNo", p.DocumentNo),
            new XElement("SourceReference", p.Posting.SourceReference),
            new XElement("CostCentre", p.Posting.CostCentre),
            new XElement("Amount", p.Posting.Amount),
            new XElement("PostingDate", p.Posting.PostingDate.ToString("yyyy-MM-dd"))))).ToString(),
        "application/xml"));

app.Run();

internal sealed class PostingLedger
{
    private readonly ConcurrentDictionary<string, (string DocumentNo, CostPosting Posting)> _byReference = new(StringComparer.OrdinalIgnoreCase);
    private int _sequence;

    public bool TryGetExisting(string reference, out string documentNo)
    {
        var found = _byReference.TryGetValue(reference, out var entry);
        documentNo = found ? entry.DocumentNo : string.Empty;
        return found;
    }

    public string Post(CostPosting posting)
    {
        var entry = _byReference.GetOrAdd(posting.SourceReference, _ =>
            ($"FI-{DateTime.UtcNow:yyyy}-{Interlocked.Increment(ref _sequence):D6}", posting));
        return entry.DocumentNo;
    }

    public IEnumerable<(string DocumentNo, CostPosting Posting)> All() =>
        _byReference.Values.OrderBy(v => v.DocumentNo);
}
