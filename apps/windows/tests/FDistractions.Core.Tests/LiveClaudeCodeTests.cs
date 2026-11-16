using FDistractions.Core;

namespace FDistractions.Core.Tests;

/// <summary>
/// Opt-in live check against the developer's own signed-in Claude Code. Skipped unless
/// FDISTRACTIONS_LIVE_CLAUDE_IMAGES points at a folder with screen1.jpg and screen2.jpg
/// (synthetic images only, never real screenshots). Uses the developer's Claude plan quota.
/// Never enable this in CI.
/// </summary>
public class LiveClaudeCodeTests
{
    private const string Variable = "FDISTRACTIONS_LIVE_CLAUDE_IMAGES";

    [LiveFact]
    public async Task SyntheticDistractionIsJudgedOffTask()
    {
        var folder = Environment.GetEnvironmentVariable(Variable)!;
        var executable = ClaudeCodeSetup.FindExecutable() ?? throw new InvalidOperationException("claude.exe not found.");
        var screens = new[]
        {
            new ScreenImage(1, "SYNTHETIC1", File.ReadAllBytes(Path.Combine(folder, "screen1.jpg")), 1200, 750),
            new ScreenImage(2, "SYNTHETIC2", File.ReadAllBytes(Path.Combine(folder, "screen2.jpg")), 1200, 750),
        };
        var classifier = new ClaudeCodeClassifier(executable, null, new SystemProcessRunner(), ClaudeCodeSetup.WorkingDirectory);

        var json = await classifier.AssessAsync("Write my history essay on the causes of the French Revolution.", screens, CancellationToken.None);
        var verdict = VerdictParser.Parse(json, 2);

        Assert.Equal(ScreenStatus.OffTask, verdict.Status);
        Assert.Equal(ScreenStatus.OffTask, verdict.Screens.Single(s => s.ScreenIndex == 2).Status);
        Assert.NotEqual(ScreenStatus.OffTask, verdict.Screens.Single(s => s.ScreenIndex == 1).Status);
    }

    private sealed class LiveFactAttribute : FactAttribute
    {
        public LiveFactAttribute()
        {
            if (string.IsNullOrEmpty(Environment.GetEnvironmentVariable(Variable)))
                Skip = $"Live Claude Code check: set {Variable} to a folder of synthetic screen1.jpg/screen2.jpg to run.";
        }
    }
}
