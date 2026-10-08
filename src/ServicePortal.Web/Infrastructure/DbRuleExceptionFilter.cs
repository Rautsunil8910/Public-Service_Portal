using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.Filters;
using Microsoft.AspNetCore.Mvc.ModelBinding;
using Microsoft.AspNetCore.Mvc.ViewFeatures;
using ServicePortal.Shared;

namespace ServicePortal.Web.Infrastructure;

/// <summary>
/// Converts database business-rule errors that a controller did not handle itself into
/// friendly pages: access denied -> 403, not found -> 404, anything else -> 400 with the message.
/// </summary>
public sealed class DbRuleExceptionFilter : IExceptionFilter
{
    public void OnException(ExceptionContext context)
    {
        if (context.Exception is not DbRuleException ex) return;

        var (view, status) = ex.Kind switch
        {
            DbRuleKind.AccessDenied => ("AccessDenied", StatusCodes.Status403Forbidden),
            DbRuleKind.NotFound => ("NotFound", StatusCodes.Status404NotFound),
            DbRuleKind.Conflict => ("RuleError", StatusCodes.Status409Conflict),
            _ => ("RuleError", StatusCodes.Status400BadRequest),
        };

        context.Result = new ViewResult
        {
            ViewName = view,
            StatusCode = status,
            ViewData = new ViewDataDictionary(new EmptyModelMetadataProvider(), new ModelStateDictionary())
            {
                ["Message"] = ex.Message,
            },
        };
        context.ExceptionHandled = true;
    }
}
