namespace Wupa;

internal static class ReportLocator
{
    internal static string? Find(string publicDocuments, string? knownDirectory = null, DateTime? notBeforeUtc = null)
    {
        bool Accept(string path) => ReportCompletion.IsComplete(path) && (!notBeforeUtc.HasValue || File.GetLastWriteTimeUtc(path) >= notBeforeUtc.Value);
        if (!string.IsNullOrWhiteSpace(knownDirectory))
        {
            var known = Path.Combine(knownDirectory, "Report.html");
            if (Accept(known)) return known;
        }
        if (!Directory.Exists(publicDocuments)) return null;
        // Never recurse through all Public Documents (including legacy denied
        // junctions). Only immediate WUPA case folders are discovery candidates.
        var candidates = new List<string>();
        try
        {
            var options = new EnumerationOptions { RecurseSubdirectories = false, IgnoreInaccessible = true, AttributesToSkip = FileAttributes.ReparsePoint };
            foreach (var directory in Directory.EnumerateDirectories(publicDocuments, "WUPA-*", options))
            {
                var path = Path.Combine(directory, "Report.html");
                try { if (Accept(path)) candidates.Add(path); } catch { /* One inaccessible case does not hide other cases. */ }
            }
            return candidates.OrderByDescending(File.GetLastWriteTimeUtc).FirstOrDefault();
        }
        catch { return null; }
    }
}
