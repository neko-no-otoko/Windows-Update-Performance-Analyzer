using System.IO.Compression;
using System.Net;
using System.Net.Http;
using System.Reflection;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;

namespace Wupa;

internal sealed record UpdateAsset(string Name, long Length, string Sha256);
internal sealed record EngineAsset(string Name, long Length, string Sha256, string BundleManifestSha256);
internal sealed record UpdateManifest(int SchemaVersion, string ReleaseVersion, string EngineVersion, string MinimumAppVersion,
    int[] StateSchemas, string[] CompatiblePreviousEngines, EngineAsset Engine, Dictionary<string, UpdateAsset> Applications);
internal sealed record VerifiedUpdate(UpdateManifest Manifest, byte[] ManifestBytes, byte[] Signature);

// Only a release manifest authenticated by the embedded offline signing key
// can authorize code downloads. GitHub's checksum alone is not a trust root.
internal sealed class UpdateCore : IDisposable
{
    internal const string Repository = "neko-no-otoko/Windows-Update-Performance-Analyzer";
    internal const long MaximumEngineBytes = 32 * 1024 * 1024;
    internal const long MaximumApplicationBytes = 256 * 1024 * 1024;
    private readonly HttpClient _http;
    private readonly string _publicKey;
    private readonly Action<string> _log;
    private static readonly JsonSerializerOptions JsonOptions = new() { UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow };
    private static readonly Regex VersionPattern = new(@"^\d+\.\d+\.\d+$", RegexOptions.CultureInvariant);
    private static readonly Regex HashPattern = new(@"^[a-fA-F0-9]{64}$", RegexOptions.CultureInvariant);

    internal UpdateCore(string publicKey, Action<string>? log = null, HttpMessageHandler? handler = null)
    {
        _publicKey = publicKey;
        _log = log ?? (_ => { });
        _http = handler is null ? new HttpClient(new HttpClientHandler { AllowAutoRedirect = false }) : new HttpClient(handler);
        _http.Timeout = Timeout.InfiniteTimeSpan;
        _http.DefaultRequestHeaders.UserAgent.ParseAdd("WUPA-UpdateClient/3.2.0");
    }

    internal static string EmbeddedPublicKey()
    {
        using var stream = Assembly.GetExecutingAssembly().GetManifestResourceStream("Wupa.UpdatePublicKey") ?? throw new InvalidOperationException("The update verification key is missing.");
        using var reader = new StreamReader(stream);
        return reader.ReadToEnd();
    }

    internal static Version ParseVersion(string value)
    {
        if (value is null || !VersionPattern.IsMatch(value) || !Version.TryParse(value, out var version)) throw new InvalidDataException("Invalid stable release version.");
        return version;
    }

    internal VerifiedUpdate Verify(byte[] bytes, byte[] signature)
    {
        if (bytes.Length == 0 || bytes.Length > 64 * 1024 || signature.Length > 1024) throw new InvalidDataException("Update metadata exceeds its bounds.");
        using var rsa = RSA.Create();
        rsa.ImportFromPem(_publicKey);
        if (!rsa.VerifyData(bytes, signature, HashAlgorithmName.SHA256, RSASignaturePadding.Pss)) throw new CryptographicException("The update manifest signature is not trusted. Nothing was installed.");
        // Reject duplicate JSON keys instead of allowing last-key-wins parsing.
        using (var document = JsonDocument.Parse(bytes)) RejectDuplicateKeys(document.RootElement);
        var manifest = JsonSerializer.Deserialize<UpdateManifest>(bytes, JsonOptions) ?? throw new InvalidDataException("Empty update manifest.");
        if (manifest.SchemaVersion != 1 || manifest.Engine is null || manifest.Applications is null || manifest.StateSchemas is null || manifest.CompatiblePreviousEngines is null) throw new InvalidDataException("Unsupported update manifest schema.");
        ParseVersion(manifest.ReleaseVersion); ParseVersion(manifest.EngineVersion); ParseVersion(manifest.MinimumAppVersion);
        if (manifest.EngineVersion != manifest.ReleaseVersion) throw new InvalidDataException("Release and engine versions disagree.");
        foreach (var version in manifest.CompatiblePreviousEngines) ParseVersion(version);
        ValidateAsset(manifest.Engine.Name, manifest.Engine.Length, manifest.Engine.Sha256, $"WUPA-engine-{manifest.EngineVersion}.zip", MaximumEngineBytes);
        if (!HashPattern.IsMatch(manifest.Engine.BundleManifestSha256 ?? "")) throw new InvalidDataException("Missing engine content hash.");
        foreach (var pair in manifest.Applications)
        {
            if (pair.Key is not ("win-x64" or "win-arm64") || pair.Value is null) throw new InvalidDataException("Unsupported executable architecture.");
            ValidateAsset(pair.Value.Name, pair.Value.Length, pair.Value.Sha256, $"WUPA-{manifest.ReleaseVersion}-{pair.Key}.exe", MaximumApplicationBytes);
        }
        return new VerifiedUpdate(manifest, bytes, signature);
    }

