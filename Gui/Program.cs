using Microsoft.Win32;
using System.Diagnostics;
using System.Reflection;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace Wupa;

internal static class Program
{
    [STAThread]
    private static void Main()
    {
        try
        {
            Application.SetHighDpiMode(HighDpiMode.PerMonitorV2);
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            Application.Run(new MainForm());
        }
        catch (Exception ex)
        {
            var path = StartupFailureLog.TryWrite(ex);
            var detail = string.IsNullOrWhiteSpace(path) ? ex.ToString() : $"{ex}\n\nDetails were saved to:\n{path}";
            MessageBox.Show(detail, "WUPA could not start", MessageBoxButtons.OK, MessageBoxIcon.Error);
        }
    }
}

internal sealed class MainForm : Form
{
    private const string AppVersion = "3.1.1";
    private const int TargetBuild = 26200;
    private readonly Label _status = new();
    private readonly Label _statusDetail = new();
    private readonly Label _stage = new();
    private readonly Button _primary = new();
    private readonly LinkLabel _analyze = new();
    private readonly LinkLabel _openReport = new();
    private readonly LinkLabel _openFolder = new();
    private readonly LinkLabel _cancel = new();
    private readonly LinkLabel _details = new();
    private readonly LinkLabel _trackingFiles = new();
    private readonly Panel _viewport = new();
    private readonly TableLayoutPanel _content = new();
    private readonly FlowLayoutPanel _reportLinks = new();
    private readonly TableLayoutPanel _title = new();
    private readonly TextBox _log = new();
    private readonly Panel _detailsPanel = new();
    private readonly System.Windows.Forms.Timer _timer = new();
    private string? _runtimePath;
    private string? _lastOutputPath;
    private string? _lastCollectorLine;
    private bool _busy;
    private bool _detailsVisible;
    private bool _layingOut;
    private string _primaryAction = "Start";
    private DateTime _actionStartedUtc;

