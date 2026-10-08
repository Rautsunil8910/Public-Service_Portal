using ServicePortal.Shared;
using Xunit;

namespace ServicePortal.Tests;

public class CostPostingXmlTests
{
    private static readonly HashSet<string> CostCentres = ["CC-4100", "CC-5100"];

    private static string Message(string costCentre = "CC-4100", string amount = "412.50", string date = "2026-10-07", string currency = "CAD") =>
        $"<CostPosting><SourceReference>SR-0000123</SourceReference><SourceSystem>PUBLIC-PORTAL</SourceSystem>" +
        $"<CostCentre>{costCentre}</CostCentre><DepartmentCode>ROADS</DepartmentCode><Description>Roads &gt; Pothole</Description>" +
        $"<Amount>{amount}</Amount><Currency>{currency}</Currency><PostingDate>{date}</PostingDate></CostPosting>";

    [Fact]
    public void Valid_message_is_parsed()
    {
        var result = CostPostingXml.Parse(Message(), CostCentres);

        Assert.True(result.IsValid);
        Assert.Equal("SR-0000123", result.Posting!.SourceReference);
        Assert.Equal(412.50m, result.Posting.Amount);
        Assert.Equal(new DateOnly(2026, 10, 7), result.Posting.PostingDate);
        Assert.Equal("Roads > Pothole", result.Posting.Description);
    }

    [Theory]
    [InlineData("CC-9999", "412.50", "2026-10-07", "CAD", "Unknown cost centre")]
    [InlineData("CC-4100", "-5", "2026-10-07", "CAD", "Amount must be a positive number")]
    [InlineData("CC-4100", "10.555", "2026-10-07", "CAD", "decimal places")]
    [InlineData("CC-4100", "10.00", "07/10/2026", "CAD", "PostingDate")]
    [InlineData("CC-4100", "10.00", "2026-10-07", "USD", "Currency")]
    public void Invalid_fields_are_rejected(string costCentre, string amount, string date, string currency, string expected)
    {
        var result = CostPostingXml.Parse(Message(costCentre, amount, date, currency), CostCentres);

        Assert.False(result.IsValid);
        Assert.Contains(result.Errors, e => e.Contains(expected));
    }

    [Theory]
    [InlineData("")]
    [InlineData("not xml")]
    [InlineData("<Other/>")]
    public void Malformed_or_wrong_documents_are_rejected(string xml) =>
        Assert.False(CostPostingXml.Parse(xml, CostCentres).IsValid);

    [Fact]
    public void Xml_with_a_DTD_is_rejected()
    {
        const string xxe = "<!DOCTYPE x [<!ENTITY e SYSTEM \"file:///etc/passwd\">]><CostPosting>&e;</CostPosting>";
        Assert.False(CostPostingXml.Parse(xxe, CostCentres).IsValid);
    }

    [Fact]
    public void Document_number_is_read_from_result()
    {
        var xml = CostPostingXml.Result("FI-2026-000042", "SR-0000123", duplicate: false);
        Assert.Equal("FI-2026-000042", CostPostingXml.ReadDocumentNo(xml));
        Assert.Null(CostPostingXml.ReadDocumentNo(CostPostingXml.Error("UNAVAILABLE", ["down"])));
        Assert.Null(CostPostingXml.ReadDocumentNo("<<garbage"));
    }
}
