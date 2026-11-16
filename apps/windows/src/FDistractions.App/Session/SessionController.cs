using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Threading;
using FDistractions.App.Capture;
using FDistractions.App.Overlays;
using FDistractions.Core;
using Microsoft.Win32;

namespace FDistractions.App.Session;

internal enum SessionPhase { Idle, Running, Paused }

internal sealed record ScreenResult(string Label, string Status, string Reason);

/// <summary>The last completed assessment, kept visible while the next one runs.</summary>
internal sealed record CompletedCheck(DateTimeOffset CapturedAt, IReadOnlyList<ScreenResult> Screens, string Classifier);

/// <summary>
/// Runs a focus session on the UI thread: schedules checks (one at a time), feeds validated results
/// into <see cref="InterventionState"/> and shows or removes overlays. Late results from a check
/// that started before a pause/end are dropped.
/// </summary>
internal sealed class SessionController : IDisposable
{
    private readonly InterventionState _state = new();
    private readonly OverlayManager _overlays = new();
    private readonly DispatcherTimer _checkTimer = new();
    private readonly DispatcherTimer _clock = new() { Interval = TimeSpan.FromSeconds(1) };
    private readonly Dispatcher _dispatcher = Dispatcher.CurrentDispatcher;
    private CancellationTokenSource _cancellation = new();
    private IScreenClassifier? _classifier;
    private int _generation;
    private bool _priorityPending;
    private TimeSpan _remainingWhenPaused;

    public event Action? Changed;

    public SessionPhase Phase { get; private set; } = SessionPhase.Idle;
    public string Goal { get; private set; } = "";
    public TimeSpan Gap { get; private set; } = TimeSpan.FromSeconds(MonitoringPolicy.DefaultGapSeconds);
    public DateTimeOffset EndsAt { get; private set; }
    public DateTimeOffset? NextCheckAt { get; private set; }
    public bool IsChecking { get; private set; }
    public CompletedCheck? LastCheck { get; private set; }
    public string? LastError { get; private set; }
    public string? Notice { get; private set; }
    public int BlurredScreens => _state.Active.Count;

    public TimeSpan Remaining => Phase switch
    {
        SessionPhase.Running => EndsAt - DateTimeOffset.Now > TimeSpan.Zero ? EndsAt - DateTimeOffset.Now : TimeSpan.Zero,
        SessionPhase.Paused => _remainingWhenPaused,
        _ => TimeSpan.Zero,
    };

    public SessionController()
    {
        _checkTimer.Tick += (_, _) =>
        {
            _checkTimer.Stop();
            NextCheckAt = null;
            _ = RunCheckAsync();
        };
        _clock.Tick += (_, _) => OnClockTick();
        _overlays.ReturnRequested += OnReturnToWork;
        SystemEvents.DisplaySettingsChanged += OnDisplaySettingsChanged;
        SystemEvents.PowerModeChanged += OnPowerModeChanged;
        SystemEvents.SessionSwitch += OnSessionSwitch;
    }

    public void Start(string goal, int minutes, int gapSeconds, IScreenClassifier classifier)
    {
        if (Phase != SessionPhase.Idle) return;
        if (string.IsNullOrWhiteSpace(goal)) throw new ArgumentException("Describe what you're working on first.");
        if (!MonitoringPolicy.IsValidDuration(minutes))
            throw new ArgumentException($"Choose {MonitoringPolicy.MinSessionMinutes}–{MonitoringPolicy.MaxSessionMinutes} minutes.");
        if (!MonitoringPolicy.IsValidGap(gapSeconds)) throw new ArgumentException("Choose a check gap of 15, 30 or 60 seconds.");

        Goal = goal.Trim();
        Gap = TimeSpan.FromSeconds(gapSeconds);
        EndsAt = DateTimeOffset.Now.AddMinutes(minutes);
        _classifier = classifier;
        LastCheck = null;
        LastError = null;
        Notice = null;
        _state.ClearAll();
        Phase = SessionPhase.Running;
        NewGeneration();
        _clock.Start();
        ScheduleCheck(TimeSpan.Zero);
        Changed?.Invoke();
    }

    /// <summary>Freezes the timer, stops capture and removes all overlays. Resume is explicit.</summary>
    public void Pause(string notice)
    {
        if (Phase != SessionPhase.Running) return;
        _remainingWhenPaused = Remaining;
        Phase = SessionPhase.Paused;
        _clock.Stop();
        NewGeneration();
        CleanUpOverlays();
        Notice = notice;
        Changed?.Invoke();
    }

    public void Resume()
    {
        if (Phase != SessionPhase.Paused) return;
        EndsAt = DateTimeOffset.Now + _remainingWhenPaused;
        Phase = SessionPhase.Running;
        Notice = null;
        NewGeneration();
        _clock.Start();
        ScheduleCheck(TimeSpan.Zero);
        Changed?.Invoke();
    }

    public void End(string notice)
    {
        if (Phase == SessionPhase.Idle) return;
        Phase = SessionPhase.Idle;
        _clock.Stop();
        NewGeneration();
        CleanUpOverlays();
        Notice = notice;
        Changed?.Invoke();
    }

    public void CheckNow()
    {
        if (Phase != SessionPhase.Running || IsChecking) return;
        _checkTimer.Stop();
        NextCheckAt = null;
        _ = RunCheckAsync();
    }

