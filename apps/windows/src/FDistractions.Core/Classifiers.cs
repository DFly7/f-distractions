using System.Text.Json;

namespace FDistractions.Core;

/// <summary>One captured display, already downscaled and JPEG-encoded. Held in memory only.</summary>
public sealed record ScreenImage(int ScreenIndex, string DisplayId, byte[] Jpeg, int Width, int Height);

/// <summary>
/// Assesses screenshots against the user's goal. Implementations return the raw JSON text of an
/// assessment; the caller always validates it with <see cref="VerdictParser"/>, so a real AI adapter
/// and the fake one go through the same checks. Screenshot content is evidence, never instructions,
/// and classifiers must not execute tools.
/// </summary>
public interface IScreenClassifier
{
    string Name { get; }
    Task<string> AssessAsync(string goal, IReadOnlyList<ScreenImage> screens, CancellationToken cancellationToken);
}

public enum FakeMode
{
    AlwaysOnTask,
    AlwaysOffTaskOnScreen,
    OffTaskOnceOnScreen,
    AlwaysFails,
}

/// <summary>
/// A local stand-in for the AI, for testing capture → overlay → explicit dismissal without an AI
/// account. It never looks at the pixels and never sends them anywhere.
/// </summary>
public sealed class FakeClassifier(FakeMode mode, int targetScreen, TimeSpan? latency = null) : IScreenClassifier
{
    private bool _firedOnce;

    public string Name => "Test classifier (no AI)";

    public async Task<string> AssessAsync(string goal, IReadOnlyList<ScreenImage> screens, CancellationToken cancellationToken)
    {
        await Task.Delay(latency ?? TimeSpan.FromMilliseconds(600), cancellationToken);
        if (mode == FakeMode.AlwaysFails) throw new InvalidOperationException("Test classifier: simulated AI failure.");

        var offTask = mode switch
        {
            FakeMode.AlwaysOffTaskOnScreen => true,
            FakeMode.OffTaskOnceOnScreen => !_firedOnce,
            _ => false,
        };
        // A target screen that doesn't exist (e.g. screen 2 with one monitor) just means "on task".
        offTask &= screens.Any(s => s.ScreenIndex == targetScreen);
        if (offTask) _firedOnce = true;

        var results = screens.Select(s => new
        {
            screenIndex = s.ScreenIndex,
            status = offTask && s.ScreenIndex == targetScreen ? ScreenStatus.OffTask : ScreenStatus.OnTask,
            reason = offTask && s.ScreenIndex == targetScreen
                ? "Test classifier: pretending this screen shows content unrelated to your focus."
                : "Test classifier: pretending this screen is on task.",
            evidenceSource = ScreenStatus.ActiveContent,
        }).ToList();
        return JsonSerializer.Serialize(new
        {
            status = ScreenStatus.Aggregate(results.Select(r => r.status)),
            reason = "Test classifier result; no AI was used.",
            nextStep = "Continue your task.",
            screens = results,
        });
    }
}
