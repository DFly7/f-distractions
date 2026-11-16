using System.Text.Json;
using FDistractions.Core;

namespace FDistractions.Core.Tests;

/// <summary>Uses a fake process, so these run without Claude Code installed and send nothing anywhere.</summary>
public class ClaudeCodeClassifierTests
{
    private static readonly ScreenImage[] TwoScreens =
    [
        new(1, "DISPLAY1", [1, 2, 3], 10, 10),
        new(2, "DISPLAY2", [4, 5, 6], 10, 10),
    ];

    private const string ValidVerdict =
        "{\"status\":\"off_task\",\"reason\":\"r\",\"nextStep\":\"n\",\"screens\":[" +
        "{\"screenIndex\":1,\"status\":\"on_task\",\"reason\":\"work\",\"evidenceSource\":\"active_content\"},{\"screenIndex\":2,\"status\":\"off_task\",\"reason\":\"video\",\"evidenceSource\":\"active_content\"}]}";

    private static string Result(string extra) =>
        "{\"type\":\"system\",\"subtype\":\"init\"}\n" +
        "{\"type\":\"assistant\",\"message\":{}}\n" +
        "{\"type\":\"result\"," + extra + "}\n";

    [Fact]
    public void ArgumentsRemoveEveryToolAndKeepNothing()
    {
        var args = ClaudeCodeClassifier.BuildArguments(2, null);
        Assert.Equal("-p", args[0]);
        Assert.Equal("", args[args.ToList().IndexOf("--tools") + 1]);
        Assert.Equal("mcp__*", args[args.ToList().IndexOf("--disallowedTools") + 1]);
        Assert.Equal("dontAsk", args[args.ToList().IndexOf("--permission-mode") + 1]);
        Assert.Contains("--strict-mcp-config", args);
        Assert.Contains("--disable-slash-commands", args);
        Assert.Contains("--no-session-persistence", args);
        Assert.DoesNotContain("--model", args);
        Assert.Equal("sonnet", ClaudeCodeClassifier.BuildArguments(2, "sonnet").Last());
    }

    [Fact]
    public void SchemaPinsTheScreenCount()
    {
        using var schema = JsonDocument.Parse(ClaudeCodeClassifier.VerdictSchema(3));
        var screens = schema.RootElement.GetProperty("properties").GetProperty("screens");
        Assert.Equal(3, screens.GetProperty("minItems").GetInt32());
        Assert.Equal(3, screens.GetProperty("maxItems").GetInt32());
        var item = screens.GetProperty("items");
        Assert.Equal(3, item.GetProperty("properties").GetProperty("screenIndex").GetProperty("maximum").GetInt32());
        Assert.Contains("evidenceSource", item.GetProperty("required").EnumerateArray().Select(e => e.GetString()));
    }

    [Fact]
    public void InputIsOneUserMessageWithImagesInScreenOrder()
    {
        var line = ClaudeCodeClassifier.BuildInput("Write my essay", [TwoScreens[1], TwoScreens[0]]);
        Assert.EndsWith("\n", line);
        using var message = JsonDocument.Parse(line);
        Assert.Equal("user", message.RootElement.GetProperty("type").GetString());
        var content = message.RootElement.GetProperty("message").GetProperty("content").EnumerateArray().ToList();
        Assert.Contains("Write my essay", content[0].GetProperty("text").GetString());
        Assert.Equal("Screen 1:", content[1].GetProperty("text").GetString());
        Assert.Equal(Convert.ToBase64String([1, 2, 3]), content[2].GetProperty("source").GetProperty("data").GetString());
        Assert.Equal("Screen 2:", content[3].GetProperty("text").GetString());
    }

    [Fact]
    public void PromptMatchesTheSharedReferenceCopy()
    {
        var shared = File.ReadAllText(Path.Combine(SharedPaths.RepoRoot(), "shared", "prompts", "classify.txt"));
        Assert.Equal(shared.Replace("\r\n", "\n").Trim(), ClassifierPrompt.Instructions);
    }

    [Fact]
    public async Task StructuredOutputIsReturnedAndValidates()
    {
        var runner = new FakeRunner(new ProcessResult(0, Result($"\"subtype\":\"success\",\"is_error\":false,\"structured_output\":{ValidVerdict}"), ""));
        var classifier = new ClaudeCodeClassifier("claude.exe", null, runner, Path.GetTempPath());
        var json = await classifier.AssessAsync("goal", TwoScreens, CancellationToken.None);
        Assert.Equal(ScreenStatus.OffTask, VerdictParser.Parse(json, 2).Status);
        Assert.NotNull(runner.LastInput);
    }

    [Theory]
    [InlineData("\"subtype\":\"success\",\"is_error\":true,\"result\":\"Not logged in · Please run /login\"", "Not logged in")]
    [InlineData("\"subtype\":\"error_max_turns\",\"is_error\":false", "error_max_turns")]
    [InlineData("\"subtype\":\"success\",\"is_error\":false,\"result\":\"I can't help\"", "expected format")]
    public void FailuresAreErrorsNeverVerdicts(string resultFields, string expected)
    {
        var error = Assert.Throws<ClaudeCodeException>(() =>
            ClaudeCodeClassifier.ExtractVerdictJson(new ProcessResult(1, Result(resultFields), "")));
        Assert.Contains(expected, error.Message);
    }

    [Fact]
    public void NoResultEventReportsStandardError()
    {
        var error = Assert.Throws<ClaudeCodeException>(() =>
            ClaudeCodeClassifier.ExtractVerdictJson(new ProcessResult(1, "", "error: unknown option '--foo'\n")));
        Assert.Contains("unknown option", error.Message);
    }

    [Theory]
    [InlineData(0, "{\"loggedIn\":true,\"authMethod\":\"claude.ai\"}", true)]
    [InlineData(1, "{\"loggedIn\":false,\"authMethod\":\"none\"}", false)]
    [InlineData(0, "not json", false)]
    public void AuthStatusIsInterpretedWithoutCredentials(int exitCode, string stdout, bool signedIn)
    {
        var status = ClaudeCodeSetup.Interpret("claude.exe", new ProcessResult(exitCode, stdout, ""));
        Assert.Equal(signedIn, status.Ready);
    }

    private sealed class FakeRunner(ProcessResult result) : IProcessRunner
    {
        public string? LastInput { get; private set; }

        public Task<ProcessResult> RunAsync(string executable, IReadOnlyList<string> arguments, string? standardInput,
            string workingDirectory, TimeSpan timeout, CancellationToken cancellationToken)
        {
            LastInput = standardInput;
            return Task.FromResult(result);
        }
    }
}
