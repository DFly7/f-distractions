using System.Text.Json;

namespace FDistractions.Core;

public sealed record ClaudeCodeStatus(string? Executable, bool SignedIn, string? AuthMethod, string Message)
{
    public bool Ready => Executable is not null && SignedIn;
}

/// <summary>
/// Finds the user's Claude Code install and asks it whether it's signed in (<c>claude auth status</c>).
/// Only the sign-in method is read from that output; no credentials are touched.
/// </summary>
public static class ClaudeCodeSetup
{
    /// <summary>Looks for claude.exe (the native installer's binary) on PATH and in ~/.local/bin.</summary>
    public static string? FindExecutable()
    {
        var candidates = (Environment.GetEnvironmentVariable("PATH") ?? "")
            .Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries)
            .Select(dir => Path.Combine(dir.Trim('"'), "claude.exe"))
            .Append(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".local", "bin", "claude.exe"));
        return candidates.FirstOrDefault(File.Exists);
    }

    public static async Task<ClaudeCodeStatus> CheckAsync(IProcessRunner runner, string workingDirectory, CancellationToken cancellationToken)
    {
        var executable = FindExecutable();
        if (executable is null)
            return new ClaudeCodeStatus(null, false, null,
                "Claude Code isn’t installed (claude.exe not found). Install it, then run: claude auth login");

        Directory.CreateDirectory(workingDirectory);
        ProcessResult result;
        try
        {
            result = await runner.RunAsync(executable, ["auth", "status"], null, workingDirectory, TimeSpan.FromSeconds(20), cancellationToken);
        }
        catch (Exception e) when (e is not OperationCanceledException)
        {
            return new ClaudeCodeStatus(executable, false, null, $"Couldn’t run Claude Code: {e.Message}");
        }
        return Interpret(executable, result);
    }

    public static ClaudeCodeStatus Interpret(string executable, ProcessResult result)
    {
        string? method = null;
        try
        {
            using var document = JsonDocument.Parse(result.StandardOutput);
            if (document.RootElement.TryGetProperty("authMethod", out var value) && value.ValueKind == JsonValueKind.String)
                method = value.GetString();
        }
        catch (JsonException) { }

        var signedIn = result.ExitCode == 0 && method is not null && method != "none";
        var message = signedIn
            ? method == "claude.ai"
                ? "Claude Code is signed in with your Claude account."
                : $"Claude Code is signed in ({method}). Checks will use that sign-in."
            : "Claude Code isn’t signed in. Run claude auth login in a terminal, then check again.";
        return new ClaudeCodeStatus(executable, signedIn, method, message);
    }

    /// <summary>An empty folder for Claude Code runs, so no project files or CLAUDE.md are picked up.</summary>
    public static string WorkingDirectory =>
        Path.Combine(Path.GetTempPath(), "FDistractions", "claude-runs");
}
