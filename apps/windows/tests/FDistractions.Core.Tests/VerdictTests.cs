using System.Text.Json;
using FDistractions.Core;

namespace FDistractions.Core.Tests;

/// <summary>Runs the shared synthetic fixtures (shared/fixtures/verdicts.json) through the Windows validator.</summary>
public class VerdictTests
{
    public static TheoryData<string> FixtureNames()
    {
        var data = new TheoryData<string>();
        foreach (var fixture in SharedFixtures.Verdicts()) data.Add(fixture.GetProperty("name").GetString()!);
        return data;
    }

    [Theory]
    [MemberData(nameof(FixtureNames))]
    public void SharedFixtureValidity(string name)
    {
        var fixture = SharedFixtures.Verdicts().Single(f => f.GetProperty("name").GetString() == name);
        var json = fixture.GetProperty("response").GetRawText();
        var screenCount = fixture.GetProperty("screenCount").GetInt32();

        if (fixture.GetProperty("valid").GetBoolean())
        {
            var verdict = VerdictParser.Parse(json, screenCount);
            Assert.Equal(screenCount, verdict.Screens.Count);
        }
        else
        {
            Assert.Throws<VerdictException>(() => VerdictParser.Parse(json, screenCount));
        }
    }

    [Theory]
    [InlineData("not json")]
    [InlineData("{\"status\":\"on_task\"}")]
    [InlineData("{\"status\":\"on_task\",\"reason\":\"r\",\"nextStep\":\"n\",\"screens\":[{\"screenIndex\":1,\"status\":\"on_task\",\"reason\":\"r\"}],\"extra\":1}")]
    [InlineData("{\"status\":\"neutral\",\"reason\":\"r\",\"nextStep\":\"n\",\"screens\":[{\"screenIndex\":1,\"status\":\"neutral\",\"reason\":\"r\"}]}")]
    [InlineData("{\"status\":\"on_task\",\"reason\":\"r\",\"nextStep\":\"n\",\"screens\":[{\"screenIndex\":1.5,\"status\":\"on_task\",\"reason\":\"r\"}]}")]
    public void MalformedResponsesAreErrorsNotOffTask(string json)
    {
        Assert.Throws<VerdictException>(() => VerdictParser.Parse(json, 1));
    }

    [Fact]
    public void ResponseOrderIsNotMeaningful()
    {
        const string json = "{\"status\":\"off_task\",\"reason\":\"r\",\"nextStep\":\"n\",\"screens\":[" +
            "{\"screenIndex\":2,\"status\":\"off_task\",\"reason\":\"r\",\"evidenceSource\":\"active_content\"},{\"screenIndex\":1,\"status\":\"on_task\",\"reason\":\"r\",\"evidenceSource\":\"active_content\"}]}";
        Assert.Equal(ScreenStatus.OffTask, VerdictParser.Parse(json, 2).Status);
    }

    [Theory]
    [InlineData(new[] { "on_task", "off_task" }, "off_task")]
    [InlineData(new[] { "unsure", "on_task" }, "unsure")]
    [InlineData(new[] { "on_task", "neutral" }, "on_task")]
    [InlineData(new[] { "neutral", "neutral" }, "unsure")]
    public void AggregateRule(string[] screens, string expected)
    {
        Assert.Equal(expected, ScreenStatus.Aggregate(screens));
    }

    [Fact]
    public async Task FakeClassifierOutputPassesValidation()
    {
        var images = new[] { Image(1), Image(2) };
        var fake = new FakeClassifier(FakeMode.AlwaysOffTaskOnScreen, 2, TimeSpan.Zero);
        var verdict = VerdictParser.Parse(await fake.AssessAsync("goal", images, CancellationToken.None), 2);
        Assert.Equal(ScreenStatus.OffTask, verdict.Status);
        Assert.Equal(ScreenStatus.OffTask, verdict.Screens.Single(s => s.ScreenIndex == 2).Status);
    }

    [Fact]
    public async Task FakeClassifierOffTaskOnceThenOnTask()
    {
        var images = new[] { Image(1) };
        var fake = new FakeClassifier(FakeMode.OffTaskOnceOnScreen, 1, TimeSpan.Zero);
        Assert.Equal(ScreenStatus.OffTask, VerdictParser.Parse(await fake.AssessAsync("g", images, CancellationToken.None), 1).Status);
        Assert.Equal(ScreenStatus.OnTask, VerdictParser.Parse(await fake.AssessAsync("g", images, CancellationToken.None), 1).Status);
    }

    private static ScreenImage Image(int index) => new(index, $"display-{index}", [], 1, 1);
}

internal static class SharedFixtures
{
    public static IReadOnlyList<JsonElement> Verdicts()
    {
        var path = Path.Combine(SharedPaths.RepoRoot(), "shared", "fixtures", "verdicts.json");
        using var document = JsonDocument.Parse(File.ReadAllText(path));
        return document.RootElement.EnumerateArray().Select(e => e.Clone()).ToList();
    }
}

internal static class SharedPaths
{
    public static string RepoRoot()
    {
        for (var dir = new DirectoryInfo(AppContext.BaseDirectory); dir is not null; dir = dir.Parent)
        {
            if (File.Exists(Path.Combine(dir.FullName, "shared", "fixtures", "verdicts.json"))) return dir.FullName;
        }
        throw new DirectoryNotFoundException("Couldn't find the repository's shared/ folder above the test output.");
    }
}
