using System.Diagnostics;
using System.Runtime.InteropServices;

namespace Wupa;

internal sealed partial class MainForm
{
    private readonly LinkLabel _updateLink = new();
    private readonly LinkLabel _repairRun = new();
    private UpdateCore? _updater;
    private VerifiedUpdate? _availableUpdate;
    private VerifiedUpdate? _installedUpdate;
    private string _engineVersion = AppVersion;
    private bool _checkingUpdates;
    private string ProgramRoot => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "WUPA");

    private void BuildUpdateLinks()
    {
        ConfigureLink(_updateLink, "Check for updates");
        _updateLink.Dock = DockStyle.Top;
        _updateLink.Enabled = false;
        _updateLink.LinkClicked += async (_, _) => { if (_availableUpdate is null) await CheckForUpdatesAsync(true); else await ApplyAvailableUpdateAsync(); };
        ConfigureLink(_repairRun, "Apply updated engine to active tracking");
        _repairRun.Dock = DockStyle.Top;
        _repairRun.Visible = false;
        _repairRun.LinkClicked += async (_, _) => await RepairActiveRunAsync();
        _content.Controls.Add(_repairRun);
        _content.Controls.Add(_updateLink);
        Disposed += (_, _) => _updater?.Dispose();
    }

    private void InitializeUpdater()
    {
        _updater = new UpdateCore(UpdateCore.EmbeddedPublicKey(), AppendLog);
        var installed = _updater.FindInstalledEngine(ProgramRoot, AppVersion, AppVersion);
        if (installed is not null)
        {
            _runtimePath = installed.Value.Path;
            _installedUpdate = installed.Value.Update;
            _engineVersion = installed.Value.Update.Manifest.EngineVersion;
        }
        Text = $"WUPA {AppVersion}" + (_engineVersion == AppVersion ? "" : $" • engine {_engineVersion}");
        RefreshUpdateControls();
    }

    private bool CanMigrate(ActiveRunInfo active) => active.SchemaVersion == 2 &&
        (_installedUpdate is null ? new[] { "3.0.0", "3.1.0", "3.1.1", "3.2.0", "3.2.1" }.Contains(active.ToolVersion) :
            _installedUpdate.Manifest.StateSchemas.Contains(active.SchemaVersion) && _installedUpdate.Manifest.CompatiblePreviousEngines.Contains(active.ToolVersion));

    private void RefreshUpdateControls()
    {
        _updateLink.Enabled = !_busy && !_checkingUpdates && _updater is not null;
        _updateLink.Text = _checkingUpdates ? "Checking GitHub…" : _availableUpdate is null ? "Check for updates" : $"Update available: {_availableUpdate.Manifest.ReleaseVersion} — apply update";
        var active = ActiveRunInfo.TryRead();
        _repairRun.Visible = active is not null && (!string.Equals(active.RuntimePath, _runtimePath, StringComparison.OrdinalIgnoreCase) || active.HasPendingRuntimeUpdate());
        _repairRun.Text = $"Apply engine {_engineVersion} to this active run";
        _repairRun.Enabled = !_busy && active is not null && CanMigrate(active) && active.ProbeRunLock() == RunLockStatus.NotHeld && _runtimePath is not null;
        LayoutContent();
    }

    private async Task CheckForUpdatesAsync(bool interactive)
    {
        if (_updater is null || _busy || _checkingUpdates) return;
        _checkingUpdates = true; RefreshUpdateControls();
        try
        {
            _availableUpdate = await _updater.CheckAsync(_engineVersion);
            if (IsDisposed || Disposing) return;
            AppendLog(_availableUpdate is null ? "No newer stable release was found on GitHub." : $"Trusted update {_availableUpdate.Manifest.ReleaseVersion} is available. Operator approval is required.");
            if (interactive && _availableUpdate is null) MessageBox.Show(this, "No newer stable release is available.", "WUPA updates", MessageBoxButtons.OK, MessageBoxIcon.Information);
        }
        catch (Exception ex)
        {
            if (IsDisposed || Disposing) return;
            AppendLog("Update check unavailable; the current collector remains usable. " + ex.Message);
            if (interactive) MessageBox.Show(this, "The update check could not be verified or completed. WUPA can continue with its current engine.\n\n" + ex.Message, "WUPA updates", MessageBoxButtons.OK, MessageBoxIcon.Warning);
        }
        finally { _checkingUpdates = false; if (!IsDisposed) RefreshUpdateControls(); }
    }

    private async Task ApplyAvailableUpdateAsync()
    {
        if (_busy || _updater is null || _availableUpdate is null) return;
        var update = _availableUpdate;
        var fullApplication = UpdateCore.ParseVersion(update.Manifest.MinimumAppVersion) > UpdateCore.ParseVersion(AppVersion);
        var detail = fullApplication ? "Download and open the new portable EXE locally? The original EXE, including one on a network share, will not be overwritten. Existing tracking tasks are not changed by this download." : "Download and activate the verified collector engine? Existing tracking will not be migrated until you explicitly apply the engine to that run. Collected evidence is retained.";
        if (MessageBox.Show(this, detail, $"Apply WUPA {update.Manifest.ReleaseVersion}", MessageBoxButtons.YesNo, MessageBoxIcon.Question) != DialogResult.Yes) return;
        _busy = true; SetBusy(true); RefreshUpdateControls();
        try
        {
            if (fullApplication)
            {
                var architecture = RuntimeInformation.OSArchitecture == Architecture.Arm64 ? "win-arm64" : "win-x64";
                var path = await _updater.DownloadApplicationAsync(update, ProgramRoot, architecture);
                var asset = update.Manifest.Applications[architecture];
                UpdateCore.VerifyFile(path, asset.Length, asset.Sha256);
                AppendLog("Verified application downloaded locally: " + path);
                if (MessageBox.Show(this, "The verified replacement EXE is ready. Open it and close this window?", "WUPA update ready", MessageBoxButtons.YesNo, MessageBoxIcon.Question) == DialogResult.Yes)
                {
                    Process.Start(new ProcessStartInfo(path) { UseShellExecute = true });
                    _busy = false; Close(); return;
                }
            }
            else
            {
                _runtimePath = await _updater.InstallEngineAsync(update, ProgramRoot);
                _engineVersion = update.Manifest.EngineVersion; _installedUpdate = update;
                Text = $"WUPA {AppVersion} • engine {_engineVersion}";
                _availableUpdate = null;
                MessageBox.Show(this, "The verified engine is ready. If this computer has an older active tracking run, use Apply engine to this active run to update its scheduled tasks safely.", "WUPA engine updated", MessageBoxButtons.OK, MessageBoxIcon.Information);
            }
        }
        catch (Exception ex) { AppendLog("Update failed: " + ex); MessageBox.Show(this, ex.Message + "\n\nExisting evidence and scheduled tasks were not intentionally replaced by the download.", "WUPA update failed", MessageBoxButtons.OK, MessageBoxIcon.Error); }
        finally { _busy = false; if (!IsDisposed) { SetBusy(false); RefreshState(); } }
    }

    private async Task RepairActiveRunAsync()
    {
        var active = ActiveRunInfo.TryRead();
        if (_busy || active is null || _runtimePath is null || !CanMigrate(active)) return;
        if (MessageBox.Show(this, $"Apply engine {_engineVersion} to run {active.RunId}?\n\nWUPA will briefly pause its recorder, preserve the baseline and samples, update only this run's owned task actions, then restart tracking. The sampling interruption is recorded. Windows Update itself and SetupConfig hooks are not changed. Busy collectors are never replaced.", "Update this active run", MessageBoxButtons.YesNo, MessageBoxIcon.Question) != DialogResult.Yes) return;
        _busy = true; SetBusy(true); RefreshUpdateControls();
        try
        {
            var info = new ProcessStartInfo(Path.Combine(Environment.GetEnvironmentVariable("SystemRoot") ?? @"C:\Windows", "System32", "WindowsPowerShell", "v1.0", "powershell.exe")) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true, WorkingDirectory = _runtimePath };
            foreach (var argument in new[] { "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", Path.Combine(_runtimePath, "Update-WupaActiveRun.ps1"), "-RunId", active.RunId }) info.ArgumentList.Add(argument);
            using var process = new Process { StartInfo = info };
            process.OutputDataReceived += (_, e) => { if (e.Data is not null) AppendLog(e.Data); };
            process.ErrorDataReceived += (_, e) => { if (e.Data is not null) AppendLog("ERROR: " + e.Data); };
            if (!process.Start()) throw new IOException("Active-run update could not start.");
            process.BeginOutputReadLine(); process.BeginErrorReadLine(); await process.WaitForExitAsync(); process.WaitForExit();
            if (process.ExitCode != 0) throw new IOException($"Active-run update exited with code {process.ExitCode}. Review the collector log and State\\Updates journal. Original evidence is retained.");
            MessageBox.Show(this, "This run now uses the updated engine. Review the current recorder status before proceeding; its original baseline and samples were retained.", "Active run updated", MessageBoxButtons.OK, MessageBoxIcon.Information);
        }
        catch (Exception ex) { AppendLog(ex.ToString()); MessageBox.Show(this, ex.Message, "Active-run update", MessageBoxButtons.OK, MessageBoxIcon.Warning); }
        finally { _busy = false; SetBusy(false); RefreshState(); }
    }
}
