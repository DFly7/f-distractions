namespace FDistractions.Core;

/// <summary>
/// The ten-second continuous hold that guards early exit (docs/behaviour.md, "Early-exit friction").
/// Times are monotonic seconds (e.g. Stopwatch), so wall-clock changes are irrelevant. Any release,
/// drag-out or loss of focus must call <see cref="Reset"/>.
/// </summary>
public sealed class ContinuousHold
{
    public static readonly TimeSpan Duration = TimeSpan.FromSeconds(10);

    public TimeSpan? StartedAt { get; private set; }

    public bool IsHolding => StartedAt is not null;

    public void Begin(TimeSpan now) => StartedAt ??= now;

    public void Reset() => StartedAt = null;

    public double Progress(TimeSpan now)
    {
        if (StartedAt is not { } started) return 0;
        return Math.Clamp((now - started) / Duration, 0, 1);
    }

    public int SecondsRemaining(TimeSpan now) =>
        Math.Max(1, (int)Math.Ceiling(Duration.TotalSeconds * (1 - Progress(now))));

    /// <summary>Returns true once, when the hold has lasted the full duration, and resets.</summary>
    public bool Complete(TimeSpan now)
    {
        if (Progress(now) < 1) return false;
        Reset();
        return true;
    }
}
