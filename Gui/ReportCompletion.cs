using System.Security.Cryptography;
using System.Text.Json;

namespace Wupa;

internal static class ReportCompletion
{
    // A written HTML file alone does not prove final packaging succeeded.
    internal static bool IsComplete(string reportPath)
    {
        try
        {
            var directory = Path.GetDirectoryName(reportPath)!;
            if (!File.Exists(reportPath) || File.Exists(Path.Combine(directory, "Report.pending"))) return false;
            var checksumsPath = Path.Combine(directory, "Checksums.sha256");
            if (!File.Exists(checksumsPath) || new FileInfo(checksumsPath).Length > 1024 * 1024) return false;
            var hashes = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            foreach (var line in File.ReadLines(checksumsPath))
            {
                if (line.Length < 67) continue;
                var name = line[64..].Trim();
                if (name is "Report.html" or "Summary.json" or "Manifest.json")
                    if (!hashes.TryAdd(name, line[..64])) return false;
            }
            foreach (var name in new[] { "Report.html", "Summary.json", "Manifest.json" })
            {
                if (!hashes.TryGetValue(name, out var hash)) return false;
                var path = Path.Combine(directory, name);
                if (!File.Exists(path) || new FileInfo(path).Length > 64 * 1024 * 1024) return false;
                using var stream = File.OpenRead(path);
                if (!Convert.ToHexString(SHA256.HashData(stream)).Equals(hash, StringComparison.OrdinalIgnoreCase)) return false;
            }
            using var manifest = JsonDocument.Parse(File.ReadAllText(Path.Combine(directory, "Manifest.json")));
            return manifest.RootElement.TryGetProperty("Artifacts", out var artifacts) && artifacts.ValueKind == JsonValueKind.Array &&
                artifacts.EnumerateArray().Any(a => a.TryGetProperty("Name", out var name) && name.GetString() == "Report.html" && a.TryGetProperty("Sha256", out var hash) && string.Equals(hash.GetString(), hashes["Report.html"], StringComparison.OrdinalIgnoreCase));
        }
        catch { return false; }
    }
}
