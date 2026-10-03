namespace GpuManager.Core;

public static class Policy
{
    public static readonly StringComparer Paths = StringComparer.OrdinalIgnoreCase;
    public static bool IsExe(string? path) => !string.IsNullOrWhiteSpace(path) && Path.IsPathFullyQualified(path) && Path.GetExtension(path).Equals(".exe", StringComparison.OrdinalIgnoreCase);
    public static string Decide(string mode, GpuNative.DisplayPath[] displays, GpuNative.DeviceState power,
        Client[] protectedApps, Client[] clients, IEnumerable<string> safe, double secondsSinceLast, int cooldown = 300)
    {
        if (mode == "Nvidia") return "Paused";
        if (displays.Length == 0 || !displays.Any(p => p.Internal) || displays.Any(p => !p.Internal || p.Nvidia)) return "DisplayInUse";
        if (!power.Present || power.Problem != 0) return "DeviceError";
        if (power.Power == "D3") return "AlreadyAsleep";
        if (protectedApps.Length > 0) return "ProtectedApp";
        if (power.Power != "D0") return "UnknownPower";
        if (secondsSinceLast < Math.Max(300, cooldown)) return "Cooldown";
        var known = safe.ToHashSet(Paths);
        if (clients.Any(c => string.IsNullOrEmpty(c.Path) || !known.Contains(c.Path))) return "UnknownClient";
        return "AllowReset";
    }
    public static string Authorization(string policy, bool manual, bool approved) => approved ? "Proceed" : manual || policy == "Ask" ? "Ask" : policy == "Notify" ? "Notify" : "Proceed";
    public static string Signature(IEnumerable<Client> clients) => string.Join("|", clients.Select(c => $"{c.Id}:{c.Started:O}:{c.Path.ToUpperInvariant()}").Order(StringComparer.Ordinal));
    public static bool ApprovalMatches(Approval? approval, DateTimeOffset now, Client[] clients) => approval is not null && now < approval.Expires && approval.Signature == Signature(clients);
    public static AppAssignment[] Merge(IEnumerable<AppAssignment> defaults, IEnumerable<AppOverride> overrides)
    {
        var result = new Dictionary<string, AppAssignment>(Paths);
        foreach (var app in defaults) if (IsExe(app.Path) && app.Gpu is >= 0 and <= 2) result[app.Path] = app;
        foreach (var app in overrides)
        {
            if (!IsExe(app.Path)) throw new InvalidDataException("Неверный путь приложения.");
            if (app.Disabled) result.Remove(app.Path);
            else if (app.Gpu is >= 0 and <= 2) result[app.Path] = new(app.Path, app.Gpu);
            else throw new InvalidDataException("Неверное назначение GPU.");
        }
        return result.Values.OrderBy(a => a.Path, Paths).ToArray();
    }
    public static BatterySummary Summarize(IReadOnlyList<BatterySample> samples)
    {
        var duration = samples.Count > 1 ? samples[^1].AwakeSeconds - samples[0].AwakeSeconds : 0;
        static double? Mean(IEnumerable<double?> xs) { var a = xs.Where(x => x.HasValue).Select(x => x!.Value).ToArray(); return a.Length > 0 ? Math.Round(a.Average(), 2) : null; }
        double? capacity = null;
        if (samples.Count > 1 && duration >= 30 && samples[0].RemainingMWh is > 0 and < uint.MaxValue && samples[^1].RemainingMWh is > 0 and < uint.MaxValue && samples[0].RemainingMWh >= samples[^1].RemainingMWh)
            capacity = Math.Round((samples[0].RemainingMWh - samples[^1].RemainingMWh) / 1000.0 / (duration / 3600), 2);
        return new(samples.Count, Math.Round(duration, 1), Mean(samples.Select(s => s.Watts)), capacity,
            Mean(samples.Select(s => s.CpuPercent)), samples.Count(s => s.GpuPower == "D3"));
    }
}
