namespace GpuManager.Core;

public sealed class Config
{
    public int Version { get; set; } = 7;
    public string DeviceId { get; set; } = "";
    public int SettleSeconds { get; set; } = 15;
    public int CooldownSeconds { get; set; } = 300;
    public int PendingLifetimeMinutes { get; set; } = 30;
    public string[] ProtectedProcessNames { get; set; } = [];
    public string[] EverydayExecutables { get; set; } = [];
    public string[] PerformanceExecutables { get; set; } = [];
    public string[] ManualPerformanceExecutables { get; set; } = [];
    public string[] PackagePatterns { get; set; } = [];
    public string[] PackageExecutableNames { get; set; } = [];
    public string[] PackageFamilies { get; set; } = ["OpenAI.Codex_2p2nqsd0c76g0", "5319275A.WhatsAppDesktop_cv1g1gvanyjgm", "MSTeams_8wekyb3d8bbwe"];
    public string[] ResetTolerantExecutableNames { get; set; } = [];
}
public sealed record AppAssignment(string Path, int Gpu);
public sealed record AppOverride(string Path, int Gpu, bool Disabled = false);
public sealed record PreferenceBackup(string Path, bool Existed, string? Value);
public sealed class Options
{
    public string ResetPolicy { get; set; } = "Auto";
    public string[] ProtectedPaths { get; set; } = [];
    public void Validate()
    {
        if (ResetPolicy is not ("Auto" or "Ask" or "Notify")) throw new InvalidDataException("Неизвестная политика сброса.");
        if (ProtectedPaths is null || ProtectedPaths.Length > 512 || ProtectedPaths.Any(p => !Policy.IsExe(p))) throw new InvalidDataException("Неверный список защищённых программ.");
    }
}
public sealed record Client(int Id, string Name, string Path, DateTimeOffset? Started = null);
public sealed record Command(string Action, string Value = "", int Minutes = 120, string Label = "");
public sealed record ModeState(string Mode = "Auto", DateTimeOffset? Until = null, bool Forever = false);
public sealed record Approval(string Id, DateTimeOffset Expires, string Signature, Client[] Clients);
public sealed class Snapshot
{
    public int Version { get; set; } = 7;
    public DateTimeOffset Time { get; set; } = DateTimeOffset.Now;
    public DateTimeOffset Heartbeat { get; set; } = DateTimeOffset.Now;
    public string Mode { get; set; } = "Auto";
    public DateTimeOffset? Until { get; set; }
    public string PowerLine { get; set; } = "Unknown";
    public string Status { get; set; } = "";
    public DateTimeOffset? Pending { get; set; }
    public string Reason { get; set; } = "";
    public string GpuPower { get; set; } = "Unknown";
    public Client[] Clients { get; set; } = [];
    public string[] Blockers { get; set; } = [];
    public GpuNative.DisplayPath[] Displays { get; set; } = [];
    public int ProcessId { get; set; } = Environment.ProcessId;
    public DateTimeOffset AgentStarted { get; set; } = DateTimeOffset.Now;
    public Approval? Approval { get; set; }
    public string ResetPolicy { get; set; } = "Auto";
    public bool ObservingOnly { get; set; }
}
public sealed record Diagnosis(DateTimeOffset Time, GpuNative.DeviceState Power, string Decision, string Explanation,
    Client[] Clients, Client[] Protected, GpuNative.DisplayPath[] Displays, string[] Errors);
public sealed record BatterySample(DateTimeOffset Time, double AwakeSeconds, double? Watts, uint RemainingMWh,
    double Percent, double? CpuPercent, string GpuPower, string ActiveApplications);
public sealed record BatterySummary(int Samples, double DurationSeconds, double? MeanDischargeWatts,
    double? CapacityDeltaWatts, double? MeanCpuPercent, int D3Samples);
public sealed class BatterySession
{
    public string Id { get; set; } = "";
    public string Label { get; set; } = "";
    public DateTimeOffset Started { get; set; }
    public DateTimeOffset? Ended { get; set; }
    public double AwakeStart { get; set; }
    public int Minutes { get; set; }
    public string Mode { get; set; } = "Auto";
    public int[] Brightness { get; set; } = [];
    public List<BatterySample> Samples { get; set; } = [];
    public bool Complete { get; set; }
    public bool Valid { get; set; } = true;
    public string EndReason { get; set; } = "";
    public BatterySummary? Summary { get; set; }
}
