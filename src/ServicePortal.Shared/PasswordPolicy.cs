namespace ServicePortal.Shared;

/// <summary>Password rules applied to self-registration and admin-set passwords.</summary>
public static class PasswordPolicy
{
    public const int MinimumLength = 10;

    public static IReadOnlyList<string> Validate(string? password, string? userName = null)
    {
        var errors = new List<string>();
        if (string.IsNullOrEmpty(password))
        {
            errors.Add("Password is required.");
            return errors;
        }
        if (password.Length < MinimumLength) errors.Add($"Use at least {MinimumLength} characters.");
        if (!password.Any(char.IsUpper)) errors.Add("Include an upper-case letter.");
        if (!password.Any(char.IsLower)) errors.Add("Include a lower-case letter.");
        if (!password.Any(char.IsDigit)) errors.Add("Include a number.");
        if (!string.IsNullOrWhiteSpace(userName) &&
            password.Contains(userName.Split('@')[0], StringComparison.OrdinalIgnoreCase))
            errors.Add("Do not include your user name in the password.");
        return errors;
    }
}
