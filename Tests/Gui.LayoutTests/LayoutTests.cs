using System.Drawing.Imaging;
using System.Reflection;
using System.Text.Json;

namespace Wupa;

internal static class GuiLayoutTests
{
    private static readonly List<string> Checks = new();
    private static readonly List<object> Snapshots = new();

    [STAThread]
    private static int Main(string[] args)
    {
        Application.SetHighDpiMode(HighDpiMode.PerMonitorV2);
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        var output = Path.GetFullPath(args.FirstOrDefault() ?? "gui-layout-results");
        Directory.CreateDirectory(output);
        var fixture = Path.Combine(output, "tracking-fixture");
        Directory.CreateDirectory(fixture);
        File.WriteAllText(Path.Combine(fixture, "Collector.log"), "2026-10-01T16:00:00Z [INFO] Collecting native Windows Update, Update Orchestrator, and Delivery Optimization traces; rotated files and capture failures are recorded in the trace coverage manifest.");
        var active = new ActiveRunInfo { RunId = "layout-fixture", RunPath = fixture, TargetVersion = "25H2", RecorderStartStatus = "Started" };
        var status = active.TryReadLatestCollectorStatus();
        try
        {
            foreach (var state in new[] { "idle", "tracking", "held", "unknown-lock", "report", "newer-build", "legacy" })
            {
                using var form = new MainForm(prepareRuntime: false);
                form.Show();
                Apply(form, state, active, status);
                ValidateState(form, state);
                foreach (var size in new[] { new Size(740, 600), new Size(860, 640), new Size(1920, 1080) })
                {
                    form.WindowState = FormWindowState.Normal;
                    if (size.Width >= 1920)
                    {
                        // Render the actual production viewport offscreen at
                        // 1920x1080. A top-level Form is capped by CI's small
                        // desktop, so do not mislabel a clamped Form as wide.
                        var viewport = Field<Panel>(form, "_viewport");
                        viewport.Font = form.Font;
                        form.Controls.Remove(viewport);
                        viewport.Dock = DockStyle.None;
                        viewport.Size = size;
                        viewport.Visible = true;
                        viewport.CreateControl(); Settle(form);
                        Assert(viewport.Size == size, state + ": wide viewport has the requested native surface size");
                        using (var bitmap = new Bitmap(size.Width, size.Height)) { viewport.DrawToBitmap(bitmap, new Rectangle(Point.Empty, size)); bitmap.Save(Path.Combine(output, state + "-" + size.Width + ".png"), ImageFormat.Png); }
                        ValidateLayout(form, state + "-" + size.Width);
                        Snapshots.Add(new { Name = state + "-" + size.Width, Kind = "NativeViewport", Width = viewport.Width, Height = viewport.Height, Dpi = form.DeviceDpi });
                        form.Controls.Add(viewport);
                        viewport.Dock = DockStyle.Fill; Settle(form);
                        continue;
                    }
                    else form.ClientSize = size;
                    Settle(form);
                    Assert(form.Width >= size.Width && form.Height >= size.Height, state + ": requested snapshot size was not clamped");
                    ValidateLayout(form, state + "-" + size.Width);
                    Save(form, output, state + "-" + size.Width);
                }
                var bounds = form.Bounds;
                ActivateDetails(form); Settle(form);
                Save(form, output, state + "-log-open");
                Assert(Field<TextBox>(form, "_log").Height >= 150, state + $": expanded log has usable height (log={Field<TextBox>(form, "_log").Height}, panel={Field<Panel>(form, "_detailsPanel").Height})");
                Assert(form.Bounds == bounds, state + ": log toggle does not resize the window");
                ValidateLayout(form, state + "-log-open");
                ActivateDetails(form); Settle(form);
                form.WindowState = FormWindowState.Maximized; Settle(form);
                bounds = form.Bounds;
                ActivateDetails(form); Settle(form);
                Assert(form.WindowState == FormWindowState.Maximized && form.Bounds == bounds, state + ": log toggle preserves maximized state and bounds");
                ValidateLayout(form, state + "-maximized");
                Save(form, output, state + "-maximized");
                form.Close();
            }
            // Larger text is a layout stress test, not a claim of real 150/200%
            // monitor DPI. Actual forms use PerMonitorV2 and Dpi autoscaling.
            foreach (var scale in new[] { 1.5F, 2F })
            {
                using var form = new MainForm(prepareRuntime: false);
                form.Show();
                Apply(form, "tracking", active, status);
                var fonts = Descendants(form).Select(c => (Control: c, Font: c.Font)).ToArray();
                foreach (var entry in fonts) entry.Control.Font = new Font(entry.Font.FontFamily, entry.Font.Size * scale, entry.Font.Style);
                form.ClientSize = new Size(740, 600);
                Settle(form);
                ValidateLayout(form, "large-text-" + scale);
                Save(form, output, "large-text-" + scale.ToString(System.Globalization.CultureInfo.InvariantCulture));
                form.Close();
            }
            File.WriteAllText(Path.Combine(output, "Validation.json"), JsonSerializer.Serialize(new { Passed = true, Checks, Snapshots, Scope = "Native WinForms fixture rendering and layout; no collectors, runtime extraction, tasks or upgrade actions executed. Large-text cases are not real monitor-DPI validation." }, new JsonSerializerOptions { WriteIndented = true }));
            Console.WriteLine($"PASS: {Checks.Count} native GUI layout/state checks; snapshots in {output}");
            return 0;
        }
        catch (Exception ex)
        {
            File.WriteAllText(Path.Combine(output, "Validation.json"), JsonSerializer.Serialize(new { Passed = false, Checks, Error = ex.ToString() }, new JsonSerializerOptions { WriteIndented = true }));
            Console.Error.WriteLine(ex);
            return 1;
        }
    }

