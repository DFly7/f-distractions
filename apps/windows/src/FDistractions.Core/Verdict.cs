using System.Text.Json;

namespace FDistractions.Core;

/// <summary>Status strings from shared/schemas/verdict.schema.json.</summary>
public static class ScreenStatus
{
    public const string OnTask = "on_task";
    public const string OffTask = "off_task";
    public const string Unsure = "unsure";
    public const string Neutral = "neutral";

    public static readonly IReadOnlySet<string> ScreenValues = new HashSet<string> { OnTask, OffTask, Unsure, Neutral };

    /// <summary>What a screen judgment is based on. Only <see cref="ActiveContent"/> may accompany off_task.</summary>
    public const string ActiveContent = "active_content";
    public const string InactiveNavigation = "inactive_navigation";
    public const string MonitoringUi = "monitoring_ui";
    public const string Unreadable = "unreadable";

    public static readonly IReadOnlySet<string> EvidenceSources =
        new HashSet<string> { ActiveContent, InactiveNavigation, MonitoringUi, Unreadable };
    public static readonly IReadOnlySet<string> AggregateValues = new HashSet<string> { OnTask, OffTask, Unsure };

    /// <summary>
    /// any off_task → off_task; else any unsure → unsure; else any on_task → on_task; else unsure.
    /// </summary>
    public static string Aggregate(IEnumerable<string> screenStatuses)
    {
        var all = screenStatuses.ToList();
        if (all.Contains(OffTask)) return OffTask;
        if (all.Contains(Unsure)) return Unsure;
        if (all.Contains(OnTask)) return OnTask;
        return Unsure;
    }
}

public sealed record ScreenVerdict(int ScreenIndex, string Status, string Reason, string EvidenceSource = ScreenStatus.ActiveContent);

public sealed record Verdict(string Status, string Reason, string NextStep, IReadOnlyList<ScreenVerdict> Screens);

public sealed class VerdictException(string message) : Exception(message);

/// <summary>
/// Parses and validates an AI assessment. Validation follows shared/README.md: exactly N screen
/// entries with unique indices 1..N, known statuses and evidence sources only, off_task only with
/// active_content evidence, and a consistent aggregate. A failure is always an error, never an
/// off-task verdict, and never clears a blur that is already locked.
/// </summary>
public static class VerdictParser
{
    private static readonly HashSet<string> TopLevelKeys = ["status", "reason", "nextStep", "screens"];
    private static readonly HashSet<string> ScreenKeys = ["screenIndex", "status", "reason", "evidenceSource"];

    public static Verdict Parse(string json, int screenCount)
    {
        Verdict verdict;
        try
        {
            using var document = JsonDocument.Parse(json);
            verdict = Read(document.RootElement);
        }
        catch (JsonException)
        {
            throw new VerdictException("The model returned an unrecognised verdict. Try another check.");
        }
        catch (Exception e) when (e is InvalidOperationException or FormatException or KeyNotFoundException)
        {
            throw new VerdictException("The model returned an unrecognised verdict. Try another check.");
        }
        return Validate(verdict, screenCount);
    }

    public static Verdict Validate(Verdict verdict, int screenCount)
    {
        if (screenCount < 1) throw new VerdictException("No screens were captured for this check.");
        if (!ScreenStatus.AggregateValues.Contains(verdict.Status))
            throw new VerdictException("The model returned an unrecognised verdict. Try another check.");
        if (verdict.Screens.Count != screenCount)
            throw new VerdictException("The model didn’t assess every screen correctly. Try another check.");

        var indices = verdict.Screens.Select(s => s.ScreenIndex).ToHashSet();
        if (indices.Count != screenCount || indices.Any(i => i < 1 || i > screenCount))
            throw new VerdictException("The model didn’t assess every screen correctly. Try another check.");
        if (verdict.Screens.Any(s => !ScreenStatus.ScreenValues.Contains(s.Status) || !ScreenStatus.EvidenceSources.Contains(s.EvidenceSource)))
            throw new VerdictException("The model returned an unrecognised verdict. Try another check.");
        if (verdict.Screens.Any(s => s.Status == ScreenStatus.OffTask && s.EvidenceSource != ScreenStatus.ActiveContent))
            throw new VerdictException("The model cited inactive navigation, monitoring UI or unreadable content as a distraction. " +
                                       "No new blur was applied; checking again later.");
        if (ScreenStatus.Aggregate(verdict.Screens.Select(s => s.Status)) != verdict.Status)
            throw new VerdictException("The model’s screen judgments were inconsistent. Try another check.");
        return verdict;
    }

    private static Verdict Read(JsonElement root)
    {
        RequireExactKeys(root, TopLevelKeys);
        var screens = root.GetProperty("screens");
        if (screens.ValueKind != JsonValueKind.Array) throw new InvalidOperationException();
        var list = new List<ScreenVerdict>();
        foreach (var item in screens.EnumerateArray())
        {
            RequireExactKeys(item, ScreenKeys);
            list.Add(new ScreenVerdict(
                item.GetProperty("screenIndex").GetInt32(),
                item.GetProperty("status").GetString()!,
                item.GetProperty("reason").GetString()!,
                item.GetProperty("evidenceSource").GetString()!));
        }
        return new Verdict(
            root.GetProperty("status").GetString()!,
            root.GetProperty("reason").GetString()!,
            root.GetProperty("nextStep").GetString()!,
            list);
    }

    private static void RequireExactKeys(JsonElement element, HashSet<string> keys)
    {
        if (element.ValueKind != JsonValueKind.Object) throw new InvalidOperationException();
        var seen = new HashSet<string>();
        foreach (var property in element.EnumerateObject())
        {
            if (!keys.Contains(property.Name) || !seen.Add(property.Name)) throw new InvalidOperationException();
        }
        if (seen.Count != keys.Count) throw new InvalidOperationException();
    }
}
