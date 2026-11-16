using System.Reflection;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace FDistractions.Core;

public sealed class ClaudeCodeException(string message) : Exception(message);

/// <summary>
/// Assesses screenshots by running the user's own, unmodified Claude Code CLI (<c>claude -p</c>),
/// signed in by the user through Anthropic's own sign-in flow. This app never reads, stores or
/// handles Claude credentials.
///
/// Safety: every built-in tool is removed (<c>--tools ""</c>), MCP tools are denied, slash commands
/// are off, permission prompts are denied, the run starts in an empty folder and the session is not
/// saved. Screenshots go in on stdin only; nothing is written to disk. The answer is requested in the
/// shared verdict format and is still validated by <see cref="VerdictParser"/> before use.
/// </summary>
public sealed class ClaudeCodeClassifier(
    string executable, string? model, IProcessRunner runner, string workingDirectory, TimeSpan? timeout = null)
    : IScreenClassifier
{
    public static readonly TimeSpan DefaultTimeout = TimeSpan.FromSeconds(120);

    public string Name => model is null ? "Claude via your Claude Code sign-in" : $"Claude ({model}) via your Claude Code sign-in";

    public async Task<string> AssessAsync(string goal, IReadOnlyList<ScreenImage> screens, CancellationToken cancellationToken)
    {
        if (screens.Count == 0) throw new ArgumentException("No screen images were supplied for this check.");
        Directory.CreateDirectory(workingDirectory);
        var result = await runner.RunAsync(executable, BuildArguments(screens.Count, model), BuildInput(goal, screens),
            workingDirectory, timeout ?? DefaultTimeout, cancellationToken);
        return ExtractVerdictJson(result);
    }

    public static IReadOnlyList<string> BuildArguments(int screenCount, string? model)
    {
        var arguments = new List<string>
        {
            "-p",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--verbose",
            "--json-schema", VerdictSchema(screenCount),
            "--system-prompt", ClassifierPrompt.Instructions,
            "--tools", "",
            "--disallowedTools", "mcp__*",
            "--strict-mcp-config",
            "--disable-slash-commands",
            "--no-session-persistence",
            "--permission-mode", "dontAsk",
            "--max-turns", "3",
        };
        if (!string.IsNullOrWhiteSpace(model)) arguments.AddRange(["--model", model]);
        return arguments;
    }

    /// <summary>One stream-json user message: the goal, then each screenshot in screen order.</summary>
    public static string BuildInput(string goal, IReadOnlyList<ScreenImage> screens)
    {
        var content = new JsonArray
        {
            new JsonObject
            {
                ["type"] = "text",
                ["text"] = $"User goal and task boundaries:\n{goal}\n\nThere are {screens.Count} screen images, " +
                           $"ordered Screen 1 through Screen {screens.Count}. Assess every screen together.",
            },
        };
        foreach (var screen in screens.OrderBy(s => s.ScreenIndex))
        {
            content.Add(new JsonObject { ["type"] = "text", ["text"] = $"Screen {screen.ScreenIndex}:" });
            content.Add(new JsonObject
            {
                ["type"] = "image",
                ["source"] = new JsonObject
                {
                    ["type"] = "base64",
                    ["media_type"] = "image/jpeg",
                    ["data"] = Convert.ToBase64String(screen.Jpeg),
                },
            });
        }
        var message = new JsonObject
        {
            ["type"] = "user",
            ["message"] = new JsonObject { ["role"] = "user", ["content"] = content },
            ["parent_tool_use_id"] = null,
        };
        return message.ToJsonString() + "\n";
    }

    /// <summary>Same shape as the Mac request schema: exactly N screens, indices 1..N.</summary>
    public static string VerdictSchema(int screenCount)
    {
        var screen = new JsonObject
        {
            ["type"] = "object",
            ["additionalProperties"] = false,
            ["properties"] = new JsonObject
            {
                ["screenIndex"] = new JsonObject { ["type"] = "integer", ["minimum"] = 1, ["maximum"] = screenCount },
                ["status"] = new JsonObject { ["type"] = "string", ["enum"] = new JsonArray("on_task", "off_task", "unsure", "neutral") },
                ["reason"] = new JsonObject { ["type"] = "string" },
                ["evidenceSource"] = new JsonObject
                {
                    ["type"] = "string",
                    ["enum"] = new JsonArray("active_content", "inactive_navigation", "monitoring_ui", "unreadable"),
                },
            },
            ["required"] = new JsonArray("screenIndex", "evidenceSource", "status", "reason"),
        };
        var schema = new JsonObject
        {
            ["type"] = "object",
            ["additionalProperties"] = false,
            ["properties"] = new JsonObject
            {
                ["status"] = new JsonObject { ["type"] = "string", ["enum"] = new JsonArray("on_task", "off_task", "unsure") },
                ["reason"] = new JsonObject { ["type"] = "string" },
                ["nextStep"] = new JsonObject { ["type"] = "string" },
                ["screens"] = new JsonObject
                {
                    ["type"] = "array",
                    ["items"] = screen,
                    ["minItems"] = screenCount,
                    ["maxItems"] = screenCount,
                },
            },
            ["required"] = new JsonArray("status", "reason", "nextStep", "screens"),
        };
        return schema.ToJsonString();
    }

    /// <summary>Finds the final <c>result</c> event and returns its structured output as JSON text.</summary>
    public static string ExtractVerdictJson(ProcessResult process)
    {
        JsonElement? result = null;
        foreach (var line in process.StandardOutput.Split('\n'))
        {
            var trimmed = line.Trim();
            if (!trimmed.StartsWith('{')) continue;
            try
            {
                using var document = JsonDocument.Parse(trimmed);
                if (document.RootElement.TryGetProperty("type", out var type) && type.ValueEquals("result"))
                    result = document.RootElement.Clone();
            }
            catch (JsonException) { /* not an event line */ }
        }

        if (result is not { } final)
        {
            var detail = FirstLine(process.StandardError);
            throw new ClaudeCodeException(detail.Length > 0
                ? $"Claude Code didn’t return a result: {detail}"
                : $"Claude Code didn’t return a result (exit code {process.ExitCode}).");
        }

        var isError = final.TryGetProperty("is_error", out var flag) && flag.ValueKind == JsonValueKind.True;
        var subtype = final.TryGetProperty("subtype", out var sub) ? sub.GetString() : null;
        if (isError || subtype != "success")
        {
            var text = final.TryGetProperty("result", out var message) && message.ValueKind == JsonValueKind.String
                ? FirstLine(message.GetString()!) : subtype ?? "unknown error";
            throw new ClaudeCodeException($"Claude Code couldn’t complete the check: {text}");
        }

        if (final.TryGetProperty("structured_output", out var structured) && structured.ValueKind == JsonValueKind.Object)
            return structured.GetRawText();

        throw new ClaudeCodeException("Claude didn’t return a verdict in the expected format. Try another check.");
    }

    private static string FirstLine(string text)
    {
        var line = text.Split('\n').Select(l => l.Trim()).FirstOrDefault(l => l.Length > 0) ?? "";
        return line.Length > 200 ? line[..200] + "…" : line;
    }
}

/// <summary>The classifier instructions, embedded at build time from shared/prompts/classify.txt.</summary>
public static class ClassifierPrompt
{
    public static string Instructions { get; } = Load();

    private static string Load()
    {
        using var stream = Assembly.GetExecutingAssembly().GetManifestResourceStream("FDistractions.Core.classify.txt")
            ?? throw new InvalidOperationException("The classifier prompt resource is missing from the build.");
        using var reader = new StreamReader(stream);
        return reader.ReadToEnd().Replace("\r\n", "\n").Trim();
    }
}