    public MainForm(bool prepareRuntime = true)
    {
        Text = $"WUPA {AppVersion}";
        StartPosition = FormStartPosition.CenterScreen;
        AutoScaleMode = AutoScaleMode.Dpi;
        AutoScaleDimensions = new SizeF(96, 96);
        MinimumSize = new Size(740, 600);
        Size = new Size(860, 640);
        BackColor = Color.FromArgb(244, 247, 250);
        Font = new Font("Segoe UI", 9.5F);
        try { Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath); } catch { }
        BuildInterface();
        if (prepareRuntime) Load += OnLoaded;
        FormClosing += OnClosing;
    }

    private void BuildInterface()
    {
        _viewport.Dock = DockStyle.Fill;
        _viewport.AutoScroll = true;
        _viewport.BackColor = BackColor;
        Controls.Add(_viewport);
        _content.AutoSize = true;
        _content.AutoSizeMode = AutoSizeMode.GrowAndShrink;
        _content.ColumnCount = 1;
        _content.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        _content.Margin = Padding.Empty;
        _viewport.Controls.Add(_content);
        _viewport.ClientSizeChanged += (_, _) => LayoutContent();

        var heading = new TableLayoutPanel { AutoSize = true, Dock = DockStyle.Top, ColumnCount = 2, BackColor = Color.FromArgb(6, 38, 70), Padding = new Padding(20), Margin = Padding.Empty };
        heading.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        heading.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        var logo = new PictureBox { Size = new Size(62, 62), Margin = new Padding(0, 0, 16, 0), SizeMode = PictureBoxSizeMode.Zoom };
        try
        {
            using var stream = Assembly.GetExecutingAssembly().GetManifestResourceStream("Wupa.BrandLogo");
            if (stream is not null) { using var image = Image.FromStream(stream); logo.Image = new Bitmap(image); }
            else logo.Image = Icon?.ToBitmap();
        }
        catch { }
        Disposed += (_, _) => logo.Image?.Dispose();
        heading.Controls.Add(logo, 0, 0);
        _title.AutoSize = true;
        _title.Dock = DockStyle.Top;
        _title.ColumnCount = 1;
        _title.Margin = Padding.Empty;
        _title.Controls.Add(new Label { Text = "WUPA", Dock = DockStyle.Top, ForeColor = Color.White, Font = new Font("Segoe UI Semibold", 21F), AutoSize = true, Margin = Padding.Empty });
        _title.Controls.Add(new Label { Text = "Windows Update Performance Analyzer", Dock = DockStyle.Top, ForeColor = Color.FromArgb(183, 223, 237), Font = new Font("Segoe UI", 10.5F), AutoSize = true, Margin = Padding.Empty });
        heading.Controls.Add(_title, 1, 0);
        _content.Controls.Add(heading);

        var statusCard = new TableLayoutPanel { AutoSize = true, Dock = DockStyle.Top, ColumnCount = 1, BackColor = Color.White, Padding = new Padding(20), Margin = new Padding(0, 16, 0, 16) };
        statusCard.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        _status.Text = "Checking this computer…";
        _status.Font = new Font("Segoe UI Semibold", 15F);
        _status.ForeColor = Color.FromArgb(6, 38, 70);
        _status.Dock = DockStyle.Top;
        _status.AutoSize = true;
        _statusDetail.Text = "Loading the focused Windows Update collector.";
        _statusDetail.ForeColor = Color.FromArgb(70, 80, 92);
        _statusDetail.Dock = DockStyle.Top;
        _statusDetail.AutoSize = true;
        _statusDetail.Margin = new Padding(0, 10, 0, 12);
        _stage.Text = "Target: Windows 11 25H2  •  Results: Public Documents";
        _stage.ForeColor = Color.FromArgb(0, 119, 125);
        _stage.Font = new Font("Segoe UI Semibold", 9.5F);
        _stage.AutoSize = true;
        _stage.Dock = DockStyle.Top;
        _stage.Margin = Padding.Empty;
        statusCard.Controls.Add(_status);
        statusCard.Controls.Add(_statusDetail);
        statusCard.Controls.Add(_stage);
        _content.Controls.Add(statusCard);

        ConfigureButton(_primary, "Start tracking", Color.FromArgb(0, 113, 188), 48);
        _primary.Enabled = false;
        _primary.Dock = DockStyle.Top;
        _primary.Font = new Font("Segoe UI Semibold", 11F);
        _primary.Click += async (_, _) => await ConfirmAndRunPrimaryAsync();
        _content.Controls.Add(_primary);

        ConfigureLink(_analyze, "Already attempted the update? Create a report from existing logs");
        _analyze.Dock = DockStyle.Top;
        _analyze.Visible = false;
        ConfigureLink(_openReport, "Open latest completed report");
        ConfigureLink(_openFolder, "Open report folder");
        ConfigureLink(_cancel, "Stop tracking without a report");
        _cancel.LinkColor = Color.FromArgb(146, 67, 42);
        _cancel.Dock = DockStyle.Top;
        _cancel.Visible = false;
        _analyze.LinkClicked += async (_, _) => await RunActionAsync("Analyze");
        _openReport.LinkClicked += (_, _) => OpenLatestReport();
        _openFolder.LinkClicked += (_, _) => OpenBestFolder();
        _cancel.LinkClicked += async (_, _) => await ConfirmCancelAsync();
        _content.Controls.Add(_analyze);
        _content.Controls.Add(_cancel);
        _reportLinks.Dock = DockStyle.Top;
        _reportLinks.AutoSize = true;
        _reportLinks.WrapContents = true;
        _reportLinks.Margin = new Padding(0, 12, 0, 4);
        _reportLinks.Visible = false;
        _reportLinks.Controls.AddRange(new Control[] { _openReport, _openFolder });
        _content.Controls.Add(_reportLinks);

        _detailsPanel.Dock = DockStyle.Top;
        _detailsPanel.Height = 260;
        _detailsPanel.Visible = false;
        _log.Dock = DockStyle.Fill;
        _log.Multiline = true;
        _log.ReadOnly = true;
        _log.ScrollBars = ScrollBars.Both;
        _log.WordWrap = false;
        _log.Font = new Font("Consolas", 8.5F);
        _log.BackColor = Color.FromArgb(20, 27, 35);
        _log.ForeColor = Color.FromArgb(220, 231, 239);
        ConfigureLink(_trackingFiles, "Open tracking files (ProgramData)");
        _trackingFiles.Dock = DockStyle.Top;
        _trackingFiles.Visible = false;
        _trackingFiles.LinkClicked += (_, _) => { var active = ActiveRunInfo.TryRead(); if (active is not null && Directory.Exists(active.RunPath)) OpenPath(active.RunPath); };
        var technical = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 1, RowCount = 2, Margin = Padding.Empty };
        technical.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        technical.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        technical.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        // Explicit rows keep the log in the expanding row even when the
        // optional tracking-files link is hidden.
        technical.Controls.Add(_trackingFiles, 0, 0);
        technical.Controls.Add(_log, 0, 1);
        _detailsPanel.Controls.Add(technical);
        ConfigureLink(_details, "Show collector log");
        _details.Dock = DockStyle.Top;
        _details.LinkClicked += (_, _) => ToggleDetails();
        _content.Controls.Add(_details);
        _content.Controls.Add(_detailsPanel);
        _content.Controls.Add(new Label { Text = "Collects evidence only. Does not install updates or make repairs.", Dock = DockStyle.Top, AutoSize = true, ForeColor = Color.FromArgb(92, 100, 112), Margin = new Padding(0, 16, 0, 0) });
        LayoutContent();
    }

    private static void ConfigureLink(LinkLabel link, string text)
    {
        link.Text = text;
        link.AutoSize = true;
        link.LinkBehavior = LinkBehavior.HoverUnderline;
        link.LinkColor = Color.FromArgb(0, 96, 160);
        link.ActiveLinkColor = Color.FromArgb(0, 70, 120);
        link.Margin = new Padding(0, 8, 20, 8);
        link.Padding = new Padding(0, 3, 0, 3);
    }

    private void LayoutContent()
    {
        if (_content.IsDisposed || _layingOut) return;
        _layingOut = true;
        try
        {
            var gutter = LogicalToDeviceUnits(24);
            var width = Math.Max(1, Math.Min(LogicalToDeviceUnits(920), _viewport.ClientSize.Width - gutter * 2));
            _content.MinimumSize = _content.MaximumSize = new Size(width, 0);
            _content.Width = width;
            var textWidth = Math.Max(1, width - LogicalToDeviceUnits(40));
            foreach (var label in _title.Controls.OfType<Label>()) label.MaximumSize = new Size(Math.Max(1, width - LogicalToDeviceUnits(118)), 0);
            _status.MaximumSize = _statusDetail.MaximumSize = _stage.MaximumSize = new Size(textWidth, 0);
            _analyze.MaximumSize = _cancel.MaximumSize = new Size(width, 0);
            var logHeight = Math.Max(LogicalToDeviceUnits(220), Math.Min(LogicalToDeviceUnits(420), _viewport.ClientSize.Height - LogicalToDeviceUnits(460)));
            _detailsPanel.MinimumSize = new Size(0, logHeight);
            _detailsPanel.Height = logHeight;
            _content.Location = new Point(Math.Max(gutter, (_viewport.ClientSize.Width - width) / 2), gutter + _viewport.AutoScrollPosition.Y);
            _content.PerformLayout();
            _viewport.AutoScrollMinSize = new Size(0, _content.Height + gutter * 2);
            _viewport.PerformLayout();
            // AutoScroll can remove/add its vertical bar during layout. Center
            // against the final client width, not the pre-layout viewport.
            _content.Location = new Point(Math.Max(gutter, (_viewport.ClientSize.Width - _content.Width) / 2), gutter + _viewport.AutoScrollPosition.Y);
        }
        finally { _layingOut = false; }
    }

    private static void ConfigureButton(Button button, string text, Color color, int height)
    {
        button.Text = text;
        button.AutoSize = true;
        button.Height = height;
        button.MinimumSize = new Size(0, height);
        button.Padding = new Padding(14, 0, 14, 0);
        button.FlatStyle = FlatStyle.Flat;
        button.FlatAppearance.BorderSize = 0;
        button.BackColor = color;
        button.ForeColor = Color.White;
        button.Margin = new Padding(0, 0, 8, 8);
    }

    private async void OnLoaded(object? sender, EventArgs e)
    {
        try
        {
            AppendLog("Preparing the verified embedded WUPA collector…");
            _runtimePath = await Task.Run(() => PayloadManager.EnsureExtracted(AppVersion));
            AppendLog($"Collector ready: {_runtimePath}");
            RefreshState();
            _timer.Interval = 5000;
            _timer.Tick += (_, _) => { if (!_busy) RefreshState(); };
            _timer.Start();
        }
        catch (Exception ex)
        {
            SetStatus("WUPA could not start", ex.Message, true);
            AppendLog(ex.ToString());
            MessageBox.Show(this, ex.Message, "WUPA", MessageBoxButtons.OK, MessageBoxIcon.Error);
        }
    }

    private async Task ConfirmAndRunPrimaryAsync()
    {
        if (_primaryAction == "Finish")
        {
            var answer = MessageBox.Show(this, "Finish tracking and build a report now? WUPA will stop its recorder, collect final evidence, and remove this case's scheduled tasks and setup hooks. If the update is still running, later activity will not be recorded.", "Finish tracking and build report", MessageBoxButtons.YesNo, MessageBoxIcon.Question);
            if (answer != DialogResult.Yes) return;
        }
        await RunActionAsync(_primaryAction);
    }

    private async Task ConfirmCancelAsync()
    {
        var answer = MessageBox.Show(this, "Stop tracking without creating a report? WUPA will stop the recorder and remove this case's scheduled tasks and setup hooks. Evidence already recorded in ProgramData is retained. Use Finish tracking and build report if you want a report.", "Stop without a report", MessageBoxButtons.YesNo, MessageBoxIcon.Warning);
        if (answer == DialogResult.Yes) await RunActionAsync("Cancel");
    }

    private async Task RunActionAsync(string action)
    {
        if (_busy || string.IsNullOrWhiteSpace(_runtimePath)) return;
        _busy = true;
        _actionStartedUtc = DateTime.UtcNow;
        SetBusy(true);
        _log.Clear();
        SetStatus(ActionTitle(action), "Keep this window open while the collector works.", false);
        AppendLog($"Starting {action} at {_actionStartedUtc:O}");
        var activeBefore = ActiveRunInfo.TryRead();
        if (!string.IsNullOrWhiteSpace(activeBefore?.OutputPath)) _lastOutputPath = activeBefore.OutputPath;

        try
        {
            var result = await RunBackendAsync(action);
            RefreshState(false);
            var activeAfter = ActiveRunInfo.TryRead();
            if (!string.IsNullOrWhiteSpace(activeAfter?.OutputPath)) _lastOutputPath = activeAfter.OutputPath;
            if (action == "Start")
            {
                if (result.RunLockCollision) { ShowAutomaticFinalization(activeAfter ?? activeBefore, true); return; }
                if (activeAfter is null) throw new InvalidOperationException($"The collector exited with code {result.ExitCode}, but no tracked case was created. {result.LastMessage}");
                var ready = result.ExitCode is 0 or 10 && activeAfter.RecorderStartStatus.Equals("Started", StringComparison.OrdinalIgnoreCase);
                SetStatus(ready ? "Ready for the 25H2 update" : "Tracking needs attention", ready ? "You can close WUPA and start the update normally. Tracking continues across reboots." : $"Recorder startup returned '{activeAfter.RecorderStartStatus}'. Open the collector log before starting the update.", !ready);
                MessageBox.Show(this, ready ? "WUPA is ready. You can close this app and start the Windows 11 25H2 update normally. Tracking continues across reboots and finishes automatically after a terminal result." : "The tracking case was created, but recorder startup was not verified. Review the collector log before starting the update.", ready ? "Ready for the update" : "Tracking needs attention", MessageBoxButtons.OK, ready ? MessageBoxIcon.Information : MessageBoxIcon.Warning);
            }
            else if (action is "Finish" or "Resume" or "Analyze")
            {
                if (result.RunLockCollision) { ShowAutomaticFinalization(activeAfter ?? activeBefore, true); return; }
                var report = FindLatestReport(_actionStartedUtc.AddSeconds(-5));
                if (report is null) throw new InvalidOperationException(result.LastMessage ?? $"The collector exited with code {result.ExitCode} without creating a report.");
                _lastOutputPath = Path.GetDirectoryName(report);
                SetStatus(result.ExitCode >= 30 ? "Report created with evidence gaps" : "Report ready", report, result.ExitCode >= 30);
                if (MessageBox.Show(this, $"WUPA finished with exit code {result.ExitCode}.\n\nOpen the report now?", "Report ready", MessageBoxButtons.YesNo, result.ExitCode >= 30 ? MessageBoxIcon.Warning : MessageBoxIcon.Information) == DialogResult.Yes) OpenPath(report);
            }
            else if (action == "Cancel")
            {
                if (result.RunLockCollision) { ShowAutomaticFinalization(activeAfter ?? activeBefore, true); return; }
                if (result.ExitCode != 0) throw new InvalidOperationException($"Tracking could not be stopped (exit code {result.ExitCode}). {result.LastMessage}");
                SetStatus("Tracking stopped — no report created", "This case's recorder, scheduled tasks and setup hooks were stopped or removed. Previously collected evidence was retained.", false);
            }
        }
        catch (Exception ex)
        {
            SetStatus($"{ActionTitle(action)} failed", ex.Message, true);
            AppendLog(ex.ToString());
            MessageBox.Show(this, ex.Message, "WUPA", MessageBoxButtons.OK, MessageBoxIcon.Error);
        }
        finally
        {
            _busy = false;
            SetBusy(false);
            RefreshState(false);
        }
    }

    private async Task<BackendExecutionResult> RunBackendAsync(string action)
    {
        var systemRoot = Environment.GetEnvironmentVariable("SystemRoot") ?? @"C:\Windows";
        var powerShell = Path.Combine(systemRoot, "System32", "WindowsPowerShell", "v1.0", "powershell.exe");
        if (!File.Exists(powerShell)) throw new FileNotFoundException("64-bit Windows PowerShell was not found.", powerShell);
        var script = Path.Combine(_runtimePath!, "Invoke-Win11UpgradeDiag.ps1");
        var publicDocuments = GetPublicDocuments();
        Directory.CreateDirectory(publicDocuments);
        var bootstrapLog = Path.Combine(publicDocuments, "WUPA-Launcher.log");
        var startInfo = new ProcessStartInfo { FileName = powerShell, UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true, StandardOutputEncoding = Encoding.UTF8, StandardErrorEncoding = Encoding.UTF8, WorkingDirectory = _runtimePath! };
        foreach (var value in new[] { "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", script, "-Action", action, "-NoOpen", "-BootstrapLogPath", bootstrapLog }) startInfo.ArgumentList.Add(value);
        var lines = new System.Collections.Concurrent.ConcurrentQueue<string>();
        void Record(string line) { lines.Enqueue(line); while (lines.Count > 200) lines.TryDequeue(out _); AppendLog(line); }
        using var process = new Process { StartInfo = startInfo, EnableRaisingEvents = true };
        process.OutputDataReceived += (_, args) => { if (args.Data is not null) Record(args.Data); };
        process.ErrorDataReceived += (_, args) => { if (args.Data is not null) Record("ERROR: " + args.Data); };
        if (!process.Start()) throw new InvalidOperationException("Windows PowerShell did not start.");
        process.BeginOutputReadLine();
        process.BeginErrorReadLine();
        await process.WaitForExitAsync();
        process.WaitForExit();
        Record($"Collector exited with code {process.ExitCode}.");
        return new BackendExecutionResult(process.ExitCode, lines.ToArray());
    }

    private void RefreshState(bool updateStatus = true)
    {
        var active = ActiveRunInfo.TryRead();
        var legacyActive = ActiveRunInfo.LegacyCaseExists();
        var collector = active?.TryReadLatestCollectorStatus();
        if (collector is not null && !string.Equals(_lastCollectorLine, collector.RawLine, StringComparison.Ordinal)) { _lastCollectorLine = collector.RawLine; AppendLog("[Collector.log] " + collector.RawLine); }
        ApplyViewState(CurrentBuild(), legacyActive, active, active?.ProbeRunLock() ?? RunLockStatus.NotHeld, collector, FindLatestReport() is not null, updateStatus);
    }

    // The same rendering path is exercised by the Windows layout harness with
    // fixtures. It does not arm tracking, read registry keys or run collectors.
    internal void ApplyViewState(int currentBuild, bool legacyActive, ActiveRunInfo? active, RunLockStatus lockState, CollectorLogStatus? collector, bool hasReport, bool updateStatus = true)
    {
        _trackingFiles.Visible = active is not null;
        _trackingFiles.Enabled = !_busy;
        _reportLinks.Visible = hasReport;
        _openReport.Enabled = _openFolder.Enabled = !_busy && hasReport;
        _stage.Text = "Target: Windows 11 25H2  •  Reports: Public Documents";
        if (active is not null)
        {
            _lastOutputPath = active.OutputPath;
            _primaryAction = "Finish";
            _primary.Text = lockState == RunLockStatus.Held ? "Collection is already running…" : "Finish tracking and build report";
            _primary.Enabled = !_busy && lockState == RunLockStatus.NotHeld;
            _analyze.Visible = false;
            _cancel.Visible = true;
            _cancel.Enabled = !_busy && lockState == RunLockStatus.NotHeld;
            if (updateStatus && !_busy)
            {
                if (lockState == RunLockStatus.Held) ShowAutomaticFinalization(active, false);
                else if (lockState == RunLockStatus.Unknown) SetStatus("Cannot verify this run's status", "WUPA could not read the collector lock. Finish/stop actions are unavailable until its status can be verified. Check the collector log.", true);
                else if (!active.RecorderStartStatus.Equals("Started", StringComparison.OrdinalIgnoreCase)) SetStatus("Tracking needs attention", $"Recorder startup status: {active.RecorderStartStatus}. {collector?.DisplayText}", true);
                else SetStatus("Tracking the 25H2 update", collector?.DisplayText ?? "WUPA is sampling Windows Update progress every 60 seconds and survives reboots.", false);
            }
        }
        else
        {
            _lastCollectorLine = null;
            _cancel.Visible = false;
            _analyze.Visible = !legacyActive;
            if (legacyActive)
            {
                _primary.Enabled = false;
                _analyze.Visible = false;
                if (updateStatus && !_busy) SetStatus("A version 2 case is still active", "Finish or cancel the older case with Windows Update Analytics 2.2.1 before starting WUPA.", true);
            }
            else if (currentBuild >= TargetBuild)
            {
                _primaryAction = "Analyze";
                _primary.Text = "Create report from existing logs";
                _primary.Enabled = !_busy;
                _analyze.Visible = false;
                if (updateStatus && !_busy) SetStatus(currentBuild == TargetBuild ? "Windows 11 25H2 is installed" : "A newer Windows build is installed", "Create a report from retained update logs. Missing download, install or reboot timestamps stay unknown; this does not start monitoring or prove how 25H2 was installed.", false);
            }
            else
            {
                _primaryAction = "Start";
                _primary.Text = "Start tracking";
                _primary.Enabled = !_busy;
                if (updateStatus && !_busy) SetStatus("Start here before the update", "Start tracking, wait for Ready, then run the 25H2 update normally. WUPA records progress across reboots and builds a report when a final result is observed.", false);
            }
        }
        LayoutContent();
    }

    private void ShowAutomaticFinalization(ActiveRunInfo? active, bool dialog)
    {
        var detail = active?.TryReadLatestCollectorStatus()?.DisplayText ?? "Another collector holds this run. Wait for it to finish; this window refreshes every five seconds.";
        SetStatus("A collector is already working on this run", detail, false);
        _primary.Enabled = false;
        _primary.Text = "Collection is already running…";
        _cancel.Enabled = false;
        if (dialog) MessageBox.Show(this, detail, "WUPA is already working", MessageBoxButtons.OK, MessageBoxIcon.Information);
    }

    private void SetBusy(bool busy) { UseWaitCursor = busy; foreach (var control in new Control[] { _primary, _analyze, _openReport, _openFolder, _cancel }) control.Enabled = !busy; }
    private void SetStatus(string title, string detail, bool warning) { if (InvokeRequired) { BeginInvoke(new Action(() => SetStatus(title, detail, warning))); return; } _status.Text = title; _status.ForeColor = warning ? Color.FromArgb(170, 62, 42) : Color.FromArgb(6, 38, 70); _statusDetail.Text = detail; }
    internal void ToggleDetails() { _detailsVisible = !_detailsVisible; _detailsPanel.Visible = _detailsVisible; _details.Text = _detailsVisible ? "Hide collector log" : "Show collector log"; LayoutContent(); }
    private void AppendLog(string value) { if (InvokeRequired) { BeginInvoke(new Action(() => AppendLog(value))); return; } _log.AppendText(value + Environment.NewLine); _log.SelectionStart = _log.TextLength; _log.ScrollToCaret(); }
    private void OpenLatestReport() { var report = FindLatestReport(); if (report is null) MessageBox.Show(this, "No finalized WUPA report was found.", "No report yet", MessageBoxButtons.OK, MessageBoxIcon.Information); else OpenPath(report); }
    private void OpenBestFolder() { var report = FindLatestReport(); if (report is not null) OpenPath(Path.GetDirectoryName(report)!); }

    private string? FindLatestReport(DateTime? notBeforeUtc = null)
    {
        if (!string.IsNullOrWhiteSpace(_lastOutputPath)) { var known = Path.Combine(_lastOutputPath, "Report.html"); if (File.Exists(known) && (!notBeforeUtc.HasValue || File.GetLastWriteTimeUtc(known) >= notBeforeUtc.Value)) return known; }
        var parent = GetPublicDocuments();
        if (!Directory.Exists(parent)) return null;
        try { return Directory.EnumerateFiles(parent, "Report.html", SearchOption.AllDirectories).Select(path => new FileInfo(path)).Where(file => file.Directory?.Name.StartsWith("WUPA-", StringComparison.OrdinalIgnoreCase) == true).Where(file => !notBeforeUtc.HasValue || file.LastWriteTimeUtc >= notBeforeUtc.Value).OrderByDescending(file => file.LastWriteTimeUtc).FirstOrDefault()?.FullName; }
        catch { return null; }
    }

    private static int CurrentBuild() { try { using var key = Registry.LocalMachine.OpenSubKey(@"SOFTWARE\Microsoft\Windows NT\CurrentVersion"); return int.TryParse(key?.GetValue("CurrentBuild")?.ToString(), out var build) ? build : Environment.OSVersion.Version.Build; } catch { return Environment.OSVersion.Version.Build; } }
    private static string GetPublicDocuments() { var publicRoot = Environment.GetEnvironmentVariable("PUBLIC"); return !string.IsNullOrWhiteSpace(publicRoot) ? Path.Combine(publicRoot, "Documents") : Environment.GetFolderPath(Environment.SpecialFolder.CommonDocuments); }
    private static string ActionTitle(string action) => action switch { "Start" => "Starting update tracking", "Finish" => "Building the final report", "Analyze" => "Collecting retained update logs", "Cancel" => "Stopping tracking without a report", _ => "WUPA is working" };
    private static void OpenPath(string path) => Process.Start(new ProcessStartInfo(path) { UseShellExecute = true });
    private void OnClosing(object? sender, FormClosingEventArgs e) { if (!_busy) return; e.Cancel = true; MessageBox.Show(this, "WUPA is still collecting. Wait for this pass to finish before closing the app.", "Collection in progress", MessageBoxButtons.OK, MessageBoxIcon.Information); }
}