    private async Task RunCheckAsync()
    {
        if (Phase != SessionPhase.Running || IsChecking || _classifier is null) return;
        IsChecking = true;
        Changed?.Invoke();

        var generation = _generation;
        var token = _cancellation.Token;
        var classifier = _classifier;
        var goal = Goal;
        var failed = false;
        try
        {
            var captures = await Task.Run(() => ScreenCapturer.CaptureAll(token), token);
            if (generation != _generation) return;

            var json = await classifier.AssessAsync(goal, captures.Screens.Select(s => s.Image).ToList(), token);
            if (generation != _generation) return;

            var verdict = VerdictParser.Parse(json, captures.Screens.Count);
            var assessment = new Assessment(verdict, captures.Screens.Select(s => s.Display.Id).ToList(), captures.CapturedAt);
            var currentDisplays = Displays.Enumerate().Select(d => d.Id).ToList();
            var result = _state.Apply(assessment, currentDisplays, DateTimeOffset.Now);

            foreach (var intervention in result.Started)
            {
                var capture = captures.Screens[intervention.ScreenIndex - 1];
                _overlays.Show(intervention, capture.Display, capture.Preview, goal);
            }
            foreach (var intervention in result.Updated) _overlays.Update(intervention);

            LastCheck = new CompletedCheck(
                captures.CapturedAt,
                verdict.Screens.OrderBy(s => s.ScreenIndex)
                    .Select(s => new ScreenResult(captures.Screens[s.ScreenIndex - 1].Display.Describe(s.ScreenIndex), s.Status, s.Reason))
                    .ToList(),
                classifier.Name);
            LastError = null;
        }
        catch (OperationCanceledException) when (generation != _generation || token.IsCancellationRequested)
        {
            return;
        }
        catch (Exception error)
        {
            if (generation != _generation) return;
            // A failure is an error, never an off-task verdict, and never clears existing blur.
            failed = true;
            LastError = error is VerdictException ? error.Message : $"Check failed: {error.Message}";
        }
        finally
        {
            if (generation == _generation)
            {
                IsChecking = false;
                ScheduleCheck(MonitoringPolicy.NextDelay(Gap, _priorityPending, failed));
                _priorityPending = false;
                Changed?.Invoke();
            }
        }
    }

    private void OnReturnToWork(string displayId)
    {
        if (!_state.ReturnToWork(displayId, DateTimeOffset.Now)) return;
        _overlays.AnimateOut(displayId);
        // After the three-second grace period, check again with priority.
        RequestPriorityCheck();
        Changed?.Invoke();
    }

    private void RequestPriorityCheck()
    {
        if (Phase != SessionPhase.Running) return;
        if (IsChecking) { _priorityPending = true; return; }
        var priorityAt = DateTimeOffset.Now + MonitoringPolicy.PriorityFloor;
        if (NextCheckAt is { } next && next <= priorityAt) return;
        ScheduleCheck(MonitoringPolicy.PriorityFloor);
    }

    private void ScheduleCheck(TimeSpan delay)
    {
        if (Phase != SessionPhase.Running) return;
        _checkTimer.Stop();
        _checkTimer.Interval = delay > TimeSpan.Zero ? delay : TimeSpan.FromMilliseconds(1);
        NextCheckAt = DateTimeOffset.Now + delay;
        _checkTimer.Start();
    }

    private void OnClockTick()
    {
        if (Phase == SessionPhase.Running && DateTimeOffset.Now >= EndsAt) End("Session complete. Nice work.");
        else Changed?.Invoke();
    }

    /// <summary>Cancels in-flight work and makes any late result from it irrelevant.</summary>
    private void NewGeneration()
    {
        _generation++;
        _cancellation.Cancel();
        _cancellation.Dispose();
        _cancellation = new CancellationTokenSource();
        _checkTimer.Stop();
        NextCheckAt = null;
        IsChecking = false;
        _priorityPending = false;
    }

    private void CleanUpOverlays()
    {
        _state.ClearAll();
        _overlays.HideAll();
    }

    private void OnDisplaySettingsChanged(object? sender, EventArgs e) => _dispatcher.BeginInvoke(() =>
    {
        var connected = Displays.Enumerate().Select(d => d.Id).ToList();
        foreach (var removed in _state.RemoveDisconnected(connected)) _overlays.Remove(removed);
        RequestPriorityCheck();
        Changed?.Invoke();
    });

    private void OnPowerModeChanged(object? sender, PowerModeChangedEventArgs e)
    {
        if (e.Mode == PowerModes.Suspend)
            _dispatcher.BeginInvoke(() => Pause("Paused because the PC went to sleep. Resume when you're ready."));
    }

    private void OnSessionSwitch(object? sender, SessionSwitchEventArgs e)
    {
        if (e.Reason is SessionSwitchReason.SessionLock or SessionSwitchReason.ConsoleDisconnect or SessionSwitchReason.RemoteDisconnect)
            _dispatcher.BeginInvoke(() => Pause("Paused because Windows was locked. Resume when you're ready."));
    }

    public void Dispose()
    {
        SystemEvents.DisplaySettingsChanged -= OnDisplaySettingsChanged;
        SystemEvents.PowerModeChanged -= OnPowerModeChanged;
        SystemEvents.SessionSwitch -= OnSessionSwitch;
        End("App closed.");
        _cancellation.Dispose();
    }
}
