using ClosedXML.Excel;

namespace ServicePortal.Web.Reporting;

/// <summary>One-click Excel exports: a titled sheet with a formatted, filterable table.</summary>
public static class ExcelExporter
{
    public const string ContentType = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet";

    public static byte[] Build<T>(IEnumerable<T> rows, string sheetName, string title, string? subtitle = null)
    {
        using var workbook = new XLWorkbook();
        var sheet = workbook.Worksheets.Add(sheetName);

        sheet.Cell(1, 1).Value = title;
        sheet.Cell(1, 1).Style.Font.SetBold().Font.SetFontSize(14);
        sheet.Cell(2, 1).Value = subtitle ?? $"Generated {DateTime.Now:yyyy-MM-dd HH:mm}";
        sheet.Cell(2, 1).Style.Font.SetItalic();

        var list = rows.ToList();
        if (list.Count == 0)
        {
            sheet.Cell(4, 1).Value = "No data for the selected period.";
        }
        else
        {
            var table = sheet.Cell(4, 1).InsertTable(list, sheetName.Replace(' ', '_'), true);
            table.Theme = XLTableTheme.TableStyleMedium2;
            foreach (var column in table.Columns())
            {
                var header = column.FirstCell().GetString();
                if (header.Contains("Pct")) column.Style.NumberFormat.Format = "0.0";
                else if (header.Contains("Revenue") || header.Contains("Value") || header.Contains("Cost"))
                    column.Style.NumberFormat.Format = "$#,##0.00";
                else if (header.EndsWith("Utc")) column.Style.DateFormat.Format = "yyyy-mm-dd hh:mm";
            }
        }

        sheet.Columns().AdjustToContents();
        sheet.SheetView.FreezeRows(4);

        using var stream = new MemoryStream();
        workbook.SaveAs(stream);
        return stream.ToArray();
    }
}