    private static void RejectDuplicateKeys(JsonElement element)
    {
        if (element.ValueKind == JsonValueKind.Object)
        {
            var names = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (var property in element.EnumerateObject()) { if (!names.Add(property.Name)) throw new InvalidDataException("Duplicate update metadata field."); RejectDuplicateKeys(property.Value); }
        }
        else if (element.ValueKind == JsonValueKind.Array) foreach (var child in element.EnumerateArray()) RejectDuplicateKeys(child);
    }

    private static void ValidateAsset(string name, long length, string hash, string expected, long maximum)
    {
        if (name != expected || length <= 0 || length > maximum || !HashPattern.IsMatch(hash ?? "")) throw new InvalidDataException("Invalid update asset name, size or hash.");
    }

    internal static Uri ReleaseAssetUri(string version, string name) => new($"https://github.com/{Repository}/releases/download/v{ParseVersion(version)}/{Uri.EscapeDataString(name)}");

    internal static bool AllowedUri(Uri uri) => uri.Scheme == "https" && uri.IsDefaultPort && string.IsNullOrEmpty(uri.UserInfo) &&
        (uri.Host == "api.github.com" || uri.Host == "github.com" || uri.Host == "release-assets.githubusercontent.com" || uri.Host == "objects.githubusercontent.com");

