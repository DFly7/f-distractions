namespace FDistractions.Core;

/// <summary>A blur on one physical display. <paramref name="DisplayId"/> is the platform's display identity.</summary>
public sealed record Intervention(string DisplayId, int ScreenIndex, string Reason);

/// <summary>The outcome of one validated assessment captured at <paramref name="CapturedAt"/>.</summary>
/// <param name="DisplayIds">Display identities in screenshot order: index 0 is screen 1.</param>
public sealed record Assessment(Verdict Verdict, IReadOnlyList<string> DisplayIds, DateTimeOffset CapturedAt);

public sealed record ApplyResult(IReadOnlyList<Intervention> Started, IReadOnlyList<Intervention> Updated)
{
    public static readonly ApplyResult None = new([], []);
}

/// <summary>
/// Per-screen latched blur (docs/behaviour.md, "Starting and keeping blur" and "Explicit actions").
/// Only a fresh, validated off-task screen judgment can start blur. Nothing in here lets a later
/// on_task/unsure/neutral result, a failed check, or navigation clear an existing blur: blur is
/// removed only by an explicit action (<see cref="ReturnToWork"/>), a display disappearing, or
/// session cleanup (<see cref="ClearAll"/>).
/// </summary>
public sealed class InterventionState
{
    public static readonly TimeSpan MaxResultAge = TimeSpan.FromSeconds(20);
    public static readonly TimeSpan ReturnGrace = TimeSpan.FromSeconds(3);

    private readonly Dictionary<string, Intervention> _active = new();
    private readonly Dictionary<string, DateTimeOffset> _graceUntil = new();

    public IReadOnlyCollection<Intervention> Active => _active.Values;

    public bool IsBlurred(string displayId) => _active.ContainsKey(displayId);

    public bool IsInGrace(string displayId, DateTimeOffset now) =>
        _graceUntil.TryGetValue(displayId, out var until) && now < until;

    /// <summary>
    /// Applies an assessment. <paramref name="currentDisplayIds"/> is the display mapping right now,
    /// in the same order the capture used; if it differs the result is stale and starts nothing.
    /// Never removes an existing blur.
    /// </summary>
    public ApplyResult Apply(Assessment assessment, IReadOnlyList<string> currentDisplayIds, DateTimeOffset now)
    {
        var age = now - assessment.CapturedAt;
        if (age < TimeSpan.Zero || age > MaxResultAge) return ApplyResult.None;
        if (!assessment.DisplayIds.SequenceEqual(currentDisplayIds)) return ApplyResult.None;

        Verdict verdict;
        try { verdict = VerdictParser.Validate(assessment.Verdict, assessment.DisplayIds.Count); }
        catch (VerdictException) { return ApplyResult.None; }

        var started = new List<Intervention>();
        var updated = new List<Intervention>();
        foreach (var screen in verdict.Screens)
        {
            if (screen.Status != ScreenStatus.OffTask) continue;
            var displayId = assessment.DisplayIds[screen.ScreenIndex - 1];
            if (IsInGrace(displayId, now)) continue;

            var intervention = new Intervention(displayId, screen.ScreenIndex, screen.Reason);
            if (_active.ContainsKey(displayId)) updated.Add(intervention);
            else started.Add(intervention);
            _active[displayId] = intervention;
        }
        return new ApplyResult(started, updated);
    }

    /// <summary>"Return to work": clears only this screen and starts its three-second grace period.</summary>
    public bool ReturnToWork(string displayId, DateTimeOffset now)
    {
        if (!_active.Remove(displayId)) return false;
        _graceUntil[displayId] = now + ReturnGrace;
        return true;
    }

    /// <summary>Removes blur for displays that are no longer connected. Others stay blurred.</summary>
    public IReadOnlyList<string> RemoveDisconnected(IEnumerable<string> connectedDisplayIds)
    {
        var connected = connectedDisplayIds.ToHashSet();
        var removed = _active.Keys.Where(id => !connected.Contains(id)).ToList();
        foreach (var id in removed) _active.Remove(id);
        return removed;
    }

    /// <summary>Session lifecycle cleanup (end, expiry, completed break hold).</summary>
    public void ClearAll()
    {
        _active.Clear();
        _graceUntil.Clear();
    }
}
