using ServicePortal.Shared;
using Xunit;

namespace ServicePortal.Tests;

public class PasswordPolicyTests
{
    [Theory]
    [InlineData("Short1A")]
    [InlineData("alllowercase123")]
    [InlineData("ALLUPPERCASE123")]
    [InlineData("NoDigitsHereAtAll")]
    public void Weak_passwords_are_rejected(string password) =>
        Assert.NotEmpty(PasswordPolicy.Validate(password));

    [Fact]
    public void Strong_password_is_accepted() =>
        Assert.Empty(PasswordPolicy.Validate("Muskoka-Lakes2026", "robin@example.com"));

    [Fact]
    public void Password_containing_user_name_is_rejected() =>
        Assert.Contains(PasswordPolicy.Validate("Robin2026Secure", "robin@example.com"), e => e.Contains("user name"));
}

public class DbRuleMappingTests
{
    [Theory]
    [InlineData(50001, DbRuleKind.AccessDenied)]
    [InlineData(50002, DbRuleKind.NotFound)]
    [InlineData(50003, DbRuleKind.InvalidTransition)]
    [InlineData(50004, DbRuleKind.Conflict)]
    [InlineData(50005, DbRuleKind.Validation)]
    public void Known_sql_error_numbers_map_to_rule_kinds(int number, DbRuleKind expected) =>
        Assert.Equal(expected, DbRuleException.KindFromSqlErrorNumber(number));

    [Theory]
    [InlineData(229)]     // permission denied
    [InlineData(1205)]    // deadlock victim
    [InlineData(50000)]
    public void Other_sql_errors_are_not_treated_as_business_rules(int number) =>
        Assert.Null(DbRuleException.KindFromSqlErrorNumber(number));

    [Fact]
    public void Only_validation_transition_and_conflict_are_user_fixable()
    {
        Assert.True(new DbRuleException(DbRuleKind.Validation, "x").IsUserFixable);
        Assert.True(new DbRuleException(DbRuleKind.Conflict, "x").IsUserFixable);
        Assert.False(new DbRuleException(DbRuleKind.AccessDenied, "x").IsUserFixable);
    }
}