    private async Task<HttpResponseMessage> GetAsync(Uri uri, CancellationToken token)
    {
        for (var hop = 0; hop < 5; hop++)
        {
            if (!AllowedUri(uri)) throw new InvalidDataException("Update download redirected outside the allowed GitHub HTTPS hosts.");
            using var request = new HttpRequestMessage(HttpMethod.Get, uri);
            var response = await _http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, token);
            if ((int)response.StatusCode is >= 300 and < 400)
            {
                var location = response.Headers.Location;
                response.Dispose();
                if (location is null) throw new InvalidDataException("Update redirect has no destination.");
                uri = location.IsAbsoluteUri ? location : new Uri(uri, location);
                continue;
            }
            try { response.EnsureSuccessStatusCode(); }
            catch { response.Dispose(); throw; }
            return response;
        }
        throw new InvalidDataException("Too many update redirects.");
    }

    private async Task<byte[]> ReadBoundedAsync(Uri uri, int limit, CancellationToken token)
    {
        using var response = await GetAsync(uri, token);
        if (response.Content.Headers.ContentLength > limit) throw new InvalidDataException("Update metadata is too large.");
        using var input = await response.Content.ReadAsStreamAsync(token);
        using var output = new MemoryStream();
        var buffer = new byte[8192]; int count;
        while ((count = await input.ReadAsync(buffer, token)) > 0) { if (output.Length + count > limit) throw new InvalidDataException("Update metadata is too large."); await output.WriteAsync(buffer.AsMemory(0, count), token); }
        return output.ToArray();
    }

    internal async Task<VerifiedUpdate?> CheckAsync(string currentEngine)
    {
        using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(8));
        var releaseBytes = await ReadBoundedAsync(new Uri($"https://api.github.com/repos/{Repository}/releases/latest"), 256 * 1024, deadline.Token);
        using var release = JsonDocument.Parse(releaseBytes);
        var root = release.RootElement;
        if (root.GetProperty("draft").GetBoolean() || root.GetProperty("prerelease").GetBoolean()) return null;
        var tag = root.GetProperty("tag_name").GetString() ?? "";
        if (!tag.StartsWith('v')) throw new InvalidDataException("Unexpected release tag.");
        var version = tag[1..];
        if (ParseVersion(version) <= ParseVersion(currentEngine)) return null;
        var manifestBytes = await ReadBoundedAsync(ReleaseAssetUri(version, "WUPA-update.json"), 64 * 1024, deadline.Token);
        var signature = await ReadBoundedAsync(ReleaseAssetUri(version, "WUPA-update.sig"), 1024, deadline.Token);
        var verified = Verify(manifestBytes, signature);
        if (verified.Manifest.ReleaseVersion != version) throw new InvalidDataException("Release tag and signed manifest disagree.");
        return verified;
    }

    internal async Task DownloadAsync(Uri uri, string path, long length, string hash, CancellationToken token)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        var drive = new DriveInfo(Path.GetPathRoot(Path.GetFullPath(path))!);
        if (drive.IsReady && drive.AvailableFreeSpace < length * 2 + 16 * 1024 * 1024) throw new IOException("Insufficient local space to stage this update.");
        using var response = await GetAsync(uri, token);
        if (response.Content.Headers.ContentLength is long announced && announced != length) throw new InvalidDataException("Update download length does not match the signed manifest.");
        var created = false;
        try
        {
            using (var input = await response.Content.ReadAsStreamAsync(token))
            using (var output = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.None, 65536, true))
            {
                created = true;
                var buffer = new byte[65536]; int count; long total = 0;
                while ((count = await input.ReadAsync(buffer, token)) > 0) { total += count; if (total > length) throw new InvalidDataException("Update exceeds the signed size."); await output.WriteAsync(buffer.AsMemory(0, count), token); }
                if (total != length) throw new InvalidDataException("Update download was truncated.");
            }
            VerifyFile(path, length, hash);
        }
        catch { if (created && File.Exists(path)) File.Delete(path); throw; }
    }

    internal static void VerifyFile(string path, long length, string hash)
    {
        if (new FileInfo(path).Length != length) throw new InvalidDataException("Update file size is incorrect.");
        using var stream = File.OpenRead(path);
        if (!Convert.ToHexString(SHA256.HashData(stream)).Equals(hash, StringComparison.OrdinalIgnoreCase)) throw new CryptographicException("Update file hash is incorrect.");
    }

    internal static string SafeRelativePath(string name)
    {
        if (string.IsNullOrWhiteSpace(name) || name.Contains('\\') || name.Contains(':') || name.StartsWith('/') || name.Split('/').Any(p => p is "" or "." or ".." || p.EndsWith('.') || p.EndsWith(' ') || p.Any(c => c < 32) || p.IndexOfAny(['<', '>', '"', '|', '?', '*']) >= 0 || Regex.IsMatch(p, @"^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)", RegexOptions.IgnoreCase))) throw new InvalidDataException("Unsafe update archive path.");
        return name.Replace('/', Path.DirectorySeparatorChar);
    }

    internal static void ExtractEngine(string archivePath, string destination, EngineAsset asset, string version)
    {
        VerifyFile(archivePath, asset.Length, asset.Sha256);
        if (Directory.Exists(destination)) throw new IOException("The staging directory already exists.");
        Directory.CreateDirectory(destination);
        using var archive = ZipFile.OpenRead(archivePath);
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase); long total = 0;
        if (archive.Entries.Count > 1024) throw new InvalidDataException("Too many engine archive entries.");
        foreach (var entry in archive.Entries)
        {
            var name = entry.FullName;
            var isDirectory = name.EndsWith('/');
            var relative = SafeRelativePath(isDirectory ? name[..^1] : name);
            if (!seen.Add(relative) || ((entry.ExternalAttributes >> 16) & 0xF000) == 0xA000) throw new InvalidDataException("Duplicate path or symbolic link in engine archive.");
            total += entry.Length;
            if (total > MaximumEngineBytes || entry.Length > MaximumEngineBytes) throw new InvalidDataException("Engine archive expands beyond its limit.");
            var target = Path.Combine(destination, relative);
            if (isDirectory) { Directory.CreateDirectory(target); continue; }
            Directory.CreateDirectory(Path.GetDirectoryName(target)!);
            using var input = entry.Open();
            using var output = new FileStream(target, FileMode.CreateNew, FileAccess.Write, FileShare.None);
            var buffer = new byte[65536]; int count; long written = 0;
            while ((count = input.Read(buffer)) > 0) { written += count; if (written > entry.Length) throw new InvalidDataException("Engine entry exceeds its declared size."); output.Write(buffer, 0, count); }
            if (written != entry.Length) throw new InvalidDataException("Engine archive entry is truncated.");
        }
        VerifyRuntime(destination, asset.BundleManifestSha256, version);
    }

    internal static void VerifyRuntime(string root, string manifestHash, string version)
    {
        AssertNoReparseAncestors(root);
        var actualFiles = EnumerateSafeFiles(root).ToArray();
        var manifestPath = Path.Combine(root, "BundleManifest.sha256");
        using (var stream = File.OpenRead(manifestPath)) if (!Convert.ToHexString(SHA256.HashData(stream)).Equals(manifestHash, StringComparison.OrdinalIgnoreCase)) throw new CryptographicException("Engine content manifest is not the signed one.");
        var allowed = new HashSet<string>(StringComparer.OrdinalIgnoreCase) { "BundleManifest.sha256" };
        foreach (var line in File.ReadLines(manifestPath))
        {
            if (string.IsNullOrWhiteSpace(line) || line.StartsWith('#')) continue;
            var match = Regex.Match(line, @"^([a-fA-F0-9]{64})\s+\*?(.+)$");
            if (!match.Success) throw new InvalidDataException("Malformed engine content manifest.");
            var relative = SafeRelativePath(match.Groups[2].Value);
            if (!allowed.Add(relative)) throw new InvalidDataException("Duplicate engine content manifest entry.");
            var path = Path.Combine(root, relative);
            for (var parent = Path.GetDirectoryName(path); parent is not null && parent != Path.GetFullPath(root); parent = Path.GetDirectoryName(parent)) if ((new DirectoryInfo(parent).Attributes & FileAttributes.ReparsePoint) != 0) throw new InvalidDataException("Runtime contains a reparse directory.");
            if ((File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0) throw new InvalidDataException("Runtime contains a reparse file.");
            using var stream = File.OpenRead(path);
            if (!Convert.ToHexString(SHA256.HashData(stream)).Equals(match.Groups[1].Value, StringComparison.OrdinalIgnoreCase)) throw new CryptographicException("Runtime payload hash mismatch.");
        }
        foreach (var required in new[] { "Invoke-Win11UpgradeDiag.ps1", "Watch-Win11Upgrade.ps1", "Update-WupaActiveRun.ps1", "VERSION" }) if (!allowed.Contains(required)) throw new InvalidDataException("Required engine entry point is missing.");
        foreach (var path in actualFiles) if (!allowed.Contains(Path.GetRelativePath(root, path))) throw new InvalidDataException("Undeclared file in engine runtime.");
        if (File.ReadAllText(Path.Combine(root, "VERSION")).Trim() != version) throw new InvalidDataException("Engine VERSION does not match the signed release.");
    }

    private static void AssertNoReparseAncestors(string path)
    {
        // Windows staging must never follow a junction into an unrelated folder.
        // macOS /tmp is itself a symlink; production staging is Windows-only.
        if (!OperatingSystem.IsWindows()) return;
        for (var cursor = Path.GetFullPath(path); cursor is not null; cursor = Path.GetDirectoryName(cursor))
            if ((Directory.Exists(cursor) || File.Exists(cursor)) && (File.GetAttributes(cursor) & FileAttributes.ReparsePoint) != 0)
                throw new InvalidDataException("Update paths cannot contain reparse points.");
    }

    private static IEnumerable<string> EnumerateSafeFiles(string root)
    {
        if ((File.GetAttributes(root) & FileAttributes.ReparsePoint) != 0) throw new InvalidDataException("Runtime is a reparse point.");
        foreach (var path in Directory.EnumerateFileSystemEntries(root))
        {
            var attributes = File.GetAttributes(path);
            if ((attributes & FileAttributes.ReparsePoint) != 0) throw new InvalidDataException("Runtime contains a reparse point.");
            if ((attributes & FileAttributes.Directory) != 0) { foreach (var file in EnumerateSafeFiles(path)) yield return file; }
            else yield return path;
        }
    }

    internal static void CommitEngine(string staging, string destination, EngineAsset asset, string version)
    {
        VerifyRuntime(staging, asset.BundleManifestSha256, version);
        Directory.CreateDirectory(Path.GetDirectoryName(destination)!);
        if (Directory.Exists(destination)) { VerifyRuntime(destination, asset.BundleManifestSha256, version); return; }
        Directory.Move(staging, destination); // Same-volume atomic commit; no overwrite.
    }

    internal async Task<string> InstallEngineAsync(VerifiedUpdate update, string programRoot)
    {
        var updates = PrepareUpdatesRoot(programRoot);
        using var gate = new FileStream(Path.Combine(updates, "update.lock"), FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None);
        var transaction = Path.Combine(updates, "stage-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(transaction);
        var manifest = update.Manifest;
        using var timeout = new CancellationTokenSource(TimeSpan.FromMinutes(2));
        var zip = Path.Combine(transaction, manifest.Engine.Name);
        await DownloadAsync(ReleaseAssetUri(manifest.ReleaseVersion, manifest.Engine.Name), zip, manifest.Engine.Length, manifest.Engine.Sha256, timeout.Token);
        var staging = Path.Combine(transaction, "engine");
        ExtractEngine(zip, staging, manifest.Engine, manifest.EngineVersion);
        var destination = Path.Combine(programRoot, "Runtime", manifest.EngineVersion);
        CommitEngine(staging, destination, manifest.Engine, manifest.EngineVersion);
        var receipt = Path.Combine(updates, "engines", manifest.EngineVersion);
        Directory.CreateDirectory(receipt);
        File.WriteAllBytes(Path.Combine(receipt, "manifest.json"), update.ManifestBytes);
        // The signature is the commit marker. On launch incomplete receipts are ignored.
        File.WriteAllBytes(Path.Combine(receipt, "manifest.sig"), update.Signature);
        _log($"Verified engine {manifest.EngineVersion} staged at {destination}. Existing runs have not been migrated yet.");
        return destination;
    }

    internal (string Path, VerifiedUpdate Update)? FindInstalledEngine(string programRoot, string minimumVersion, string applicationVersion)
    {
        var receipts = Path.Combine(programRoot, "Updates", "engines");
        if (!Directory.Exists(receipts)) return null;
        (string Path, VerifiedUpdate Update)? selected = null;
        foreach (var receipt in Directory.EnumerateDirectories(receipts))
        {
            try
            {
                var update = Verify(File.ReadAllBytes(Path.Combine(receipt, "manifest.json")), File.ReadAllBytes(Path.Combine(receipt, "manifest.sig")));
                var version = ParseVersion(update.Manifest.EngineVersion);
                if (version < ParseVersion(minimumVersion) || ParseVersion(update.Manifest.MinimumAppVersion) > ParseVersion(applicationVersion) || Path.GetFileName(receipt) != update.Manifest.EngineVersion) continue;
                var path = Path.Combine(programRoot, "Runtime", update.Manifest.EngineVersion);
                VerifyRuntime(path, update.Manifest.Engine.BundleManifestSha256, update.Manifest.EngineVersion);
                if (selected is null || version > ParseVersion(selected.Value.Update.Manifest.EngineVersion)) selected = (path, update);
            }
            catch (Exception ex) { _log("Ignored an unverified cached engine: " + ex.Message); }
        }
        return selected;
    }

    internal async Task<string> DownloadApplicationAsync(VerifiedUpdate update, string programRoot, string architecture)
    {
        if (!update.Manifest.Applications.TryGetValue(architecture, out var asset)) throw new InvalidDataException("No signed executable for this architecture.");
        var updates = PrepareUpdatesRoot(programRoot);
        using var gate = new FileStream(Path.Combine(updates, "update.lock"), FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None);
        var directory = Path.Combine(updates, "app-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        var path = Path.Combine(directory, asset.Name);
        using var timeout = new CancellationTokenSource(TimeSpan.FromMinutes(5));
        await DownloadAsync(ReleaseAssetUri(update.Manifest.ReleaseVersion, asset.Name), path, asset.Length, asset.Sha256, timeout.Token);
        return path;
    }

    private static string PrepareUpdatesRoot(string programRoot)
    {
        AssertNoReparseAncestors(programRoot);
        AssertNoReparseAncestors(Path.Combine(programRoot, "Runtime"));
        var updates = Path.Combine(programRoot, "Updates");
        AssertNoReparseAncestors(updates);
        Directory.CreateDirectory(updates);
        if (OperatingSystem.IsWindows())
        {
            var start = new System.Diagnostics.ProcessStartInfo("icacls.exe") { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true };
            foreach (var arg in new[] { updates, "/inheritance:r", "/grant:r", "*S-1-5-18:(OI)(CI)F", "*S-1-5-32-544:(OI)(CI)F" }) start.ArgumentList.Add(arg);
            using var process = System.Diagnostics.Process.Start(start) ?? throw new IOException("Could not secure update staging.");
            var output = process.StandardOutput.ReadToEndAsync(); var error = process.StandardError.ReadToEndAsync();
            if (!process.WaitForExit(10000)) { process.Kill(); throw new IOException("Update ACL verification timed out."); }
            if (process.ExitCode != 0) throw new IOException("Could not restrict update staging to SYSTEM and Administrators.");
        }
        return updates;
    }

    public void Dispose() => _http.Dispose();
}