internal static class StartupFailureLog
{
    public static string? TryWrite(Exception exception)
    {
        try { var directory = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "WUPA"); Directory.CreateDirectory(directory); var path = Path.Combine(directory, "Gui-Startup-Failure.log"); File.AppendAllText(path, $"[{DateTime.UtcNow:O}] WUPA GUI startup failure{Environment.NewLine}{exception}{Environment.NewLine}{Environment.NewLine}", Encoding.UTF8); return path; }
        catch { return null; }
    }
}

internal sealed class ActiveRunInfo
{
    public string RunId { get; init; } = string.Empty;
    public string Status { get; init; } = string.Empty;
    public string TargetVersion { get; init; } = string.Empty;
    public string RunPath { get; init; } = string.Empty;
    public string? OutputPath { get; init; }
    public string RecorderStartStatus { get; init; } = string.Empty;
    public DateTime? ExpiresUtc { get; init; }
    public string ExpiresUtcLocal => ExpiresUtc?.ToLocalTime().ToString("g") ?? "unknown";
    public RunLockStatus ProbeRunLock() { if (string.IsNullOrWhiteSpace(RunPath)) return RunLockStatus.Unknown; var path = Path.Combine(RunPath, "State", "run.lock"); if (!File.Exists(path)) return RunLockStatus.NotHeld; try { using var stream = new FileStream(path, FileMode.Open, FileAccess.ReadWrite, FileShare.None); return RunLockStatus.NotHeld; } catch (FileNotFoundException) { return RunLockStatus.NotHeld; } catch (DirectoryNotFoundException) { return RunLockStatus.NotHeld; } catch (IOException) { return RunLockStatus.Held; } catch { return RunLockStatus.Unknown; } }
    public CollectorLogStatus? TryReadLatestCollectorStatus()
    {
        var path = Path.Combine(RunPath, "Collector.log");
        if (!File.Exists(path)) return null;
        try { const int tailBytes = 128 * 1024; using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete); stream.Seek(Math.Max(0, stream.Length - tailBytes), SeekOrigin.Begin); using var reader = new StreamReader(stream, Encoding.UTF8, true); var lines = reader.ReadToEnd().Split(new[] { "\r\n", "\n", "\r" }, StringSplitOptions.RemoveEmptyEntries); var line = lines.LastOrDefault(CollectorLogStatus.IsStructured) ?? lines.LastOrDefault(); return string.IsNullOrWhiteSpace(line) ? null : CollectorLogStatus.Parse(line.Trim()); }
        catch { return null; }
    }
    public static ActiveRunInfo? TryRead()
    {
        var path = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "WUPA", "ActiveRun.json");
        if (!File.Exists(path)) return null;
        try { using var document = JsonDocument.Parse(File.ReadAllText(path)); var root = document.RootElement; var recorderStatus = string.Empty; if (root.TryGetProperty("RecorderStart", out var recorder) && recorder.ValueKind == JsonValueKind.Object && recorder.TryGetProperty("Status", out var status)) recorderStatus = status.ToString(); return new ActiveRunInfo { RunId = ReadString(root, "RunId"), Status = ReadString(root, "Status"), TargetVersion = ReadString(root, "TargetVersion"), RunPath = ReadString(root, "RunPath"), OutputPath = ReadString(root, "OutputPath"), RecorderStartStatus = recorderStatus, ExpiresUtc = DateTime.TryParse(ReadString(root, "ExpiresUtc"), out var expires) ? expires.ToUniversalTime() : null }; }
        catch { return null; }
    }
    public static bool LegacyCaseExists() => File.Exists(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "Win11UpgradeDiag", "ActiveRun.json"));
    private static string ReadString(JsonElement root, string name) => root.TryGetProperty(name, out var value) ? value.ToString() : string.Empty;
}

