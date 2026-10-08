using Dapper;
using Microsoft.AspNetCore.Identity;
using Microsoft.Data.SqlClient;
using ServicePortal.Web.Data;

namespace ServicePortal.Web.Infrastructure;

/// <summary>
/// Development/demo only (Seed:DemoUsers = true): creates the demo login accounts on first start.
/// Passwords must be hashed by the application, which is why this isn't a SQL script.
/// Waits for the database to be deployed (useful under docker compose).
/// </summary>
public sealed class DemoSeeder(IServiceProvider services, IConfiguration configuration, ILogger<DemoSeeder> logger) : IHostedService
{
    public async Task StartAsync(CancellationToken cancellationToken)
    {
        if (!configuration.GetValue<bool>("Seed:DemoUsers")) return;

        var password = configuration["Seed:DemoPassword"] ?? "Demo!Pass2026";
        using var scope = services.CreateScope();
        var db = scope.ServiceProvider.GetRequiredService<SqlDb>();
        var hasher = new PasswordHasher<object>();
        string Hash() => hasher.HashPassword(new object(), password);

        for (var attempt = 1; ; attempt++)
        {
            try
            {
                await db.QuerySingleAsync<LoginUser>("app.usp_User_GetForLogin", new { UserName = "admin" });
                break;
            }
            catch (SqlException ex) when (attempt < 30)
            {
                logger.LogInformation("Waiting for database ({Attempt}/30): {Message}", attempt, ex.Message);
                await Task.Delay(TimeSpan.FromSeconds(5), cancellationToken);
            }
        }

        var admin = await db.QuerySingleAsync<LoginUser>("app.usp_User_GetForLogin", new { UserName = "admin" });
        int adminId;
        if (admin is null)
        {
            adminId = await db.QuerySingleAsync<int>("app.usp_User_Bootstrap",
                new { UserName = "admin", DisplayName = "Portal Administrator", PasswordHash = Hash() });
            logger.LogInformation("Bootstrapped administrator account 'admin'");
        }
        else
        {
            adminId = admin.UserId;
        }

        var departments = (await db.QueryAsync<Department>("app.usp_Lookup_Departments")).ToDictionary(d => d.Code, d => d.DepartmentId);
        var staff = new (string UserName, string Display, string Role, string? Dept)[]
        {
            ("clerk", "Casey Clerk", "CLERK", null),
            ("sup.roads", "Riley Roads (Supervisor)", "SUPERVISOR", "ROADS"),
            ("sup.transport", "Taylor Transportation (Director)", "SUPERVISOR", "TRANS"),
            ("sup.waste", "Wren Waste (Supervisor)", "SUPERVISOR", "WASTE"),
            ("sup.building", "Blake Building (Chief Building Official)", "SUPERVISOR", "BUILDING"),
        };

        foreach (var (userName, display, role, dept) in staff)
        {
            if (await db.QuerySingleAsync<LoginUser>("app.usp_User_GetForLogin", new { UserName = userName }) is not null) continue;
            await db.QuerySingleAsync<int>("app.usp_User_Save", new
            {
                UserId = (int?)null,
                UserName = userName,
                DisplayName = display,
                RoleCode = role,
                DepartmentId = dept is null ? (int?)null : departments[dept],
                IsActive = true,
                PasswordHash = Hash(),
            }, actingUserId: adminId);
            logger.LogInformation("Created demo user {UserName}", userName);
        }

        if (await db.QuerySingleAsync<LoginUser>("app.usp_User_GetForLogin", new { UserName = "resident@example.com" }) is null)
        {
            await db.QuerySingleAsync<int>("app.usp_Resident_Register", new
            {
                FirstName = "Robin",
                LastName = "Resident",
                Email = "resident@example.com",
                Phone = "705-555-0142",
                StreetAddress = "12 Bayfield St",
                MunicipalityId = (byte)13,
                PasswordHash = Hash(),
            });
            logger.LogInformation("Created demo resident resident@example.com");
        }
    }

    public Task StopAsync(CancellationToken cancellationToken) => Task.CompletedTask;
}
