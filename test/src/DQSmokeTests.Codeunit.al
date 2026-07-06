namespace DynaQuery.Test;

codeunit 50149 "DQ Smoke Tests"
{
    Subtype = Test;
    TestPermissions = Disabled;

    [Test]
    procedure Smoke_TestRunnerWorks_Passes()
    var
        Expected: Integer;
        Actual: Integer;
    begin
        // [SCENARIO] The AL-Go test project builds and the test runner executes a test.
        // [GIVEN] a known value
        Expected := 2;
        // [WHEN] a trivial computation is performed
        Actual := 1 + 1;
        // [THEN] it matches — self-contained assert, no test-toolkit dependency yet
        //        (Library Assert is introduced in Phase 3/5 with verified GUIDs)
        if Actual <> Expected then
            Error('Smoke test failed: expected %1, got %2', Expected, Actual);
    end;
}