internal enum RunLockStatus { NotHeld, Held, Unknown }

internal sealed class CollectorLogStatus
{
    private static readonly Regex Pattern = new(@"^(?<timestamp>\S+)\s+\[(?<level>DEBUG|INFO|WARN|ERROR)\]\s+(?<message>.*)$", RegexOptions.Compiled | RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);
    public string RawLine { get; }
    public string DisplayText { get; }
    private CollectorLogStatus(string raw, string display) { RawLine = raw; DisplayText = display; }
    public static bool IsStructured(string line) => Pattern.IsMatch(line.Trim());
    public static CollectorLogStatus Parse(string line) { var match = Pattern.Match(line); if (!match.Success) return new CollectorLogStatus(line, "Last collector status: " + line); var timestamp = DateTimeOffset.TryParse(match.Groups["timestamp"].Value, out var parsed) ? parsed.ToLocalTime().ToString("g") : match.Groups["timestamp"].Value; return new CollectorLogStatus(line, $"Last collector status ({timestamp}, {match.Groups["level"].Value.ToUpperInvariant()}): {match.Groups["message"].Value}"); }
}

internal sealed class BackendExecutionResult
{
    public int ExitCode { get; }
    public IReadOnlyList<string> Lines { get; }
    public bool RunLockCollision => Lines.Any(line => line.Contains("already handling this run", StringComparison.OrdinalIgnoreCase));
    public string? LastMessage => Lines.LastOrDefault(line => !string.IsNullOrWhiteSpace(line));
    public BackendExecutionResult(int exitCode, IReadOnlyList<string> lines) { ExitCode = exitCode; Lines = lines; }
}

