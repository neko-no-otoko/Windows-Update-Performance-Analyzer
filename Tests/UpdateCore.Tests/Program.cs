using System.IO.Compression;
using System.Net;
using System.Net.Http;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Wupa;

var fixture = Path.Combine(Path.GetTempPath(), "WUPA-UpdateTests-" + Guid.NewGuid().ToString("N"));
Directory.CreateDirectory(fixture);
using var signingKey = RSA.Create(3072);
using var otherKey = RSA.Create(3072);
using var core = new UpdateCore(signingKey.ExportSubjectPublicKeyInfoPem());
var checks = 0;
if (args.Length == 3 && args[0] == "--verify-release")
{
    using var publisher = new UpdateCore(File.ReadAllText(args[2]));
    var release = publisher.Verify(File.ReadAllBytes(Path.Combine(args[1], "WUPA-update.json")), File.ReadAllBytes(Path.Combine(args[1], "WUPA-update.sig")));
    UpdateCore.ExtractEngine(Path.Combine(args[1], release.Manifest.Engine.Name), Path.Combine(fixture, "published-engine"), release.Manifest.Engine, release.Manifest.EngineVersion);
    foreach (var asset in release.Manifest.Applications.Values) UpdateCore.VerifyFile(Path.Combine(args[1], asset.Name), asset.Length, asset.Sha256);
    Console.WriteLine("PASS: actual release signature, engine ZIP/payload and both executable hashes. " + release.Manifest.ReleaseVersion);
    return;
}
void Assert(bool condition, string text) { if (!condition) throw new Exception(text); checks++; Console.WriteLine("PASS: " + text); }
void Reject(Action action, string text) { try { action(); } catch (Exception) { Assert(true, text); return; } throw new Exception("Expected rejection: " + text); }
async Task RejectAsync(Func<Task> action, string text) { try { await action(); } catch (Exception) { Assert(true, text); return; } throw new Exception("Expected rejection: " + text); }
string Hash(byte[] bytes) => Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant();
byte[] Sign(byte[] bytes) => signingKey.SignData(bytes, HashAlgorithmName.SHA256, RSASignaturePadding.Pss);
var files = new Dictionary<string, byte[]>
{
    ["VERSION"] = Encoding.UTF8.GetBytes("3.2.1\n"),
    ["Invoke-Win11UpgradeDiag.ps1"] = Encoding.UTF8.GetBytes("# fixture only"),
    ["Watch-Win11Upgrade.ps1"] = Encoding.UTF8.GetBytes("# fixture only"),
    ["Update-WupaActiveRun.ps1"] = Encoding.UTF8.GetBytes("# fixture only"),
    ["Modules/example.psm1"] = Encoding.UTF8.GetBytes("# fixture only")
};
var contentManifest = Encoding.UTF8.GetBytes(string.Join('\n', files.Select(p => $"{Hash(p.Value)}  {p.Key}")) + "\n");
files["BundleManifest.sha256"] = contentManifest;
string MakeZip(string name, Dictionary<string, byte[]> entries)
{
    var path = Path.Combine(fixture, name);
    using var zip = ZipFile.Open(path, ZipArchiveMode.Create);
    foreach (var pair in entries) { var entry = zip.CreateEntry(pair.Key); using var stream = entry.Open(); stream.Write(pair.Value); }
    return path;
}
EngineAsset Asset(string path) => new("WUPA-engine-3.2.1.zip", new FileInfo(path).Length, Hash(File.ReadAllBytes(path)), Hash(contentManifest));
var archive = MakeZip("valid.zip", files);
var manifest = new UpdateManifest(1, "3.2.1", "3.2.1", "3.2.0", [2], ["3.1.1", "3.2.0"], Asset(archive), new());
var bytes = JsonSerializer.SerializeToUtf8Bytes(manifest);
var update = core.Verify(bytes, Sign(bytes));
Assert(update.Manifest.EngineVersion == "3.2.1", "Valid RSA-PSS signed manifest is accepted");
Reject(() => core.Verify(bytes, otherKey.SignData(bytes, HashAlgorithmName.SHA256, RSASignaturePadding.Pss)), "Wrong publisher signing key is rejected");
var tampered = bytes.ToArray(); tampered[20] ^= 1;
Reject(() => core.Verify(tampered, Sign(bytes)), "Tampered signed metadata is rejected");
var duplicate = Encoding.UTF8.GetBytes(Encoding.UTF8.GetString(bytes).Replace("\"SchemaVersion\":1", "\"SchemaVersion\":1,\"SchemaVersion\":1"));
Reject(() => core.Verify(duplicate, Sign(duplicate)), "Duplicate metadata fields are rejected even if signed");
var invalid = JsonSerializer.SerializeToUtf8Bytes(manifest with { EngineVersion = "3.2.1-preview" });
Reject(() => core.Verify(invalid, Sign(invalid)), "Prerelease/invalid version is rejected");
var wrongName = JsonSerializer.SerializeToUtf8Bytes(manifest with { Engine = manifest.Engine with { Name = "../../evil.zip" } });
Reject(() => core.Verify(wrongName, Sign(wrongName)), "Signed assets must use the fixed release naming contract");
Assert(!UpdateCore.AllowedUri(new Uri("http://github.com/foo")) && !UpdateCore.AllowedUri(new Uri("https://github.com.attacker.example/foo")) && !UpdateCore.AllowedUri(new Uri("https://user@github.com/foo")), "HTTP, lookalike hosts and credentials are rejected");
Assert(UpdateCore.AllowedUri(new Uri("https://release-assets.githubusercontent.com/test")), "GitHub's HTTPS asset redirect host is allowed");
foreach (var path in new[] { "../escape", "/absolute", "C:/escape", "foo\\bar", "a/../b", "foo:stream", "CON.txt", "trailing. ", "a//b" }) Reject(() => UpdateCore.SafeRelativePath(path), "Unsafe path rejected: " + path);
var extraction = Path.Combine(fixture, "extracted");
UpdateCore.ExtractEngine(archive, extraction, manifest.Engine, "3.2.1");
Assert(File.Exists(Path.Combine(extraction, "Modules", "example.psm1")), "Valid engine extracts with complete content verification");
var installed = Path.Combine(fixture, "Runtime", "3.2.1");
UpdateCore.CommitEngine(extraction, installed, manifest.Engine, "3.2.1");
Assert(Directory.Exists(installed) && !Directory.Exists(extraction), "Engine commit moves a verified versioned directory atomically");
var extra = new Dictionary<string, byte[]>(files) { ["extra.exe"] = [1] };
var extraZip = MakeZip("extra.zip", extra);
Reject(() => UpdateCore.ExtractEngine(extraZip, Path.Combine(fixture, "extra"), Asset(extraZip), "3.2.1"), "Undeclared payload files are rejected");
var slip = new Dictionary<string, byte[]>(files) { ["../escape.txt"] = [1] };
var slipZip = MakeZip("slip.zip", slip);
Reject(() => UpdateCore.ExtractEngine(slipZip, Path.Combine(fixture, "slip"), Asset(slipZip), "3.2.1"), "Zip-slip archive is rejected");
Assert(!File.Exists(Path.Combine(fixture, "escape.txt")), "Zip-slip rejection does not write outside staging");
var caseDuplicate = new Dictionary<string, byte[]>(files) { ["version"] = [1] };
var dupZip = MakeZip("duplicate.zip", caseDuplicate);
Reject(() => UpdateCore.ExtractEngine(dupZip, Path.Combine(fixture, "duplicate"), Asset(dupZip), "3.2.1"), "Case-insensitive duplicate entries are rejected");
var changed = new Dictionary<string, byte[]>(files) { ["Modules/example.psm1"] = [9] };
var changedZip = MakeZip("changed.zip", changed);
Reject(() => UpdateCore.ExtractEngine(changedZip, Path.Combine(fixture, "changed"), Asset(changedZip), "3.2.1"), "Changed inner payload is rejected despite matching outer ZIP hash");
Reject(() => UpdateCore.VerifyRuntime(installed, manifest.Engine.BundleManifestSha256, "3.2.2"), "Engine VERSION must match the signed release");

