using System.Globalization;
using System.Xml;
using System.Xml.Linq;

namespace ServicePortal.Shared;

/// <summary>
/// XML contract between the portal and the Finance (ERP) system. The portal builds the
/// message in SQL (FOR XML PATH('CostPosting')); the ERP validates it with this class.
/// <example>
/// &lt;CostPosting&gt;
///   &lt;SourceReference&gt;SR-0000123&lt;/SourceReference&gt;&lt;SourceSystem&gt;PUBLIC-PORTAL&lt;/SourceSystem&gt;
///   &lt;CostCentre&gt;CC-4100&lt;/CostCentre&gt;&lt;DepartmentCode&gt;ROADS&lt;/DepartmentCode&gt;
///   &lt;Description&gt;Roads &gt; Pothole&lt;/Description&gt;&lt;Amount&gt;412.50&lt;/Amount&gt;
///   &lt;Currency&gt;CAD&lt;/Currency&gt;&lt;PostingDate&gt;2026-10-07&lt;/PostingDate&gt;
/// &lt;/CostPosting&gt;
/// </example>
/// </summary>
public sealed record CostPosting(
    string SourceReference,
    string SourceSystem,
    string CostCentre,
    string? DepartmentCode,
    string? Description,
    decimal Amount,
    string Currency,
    DateOnly PostingDate);

public sealed record CostPostingValidation(bool IsValid, IReadOnlyList<string> Errors, CostPosting? Posting);

public static class CostPostingXml
{
    public static CostPostingValidation Parse(string? xml, IReadOnlySet<string> knownCostCentres)
    {
        var errors = new List<string>();
        if (string.IsNullOrWhiteSpace(xml))
            return new(false, ["Empty message body."], null);

        XElement root;
        try
        {
            root = SafeParse(xml).Root!;
        }
        catch (XmlException ex)
        {
            return new(false, [$"Malformed XML: {ex.Message}"], null);
        }

        if (root.Name.LocalName != "CostPosting")
            return new(false, ["Root element must be <CostPosting>."], null);

        string? Text(string name) => root.Element(name)?.Value.Trim();

        var reference = Text("SourceReference");
        var system = Text("SourceSystem");
        var costCentre = Text("CostCentre");
        var currency = Text("Currency");

        if (string.IsNullOrEmpty(reference)) errors.Add("SourceReference is required.");
        if (string.IsNullOrEmpty(system)) errors.Add("SourceSystem is required.");
        if (string.IsNullOrEmpty(costCentre)) errors.Add("CostCentre is required.");
        else if (!knownCostCentres.Contains(costCentre)) errors.Add($"Unknown cost centre '{costCentre}'.");
        if (currency != "CAD") errors.Add("Currency must be CAD.");

        if (!decimal.TryParse(Text("Amount"), NumberStyles.Number, CultureInfo.InvariantCulture, out var amount) || amount <= 0)
            errors.Add("Amount must be a positive number.");
        else if (decimal.Round(amount, 2) != amount)
            errors.Add("Amount cannot have more than 2 decimal places.");

        if (!DateOnly.TryParseExact(Text("PostingDate"), "yyyy-MM-dd", CultureInfo.InvariantCulture, DateTimeStyles.None, out var date))
            errors.Add("PostingDate must be yyyy-MM-dd.");

        if (errors.Count > 0) return new(false, errors, null);

        return new(true, errors, new CostPosting(reference!, system!, costCentre!, Text("DepartmentCode"),
                                                 Text("Description"), amount, currency!, date));
    }

    /// <summary>Parses untrusted XML with DTDs prohibited and no resolver (prevents XXE / entity expansion).</summary>
    public static XDocument SafeParse(string xml)
    {
        var settings = new XmlReaderSettings { DtdProcessing = DtdProcessing.Prohibit, XmlResolver = null };
        using var reader = XmlReader.Create(new StringReader(xml), settings);
        return XDocument.Load(reader);
    }

    public static string Result(string documentNo, string sourceReference, bool duplicate) =>
        new XElement("PostingResult",
            new XElement("Status", duplicate ? "DUPLICATE" : "POSTED"),
            new XElement("DocumentNo", documentNo),
            new XElement("SourceReference", sourceReference)).ToString(SaveOptions.DisableFormatting);

    public static string Error(string status, IEnumerable<string> errors) =>
        new XElement("PostingResult",
            new XElement("Status", status),
            new XElement("Errors", errors.Select(e => new XElement("Error", e)))).ToString(SaveOptions.DisableFormatting);

    /// <summary>Reads DocumentNo from a successful ERP response; null if absent.</summary>
    public static string? ReadDocumentNo(string? responseXml)
    {
        if (string.IsNullOrWhiteSpace(responseXml)) return null;
        try { return SafeParse(responseXml).Root?.Element("DocumentNo")?.Value; }
        catch (XmlException) { return null; }
    }
}