internal static class PayloadManager
{
    private const string ResourcePrefix = "Payload/";
    public static string EnsureExtracted(string version)
    {
        var parent = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "WUPA", "Runtime");
        var destination = Path.Combine(parent, version);
        Directory.CreateDirectory(parent);
        if (Directory.Exists(destination)) { try { VerifyEmbeddedManifestMatches(destination); VerifyManifest(destination); return destination; } catch { Directory.Move(destination, destination + ".invalid-" + DateTime.UtcNow.ToString("yyyyMMddTHHmmssZ")); } }
        var staging = Path.Combine(parent, ".extract-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(staging);
        try
        {
            var assembly = Assembly.GetExecutingAssembly();
            var resources = assembly.GetManifestResourceNames().Where(name => name.StartsWith(ResourcePrefix, StringComparison.Ordinal)).ToArray();
            if (resources.Length == 0) throw new InvalidOperationException("The executable contains no WUPA collector payload.");
            var prefix = Path.GetFullPath(staging) + Path.DirectorySeparatorChar;
            foreach (var resource in resources) { var relative = resource[ResourcePrefix.Length..].Replace('/', Path.DirectorySeparatorChar); var target = Path.GetFullPath(Path.Combine(staging, relative)); if (!target.StartsWith(prefix, StringComparison.OrdinalIgnoreCase)) throw new InvalidOperationException("An embedded payload path left the extraction root."); Directory.CreateDirectory(Path.GetDirectoryName(target)!); using var input = assembly.GetManifestResourceStream(resource) ?? throw new InvalidOperationException($"Embedded resource was unreadable: {resource}"); using var output = new FileStream(target, FileMode.CreateNew, FileAccess.Write, FileShare.None); input.CopyTo(output); }
            VerifyManifest(staging);
            Directory.Move(staging, destination);
            return destination;
        }
        catch { try { if (Directory.Exists(staging)) Directory.Delete(staging, true); } catch { } throw; }
    }
    private static void VerifyEmbeddedManifestMatches(string root) { using var expectedStream = Assembly.GetExecutingAssembly().GetManifestResourceStream(ResourcePrefix + "BundleManifest.sha256") ?? throw new InvalidOperationException("The embedded bundle manifest is missing."); var expected = SHA256.HashData(expectedStream); using var actualStream = File.OpenRead(Path.Combine(root, "BundleManifest.sha256")); var actual = SHA256.HashData(actualStream); if (!CryptographicOperations.FixedTimeEquals(expected, actual)) throw new InvalidOperationException("The installed runtime belongs to a different WUPA build."); }
    private static void VerifyManifest(string root)
    {
        var manifest = Path.Combine(root, "BundleManifest.sha256");
        if (!File.Exists(manifest)) throw new InvalidOperationException("The embedded bundle manifest is missing.");
        var prefix = Path.GetFullPath(root) + Path.DirectorySeparatorChar;
        var verified = 0;
        foreach (var line in File.ReadLines(manifest)) { if (string.IsNullOrWhiteSpace(line) || line.TrimStart().StartsWith('#')) continue; var match = Regex.Match(line, "^([A-Fa-f0-9]{64})\\s+\\*?(.+)$"); if (!match.Success) throw new InvalidOperationException("The embedded bundle manifest is malformed."); var relative = match.Groups[2].Value.Trim().Replace('/', Path.DirectorySeparatorChar); var candidate = Path.GetFullPath(Path.Combine(root, relative)); if (!candidate.StartsWith(prefix, StringComparison.OrdinalIgnoreCase) || !File.Exists(candidate)) throw new InvalidOperationException($"Embedded payload file is missing or unsafe: {relative}"); using var stream = File.OpenRead(candidate); if (!Convert.ToHexString(SHA256.HashData(stream)).Equals(match.Groups[1].Value, StringComparison.OrdinalIgnoreCase)) throw new InvalidOperationException($"Embedded payload integrity check failed: {relative}"); verified++; }
        if (verified == 0) throw new InvalidOperationException("The embedded bundle manifest contains no file records.");
    }
}
