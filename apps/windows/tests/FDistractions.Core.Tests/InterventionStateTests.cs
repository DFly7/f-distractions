using FDistractions.Core;

namespace FDistractions.Core.Tests;

/// <summary>Windows versions of the scenarios in shared/fixtures/behaviour-cases.json that the core covers.</summary>
public class InterventionStateTests
{
    private static readonly DateTimeOffset T0 = new(2026, 11, 16, 12, 0, 0, TimeSpan.Zero);
    private static readonly string[] Displays = ["DISPLAY1", "DISPLAY2"];

    private static Assessment Assess(DateTimeOffset at, params string[] statuses)
    {
        var screens = statuses.Select((s, i) => new ScreenVerdict(i + 1, s, $"reason {i + 1}")).ToList();
        var verdict = new Verdict(ScreenStatus.Aggregate(statuses), "r", "n", screens);
        return new Assessment(verdict, Displays, at);
    }

    [Fact]
    public void OffTaskStartsBlurOnlyOnThatScreen()
    {
        var state = new InterventionState();
        var result = state.Apply(Assess(T0, "on_task", "off_task"), Displays, T0.AddSeconds(1));
        Assert.Equal("DISPLAY2", Assert.Single(result.Started).DisplayId);
        Assert.False(state.IsBlurred("DISPLAY1"));
        Assert.True(state.IsBlurred("DISPLAY2"));
    }

    [Fact] // latched-on-task
    public void LaterOnTaskResultCannotClearBlur()
    {
        var state = new InterventionState();
        state.Apply(Assess(T0, "on_task", "off_task"), Displays, T0);
        var later = state.Apply(Assess(T0.AddSeconds(30), "on_task", "on_task"), Displays, T0.AddSeconds(31));
        Assert.Empty(later.Started);
        Assert.True(state.IsBlurred("DISPLAY2"));
    }

    [Fact] // reject-inactive-off-task-evidence
    public void OffTaskFromInactiveEvidenceStartsNothingAndKeepsExistingBlur()
    {
        var state = new InterventionState();
        state.Apply(Assess(T0, "off_task", "on_task"), Displays, T0);
        var screens = new List<ScreenVerdict>
        {
            new(1, "on_task", "r"),
            new(2, "off_task", "sidebar label", ScreenStatus.InactiveNavigation),
        };
        var result = state.Apply(new Assessment(new Verdict("off_task", "r", "n", screens), Displays, T0), Displays, T0.AddSeconds(1));
        Assert.Empty(result.Started);
        Assert.False(state.IsBlurred("DISPLAY2"));
        Assert.True(state.IsBlurred("DISPLAY1"));
    }

    [Fact]
    public void NeutralUnsureAndInvalidResultsCannotClearBlur()
    {
        var state = new InterventionState();
        state.Apply(Assess(T0, "on_task", "off_task"), Displays, T0);
        state.Apply(Assess(T0.AddSeconds(5), "neutral", "unsure"), Displays, T0.AddSeconds(5));
        var invalid = new Assessment(new Verdict("on_task", "r", "n", []), Displays, T0.AddSeconds(6));
        state.Apply(invalid, Displays, T0.AddSeconds(6));
        Assert.True(state.IsBlurred("DISPLAY2"));
    }

    [Fact] // per-screen-return
    public void ReturnToWorkClearsOnlyThatScreen()
    {
        var state = new InterventionState();
        state.Apply(Assess(T0, "off_task", "off_task"), Displays, T0);
        Assert.True(state.ReturnToWork("DISPLAY2", T0.AddSeconds(2)));
        Assert.True(state.IsBlurred("DISPLAY1"));
        Assert.False(state.IsBlurred("DISPLAY2"));
    }

    [Fact] // return-grace
    public void OldResultCannotReblurDuringGrace()
    {
        var state = new InterventionState();
        state.Apply(Assess(T0, "on_task", "off_task"), Displays, T0);
        state.ReturnToWork("DISPLAY2", T0.AddSeconds(1));
        var inGrace = state.Apply(Assess(T0.AddSeconds(0.5), "on_task", "off_task"), Displays, T0.AddSeconds(3.9));
        Assert.Empty(inGrace.Started);
        Assert.False(state.IsBlurred("DISPLAY2"));
    }

    [Fact]
    public void FreshOffTaskAfterGraceCanReblur()
    {
        var state = new InterventionState();
        state.Apply(Assess(T0, "on_task", "off_task"), Displays, T0);
        state.ReturnToWork("DISPLAY2", T0.AddSeconds(1));
        var after = state.Apply(Assess(T0.AddSeconds(4), "on_task", "off_task"), Displays, T0.AddSeconds(5));
        Assert.Single(after.Started);
        Assert.True(state.IsBlurred("DISPLAY2"));
    }