    private static void Apply(MainForm form, string state, ActiveRunInfo active, CollectorLogStatus? status)
    {
        var tracking = state is "tracking" or "held" or "unknown-lock";
        var build = state == "report" ? 26200 : state == "newer-build" ? 28000 : 22631;
        var runLock = state == "held" ? RunLockStatus.Held : state == "unknown-lock" ? RunLockStatus.Unknown : RunLockStatus.NotHeld;
        form.ApplyViewState(build, state == "legacy", tracking ? active : null, runLock, status, state == "report");
        Settle(form);
    }

    private static void ValidateState(MainForm form, string state)
    {
        var primary = Field<Button>(form, "_primary");
        var analyze = Field<LinkLabel>(form, "_analyze");
        var cancel = Field<LinkLabel>(form, "_cancel");
        var links = Field<FlowLayoutPanel>(form, "_reportLinks");
        if (state == "idle") Assert(primary.Text == "Start tracking" && analyze.Visible && !cancel.Visible && !links.Visible, "Idle exposes one primary start and an existing-log alternative, not unavailable report buttons");
        if (state == "tracking") Assert(primary.Text == "Finish tracking and build report" && primary.Enabled && cancel.Visible && !analyze.Visible, "Tracking distinguishes report-producing finish from stop-without-report");
        if (state is "held" or "unknown-lock") Assert(!primary.Enabled && !cancel.Enabled, state + ": destructive/duplicate run actions remain disabled");
        if (state == "report") Assert(primary.Text == "Create report from existing logs" && links.Visible && !analyze.Visible && !cancel.Visible, "Completed target offers retained-log report and actual report-folder links");
        if (state == "newer-build") Assert(!Field<Label>(form, "_status").Text.Contains("25H2 is installed"), "Newer Windows build cannot be labeled as 25H2");
        if (state == "legacy") Assert(!primary.Enabled && !analyze.Visible, "Legacy case still blocks a conflicting new recorder");
    }

    private static void ValidateLayout(MainForm form, string name)
    {
        var content = Field<TableLayoutPanel>(form, "_content");
        var viewport = Field<Panel>(form, "_viewport");
        Assert(!viewport.HorizontalScroll.Visible, name + ": no unnecessary horizontal page scrollbar");
        Assert(content.Width <= (int)Math.Ceiling(920 * form.DeviceDpi / 96D), name + ": content width is bounded");
        Assert(Math.Abs(content.Left - (viewport.ClientSize.Width - content.Width) / 2) <= 2, name + $": content stays centered (left={content.Left}, content={content.Width}, viewport={viewport.ClientSize.Width}, scroll={viewport.AutoScrollPosition})");
        foreach (var control in Descendants(content).Where(c => c.Visible && c.Parent is not null))
        {
            Assert(control.Right <= control.Parent!.ClientSize.Width + 2 && control.Left >= -2, name + ": horizontal bounds for " + control.GetType().Name);
            if (control is Label label && label.AutoSize && label.Text.Length > 0)
                Assert(label.GetPreferredSize(new Size(label.Width, 0)).Height <= label.Height + 2, name + ": label text is not vertically clipped: " + label.Text[..Math.Min(label.Text.Length, 35)]);
        }
        var children = content.Controls.Cast<Control>().Where(c => c.Visible).ToArray();
        for (var i = 0; i < children.Length; i++)
            for (var j = i + 1; j < children.Length; j++)
                Assert(!children[i].Bounds.IntersectsWith(children[j].Bounds), name + ": content rows do not overlap");
    }

    private static IEnumerable<Control> Descendants(Control parent) { foreach (Control child in parent.Controls) { yield return child; foreach (var nested in Descendants(child)) yield return nested; } }
    private static T Field<T>(MainForm form, string name) where T : Control => (T)(typeof(MainForm).GetField(name, BindingFlags.NonPublic | BindingFlags.Instance)?.GetValue(form) ?? throw new Exception("Missing control " + name));
    private static void Settle(MainForm form) { form.PerformLayout(); Application.DoEvents(); form.PerformLayout(); Application.DoEvents(); }
    private static void ActivateDetails(MainForm form) { var link = Field<LinkLabel>(form, "_details"); typeof(LinkLabel).GetMethod("OnLinkClicked", BindingFlags.Instance | BindingFlags.NonPublic)!.Invoke(link, new object[] { new LinkLabelLinkClickedEventArgs(link.Links[0]) }); }
    private static void Save(MainForm form, string output, string name) { using var bitmap = new Bitmap(form.Width, form.Height); form.DrawToBitmap(bitmap, new Rectangle(Point.Empty, form.Size)); bitmap.Save(Path.Combine(output, name + ".png"), ImageFormat.Png); Snapshots.Add(new { Name = name, Width = form.Width, Height = form.Height, ClientWidth = form.ClientSize.Width, ClientHeight = form.ClientSize.Height, Dpi = form.DeviceDpi }); }
    private static void Assert(bool condition, string message) { if (!condition) throw new InvalidOperationException(message); Checks.Add(message); }
}