using var successHttp = new UpdateCore(signingKey.ExportSubjectPublicKeyInfoPem(), handler: new FixtureHandler((request, token) => Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent([1, 2, 3]) })));
var download = Path.Combine(fixture, "download.bin");
await successHttp.DownloadAsync(new Uri("https://github.com/test"), download, 3, Hash([1, 2, 3]), CancellationToken.None);
Assert(File.ReadAllBytes(download).SequenceEqual(new byte[] { 1, 2, 3 }), "Download verifies exact length and SHA-256");
await RejectAsync(() => successHttp.DownloadAsync(new Uri("https://github.com/test"), download, 3, Hash([1, 2, 3]), CancellationToken.None), "A preexisting download is not overwritten");
Assert(File.ReadAllBytes(download).SequenceEqual(new byte[] { 1, 2, 3 }), "Failed CreateNew preserves the preexisting file");
var linkedRuntime = Path.Combine(fixture, "linked-runtime");
UpdateCore.ExtractEngine(archive, linkedRuntime, manifest.Engine, "3.2.1");
Directory.CreateSymbolicLink(Path.Combine(linkedRuntime, "undeclared-link"), installed);
Reject(() => UpdateCore.VerifyRuntime(linkedRuntime, manifest.Engine.BundleManifestSha256, "3.2.1"), "Undeclared reparse directory is rejected without following it");
var truncated = Path.Combine(fixture, "truncated.bin");
await RejectAsync(() => successHttp.DownloadAsync(new Uri("https://github.com/test"), truncated, 4, Hash([1, 2, 3]), CancellationToken.None), "Truncated/wrong-length download is rejected");
Assert(!File.Exists(truncated), "Rejected download never becomes an installed file");
await RejectAsync(() => successHttp.DownloadAsync(new Uri("https://github.com/test"), Path.Combine(fixture, "hash.bin"), 3, new string('0', 64), CancellationToken.None), "Wrong download hash is rejected");
using var redirectHttp = new UpdateCore(signingKey.ExportSubjectPublicKeyInfoPem(), handler: new FixtureHandler((r, t) => { var response = new HttpResponseMessage(HttpStatusCode.Redirect); response.Headers.Location = new Uri("https://attacker.example/payload"); return Task.FromResult(response); }));
await RejectAsync(() => redirectHttp.DownloadAsync(new Uri("https://github.com/test"), Path.Combine(fixture, "redirect.bin"), 3, Hash([1, 2, 3]), CancellationToken.None), "Off-domain redirect cannot authorize execution");
using var offlineHttp = new UpdateCore(signingKey.ExportSubjectPublicKeyInfoPem(), handler: new FixtureHandler((r, t) => throw new HttpRequestException("Offline fixture")));
await RejectAsync(() => offlineHttp.CheckAsync("3.2.0"), "Offline update check fails independently of the installed engine");
using var canceled = new CancellationTokenSource(); canceled.Cancel();
await RejectAsync(() => successHttp.DownloadAsync(new Uri("https://github.com/test"), Path.Combine(fixture, "cancel.bin"), 3, Hash([1, 2, 3]), canceled.Token), "Canceled update is rejected");
var receipt = Path.Combine(fixture, "Updates", "engines", "3.2.1"); Directory.CreateDirectory(receipt);
File.WriteAllBytes(Path.Combine(receipt, "manifest.json"), bytes);
Assert(core.FindInstalledEngine(fixture, "3.2.0", "3.2.0") is null, "Interrupted receipt without a signature is ignored");
File.WriteAllBytes(Path.Combine(receipt, "manifest.sig"), Sign(bytes));
Assert(core.FindInstalledEngine(fixture, "3.2.0", "3.2.0")?.Update.Manifest.EngineVersion == "3.2.1", "Verified compatible cached engine works offline");
Assert(core.FindInstalledEngine(fixture, "3.2.2", "3.2.0") is null, "Cached engine cannot downgrade the embedded minimum");
Assert(core.FindInstalledEngine(fixture, "3.2.0", "3.1.1") is null, "A cached engine requiring a newer GUI is not executed");
using var releaseHttp = new UpdateCore(signingKey.ExportSubjectPublicKeyInfoPem(), handler: new FixtureHandler((request, token) =>
{
    var payload = request.RequestUri!.AbsolutePath.EndsWith("/latest") ? Encoding.UTF8.GetBytes("{\"draft\":false,\"prerelease\":false,\"tag_name\":\"v3.2.1\"}") :
        request.RequestUri.AbsolutePath.EndsWith("WUPA-update.json") ? bytes : request.RequestUri.AbsolutePath.EndsWith("WUPA-update.sig") ? Sign(bytes) : File.ReadAllBytes(archive);
    return Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent(payload) });
}));
Assert((await releaseHttp.CheckAsync("3.2.0"))?.Manifest.EngineVersion == "3.2.1", "GitHub latest metadata and signature are checked together");
var installRoot = Path.Combine(fixture, "full-install");
var committedRuntime = await releaseHttp.InstallEngineAsync(update, installRoot);
Assert(Directory.Exists(committedRuntime) && core.FindInstalledEngine(installRoot, "3.2.0", "3.2.0") is not null, "Full download/install transaction creates a reusable authenticated receipt");
await RejectAsync(() => releaseHttp.DownloadApplicationAsync(update, installRoot, "unsupported-rid"), "Unsupported executable architecture cannot be downloaded");
File.AppendAllText(Path.Combine(installed, "Modules", "example.psm1"), "tampered");
Assert(core.FindInstalledEngine(fixture, "3.2.0", "3.2.0") is null, "Tampered cached runtime is ignored instead of executed");
var busy = Path.Combine(fixture, "busy.lock"); using (var gate = new FileStream(busy, FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None)) Reject(() => { using var second = new FileStream(busy, FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None); }, "Concurrent update gate is exclusive");
var reportDirectory = Path.Combine(fixture, "report"); Directory.CreateDirectory(reportDirectory);
var report = Path.Combine(reportDirectory, "Report.html"); File.WriteAllText(report, "fixture");
Assert(!ReportCompletion.IsComplete(report), "HTML without final manifest/checksums is not presented as complete");
File.WriteAllText(Path.Combine(reportDirectory, "Summary.json"), "{}");
var reportHash = Hash(File.ReadAllBytes(report));
File.WriteAllText(Path.Combine(reportDirectory, "Manifest.json"), JsonSerializer.Serialize(new { Artifacts = new[] { new { Name = "Report.html", Sha256 = reportHash } } }));
File.WriteAllText(Path.Combine(reportDirectory, "Checksums.sha256"), string.Join('\n', new[] { "Report.html", "Summary.json", "Manifest.json" }.Select(name => Hash(File.ReadAllBytes(Path.Combine(reportDirectory, name))) + "  " + name)));
Assert(ReportCompletion.IsComplete(report), "Completed report has matching manifest and checksum proofs");
File.WriteAllText(Path.Combine(reportDirectory, "Report.pending"), "incomplete retry");
Assert(!ReportCompletion.IsComplete(report), "An interrupted retry cannot reuse an old completion proof");
File.Delete(Path.Combine(reportDirectory, "Report.pending")); File.AppendAllText(report, "tampered");
Assert(!ReportCompletion.IsComplete(report), "Changed HTML is not presented as an intact completed report");
Console.WriteLine($"PASS: {checks} updater integrity/transport/cache checks. Fixtures: {fixture}");

internal sealed class FixtureHandler(Func<HttpRequestMessage, CancellationToken, Task<HttpResponseMessage>> send) : HttpMessageHandler
{
    protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken token) => send(request, token);
}