    [Fact] // stale-new-blur
    public void ResultOlderThanTwentySecondsCannotStartBlur()
    {
        var state = new InterventionState();
        var result = state.Apply(Assess(T0, "on_task", "off_task"), Displays, T0.AddSeconds(21));
        Assert.Empty(result.Started);
        Assert.Empty(state.Active);
    }

    [Fact] // stale-new-blur (display mapping changed)
    public void ChangedDisplayMappingCannotStartBlur()
    {
        var state = new InterventionState();
        var result = state.Apply(Assess(T0, "on_task", "off_task"), ["DISPLAY2", "DISPLAY1"], T0);
        Assert.Empty(result.Started);
    }

    [Fact]
    public void StaleResultDoesNotRemoveExistingBlur()
    {
        var state = new InterventionState();
        state.Apply(Assess(T0, "on_task", "off_task"), Displays, T0);
        state.Apply(Assess(T0, "on_task", "on_task"), Displays, T0.AddMinutes(5));
        Assert.True(state.IsBlurred("DISPLAY2"));
    }

    [Fact] // display-disconnect
    public void DisconnectRemovesOnlyThatDisplay()
    {
        var state = new InterventionState();
        state.Apply(Assess(T0, "off_task", "off_task"), Displays, T0);
        Assert.Equal(["DISPLAY2"], state.RemoveDisconnected(["DISPLAY1"]));
        Assert.True(state.IsBlurred("DISPLAY1"));
    }

    [Fact]
    public void RepeatedOffTaskUpdatesInsteadOfRestarting()
    {
        var state = new InterventionState();
        state.Apply(Assess(T0, "on_task", "off_task"), Displays, T0);
        var again = state.Apply(Assess(T0.AddSeconds(30), "on_task", "off_task"), Displays, T0.AddSeconds(30));
        Assert.Empty(again.Started);
        Assert.Single(again.Updated);
    }

    [Fact] // hold-complete cleanup
    public void ClearAllRemovesEverything()
    {
        var state = new InterventionState();
        state.Apply(Assess(T0, "off_task", "off_task"), Displays, T0);
        state.ClearAll();
        Assert.Empty(state.Active);
    }
}

public class ContinuousHoldTests
{
    private static TimeSpan S(double seconds) => TimeSpan.FromSeconds(seconds);

    [Fact] // hold-reset
    public void ReleasingAtNineSecondsResets()
    {
        var hold = new ContinuousHold();
        hold.Begin(S(0));
        Assert.False(hold.Complete(S(9)));
        hold.Reset();
        Assert.Equal(0, hold.Progress(S(9.5)));
        hold.Begin(S(10));
        Assert.False(hold.Complete(S(19.9)));
    }

    [Fact] // hold-complete
    public void CompletesAfterTenContinuousSeconds()
    {
        var hold = new ContinuousHold();
        hold.Begin(S(5));
        hold.Begin(S(8)); // a repeated begin (key repeat) must not restart the hold
        Assert.True(hold.Complete(S(15)));
        Assert.False(hold.IsHolding);
    }

    [Fact]
    public void CountdownShowsWholeSeconds()
    {
        var hold = new ContinuousHold();
        hold.Begin(S(0));
        Assert.Equal(10, hold.SecondsRemaining(S(0)));
        Assert.Equal(1, hold.SecondsRemaining(S(9.9)));
    }
}

public class MonitoringPolicyTests
{
    [Theory]
    [InlineData(15, false, false, 15)]
    [InlineData(30, true, false, 3)]
    [InlineData(15, false, true, 30)]
    [InlineData(60, true, true, 60)]
    public void NextDelay(int gap, bool priority, bool failed, int expected)
    {
        Assert.Equal(TimeSpan.FromSeconds(expected), MonitoringPolicy.NextDelay(TimeSpan.FromSeconds(gap), priority, failed));
    }

    [Fact]
    public void SessionLimits()
    {
        Assert.True(MonitoringPolicy.IsValidDuration(1));
        Assert.True(MonitoringPolicy.IsValidDuration(240));
        Assert.False(MonitoringPolicy.IsValidDuration(0));
        Assert.False(MonitoringPolicy.IsValidDuration(241));
        Assert.False(MonitoringPolicy.IsValidGap(20));
    }
}
