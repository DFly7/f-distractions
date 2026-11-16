namespace FDistractions.Core;

/// <summary>Session settings and check timing from docs/behaviour.md.</summary>
public static class MonitoringPolicy
{
    public static readonly IReadOnlyList<int> AllowedGapSeconds = [15, 30, 60];
    public const int DefaultGapSeconds = 30;
    public const int MinSessionMinutes = 1;
    public const int MaxSessionMinutes = 240;
    public const int DefaultSessionMinutes = 45;

    public static readonly TimeSpan PriorityFloor = TimeSpan.FromSeconds(3);
    public static readonly TimeSpan MinimumFailureBackoff = TimeSpan.FromSeconds(30);

    /// <summary>
    /// Background checks use the selected gap, priority checks have a three-second floor, and failed
    /// checks back off by at least 30 seconds or the selected gap, whichever is longer.
    /// </summary>
    public static TimeSpan NextDelay(TimeSpan gap, bool priority, bool lastCheckFailed)
    {
        if (lastCheckFailed) return gap > MinimumFailureBackoff ? gap : MinimumFailureBackoff;
        return priority ? PriorityFloor : gap;
    }

    public static bool IsValidGap(int seconds) => AllowedGapSeconds.Contains(seconds);

    public static bool IsValidDuration(int minutes) => minutes is >= MinSessionMinutes and <= MaxSessionMinutes;
}
