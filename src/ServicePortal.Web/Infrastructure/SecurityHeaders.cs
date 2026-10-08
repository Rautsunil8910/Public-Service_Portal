namespace ServicePortal.Web.Infrastructure;

public static class SecurityHeaders
{
    /// <summary>Baseline browser hardening headers on every response.</summary>
    public static IApplicationBuilder UseSecurityHeaders(this IApplicationBuilder app) =>
        app.Use(async (context, next) =>
        {
            var headers = context.Response.Headers;
            headers["X-Content-Type-Options"] = "nosniff";
            headers["X-Frame-Options"] = "DENY";
            headers["Referrer-Policy"] = "strict-origin-when-cross-origin";
            headers["Permissions-Policy"] = "geolocation=(self), camera=(), microphone=()";
            headers["Content-Security-Policy"] =
                "default-src 'self'; img-src 'self' data:; style-src 'self'; script-src 'self'; frame-ancestors 'none'; form-action 'self'";
            await next();
        });
}
