using Microsoft.Win32;
using GpuManager.Core;

var total = 0;
void Assert(bool condition, string name) { if (!condition) throw new Exception("FAIL: " + name); Console.WriteLine("PASS: " + name); total++; }
var directory = Path.Combine(Path.GetTempPath(), "GpuManagerTests-" + Guid.NewGuid().ToString("N"));
Directory.CreateDirectory(directory);
try
{
    Assert(new Store(directory + Path.DirectorySeparatorChar).Root == new Store(directory).Root, "Shortcut and scheduled-task roots share one panel and data lock");
    var internalDisplay = new[] { new GpuNative.DisplayPath { Key = "internal", Internal = true } };
    var externalDisplay = new[] { new GpuNative.DisplayPath { Key = "external", Nvidia = true, Internal = false } };
    var power = new GpuNative.DeviceState { Id = "fixture", Present = true, Problem = 0, Power = "D0" };
    var safePath = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), "System32", "dwm.exe");
    var client = new Client(42, "dwm", safePath, DateTimeOffset.Parse("2026-01-01T00:00:00Z"));
    Assert(Policy.Decide("Auto", externalDisplay, power, [], [], [safePath], 9999) == "DisplayInUse", "External display blocks reset");
    Assert(Policy.Decide("Auto", [], power, [], [], [], 9999) == "DisplayInUse", "No topology blocks reset");
    Assert(Policy.Decide("Nvidia", internalDisplay, power, [], [], [], 9999) == "Paused", "Paused mode blocks reset");
    Assert(Policy.Decide("Auto", internalDisplay, power, [client], [], [safePath], 9999) == "ProtectedApp", "Protected work blocks reset");
    Assert(Policy.Decide("Auto", internalDisplay, power, [], [new(4, "unknown", "")], [safePath], 9999) == "UnknownClient", "Unreadable client blocks reset");
    Assert(Policy.Decide("Auto", internalDisplay, power, [], [client], [safePath], 10) == "Cooldown", "Cooldown blocks reset");
    var asleep = new GpuNative.DeviceState { Present = true, Power = "D3" };
    Assert(Policy.Decide("Auto", internalDisplay, asleep, [client], [], [], 9999) == "AlreadyAsleep", "D3 requires no reset even with an open protected process");
    Assert(Policy.Authorization("Auto", true, false) == "Ask", "Manual request always asks");
    Assert(Policy.Authorization("Notify", false, false) == "Notify", "Notify cannot automatically reset");
    var approval = new Approval("test", DateTimeOffset.Now.AddSeconds(90), Policy.Signature([client]), [client]);
    Assert(!Policy.ApprovalMatches(approval, DateTimeOffset.Now, [client with { Started = client.Started!.Value.AddSeconds(1) }]), "PID reuse invalidates approval");
    Assert(!Policy.ApprovalMatches(approval, approval.Expires, [client]), "Expired approval rejected");
    var merged = Policy.Merge([new(@"C:\default.exe", 1), new(@"C:\removed.exe", 2)], [new(@"C:\default.exe", 0), new(@"C:\removed.exe", 0, true)]);
    Assert(merged.Length == 1 && merged[0].Gpu == 0, "User system choice and tombstone override defaults");
    Assert(Preferences.Value("GpuPreference=2;OtherToken=keep;", 0) == "GpuPreference=0;OtherToken=keep;", "Registry tokens preserved");
    var summary = Policy.Summarize([new(DateTimeOffset.Now, 0, 12, 40000, 90, null, "D0", ""), new(DateTimeOffset.Now, 300, 18, 38750, 88, 20, "D3", "")]);
    Assert(summary.MeanDischargeWatts == 15 && summary.CapacityDeltaWatts == 15 && summary.MeanCpuPercent == 20 && summary.D3Samples == 1, "Battery units, absent CPU and mean calculation");
    Assert(Policy.Summarize([]).MeanDischargeWatts is null, "Absent battery data is not zero watts");
    var migration = new Store(Path.Combine(directory, "migration")); Directory.CreateDirectory(migration.Data);
    // Use the exact JSON representation written by v6 for a one-item list.
    File.WriteAllText(Path.Combine(migration.Data, "app-overrides.json"), System.Text.Json.JsonSerializer.Serialize(new AppOverride(@"C:\legacy.exe", 0), Store.Json), new System.Text.UTF8Encoding(true));
    Assert(migration.List<AppOverride>("app-overrides.json").Single().Gpu == 0, "Legacy BOM and single-object list migration");
    var fixturePath = Path.Combine(directory, "fixture.exe"); var prefs = new Preferences(migration, new Config { PackageFamilies = [] });
    using (var key = Registry.CurrentUser.CreateSubKey(Preferences.RegistryPath)) key.SetValue(fixturePath, "GpuPreference=2;OtherToken=keep;");
    try
    {
        prefs.Change(fixturePath, "0"); Assert(prefs.Actual(fixturePath) == "GpuPreference=0;OtherToken=keep;", "Changing to Windows choice persisted");
        prefs.Change(fixturePath, "1"); prefs.Change(fixturePath, "Remove"); Assert(prefs.Actual(fixturePath) == "GpuPreference=1;OtherToken=keep;", "Remove preserves registry preference");
        prefs.Change(fixturePath, "Restore"); Assert(prefs.Actual(fixturePath) == "GpuPreference=2;OtherToken=keep;", "Restore returns first-touch original");
    }
    finally { using var key = Registry.CurrentUser.OpenSubKey(Preferences.RegistryPath, true); key?.DeleteValue(fixturePath, false); }
    int serial = 0;
    (Engine Engine, Store Store, FakePlatform Platform, FakeClock Clock) Setup(string policy = "Auto", bool observe = false)
    {
        var store = new Store(Path.Combine(directory, "engine-" + serial++)); store.Write("options.json", new Options { ResetPolicy = policy });
        var clock = new FakeClock(); var platform = new FakePlatform { DisplaysValue = internalDisplay, PowerValue = power, ClientsValue = [client] };
        var engine = new Engine(store, new Config { PackageFamilies = [], SettleSeconds = 5 }, platform, clock, observe); engine.Initialize(); return (engine, store, platform, clock);
    }
    var notify = Setup("Notify"); await notify.Engine.HandleAsync(new("Mode", "Auto")); notify.Clock.Advance(6); await notify.Engine.TickAsync();
    Assert(notify.Platform.Restarts == 0 && notify.Engine.Status.Pending is null && notify.Engine.Status.Approval is null, "Notify completes without reset");
    await notify.Engine.HandleAsync(new("Check")); notify.Clock.Advance(6); await notify.Engine.TickAsync();
    var old = notify.Engine.Status.Approval!; Assert(old is not null, "Manual request obtains approval under Notify");
    notify.Platform.ClientsValue = [client with { Id = 43 }]; await notify.Engine.HandleAsync(new("Approve", old!.Id)); await notify.Engine.TickAsync();
    var fresh = notify.Engine.Status.Approval!; Assert(fresh is not null && fresh.Id != old.Id && notify.Platform.Restarts == 0, "Changed clients require fresh approval");
    await notify.Engine.HandleAsync(new("Approve", fresh!.Id)); await notify.Engine.TickAsync();
    Assert(notify.Platform.Restarts == 1 && notify.Engine.Status.Pending is null, "Confirmed request executes fake restart once");
    notify.Clock.Advance(20); await notify.Engine.TickAsync(); Assert(notify.Platform.Restarts == 1, "Post-reset verification never resets again");
    var auto = Setup(); await auto.Engine.HandleAsync(new("Mode", "Auto")); auto.Clock.Advance(6); await auto.Engine.TickAsync();
    Assert(auto.Platform.Restarts == 1, "Auto policy reaches restart after repeated gates");
    var dry = Setup(observe: true); await dry.Engine.HandleAsync(new("Mode", "Auto")); dry.Clock.Advance(6); await dry.Engine.TickAsync();
    Assert(dry.Platform.Restarts == 0 && dry.Engine.Status.Status.Contains("DRY_RUN"), "ObserveOnly cannot execute restart");
    var secondGate = Setup(); secondGate.Platform.AfterFirstClients = () => secondGate.Platform.ProtectedValue = [client];
    await secondGate.Engine.HandleAsync(new("Mode", "Auto")); secondGate.Clock.Advance(6); await secondGate.Engine.TickAsync();
    Assert(secondGate.Platform.Restarts == 0 && secondGate.Engine.Status.Status.Contains("ProtectedApp"), "Late protected process caught by repeated gate");
    var failed = Setup(); failed.Platform.FailClients = true; await failed.Engine.HandleAsync(new("Mode", "Auto")); failed.Clock.Advance(6); await failed.Engine.TickAsync();
    Assert(failed.Platform.Restarts == 0 && failed.Engine.Status.Pending is null && failed.Engine.Status.Status.Contains("Ошибка"), "GPU counter failure cancels event instead of assuming no clients");
    var expired = Setup("Ask"); await expired.Engine.HandleAsync(new("Check")); expired.Clock.Advance(6); await expired.Engine.TickAsync();
    var id = expired.Engine.Status.Approval!.Id;
    for (var i = 0; i < 7; i++) { expired.Clock.Advance(15); await expired.Engine.TickAsync(); }
    await expired.Engine.HandleAsync(new("Approve", id)); await expired.Engine.TickAsync();
    Assert(expired.Platform.Restarts == 0 && expired.Engine.Status.Approval is null, "Expired command cannot resurrect a reset");
    var resumed = Setup("Ask"); await resumed.Engine.HandleAsync(new("Check")); resumed.Clock.Advance(6); await resumed.Engine.TickAsync();
    await resumed.Engine.TickAsync(2); Assert(resumed.Engine.Status.Pending is null && resumed.Engine.Status.Approval is null, "Resume cancels stale approval and pending request on AC");
    var paused = Setup(); await paused.Engine.HandleAsync(new("Mode", "Nvidia", 0)); paused.Clock.Advance(10); await paused.Engine.TickAsync();
    Assert(paused.Engine.Status.Mode == "Nvidia" && paused.Engine.Status.Until is null, "Indefinite pause remains active");
    await paused.Engine.HandleAsync(new("Mode", "Nvidia", 30));
    for (var i = 0; i < 121; i++) { paused.Clock.Advance(15); await paused.Engine.TickAsync(); }
    Assert(paused.Engine.Status.Mode == "Auto", "Timed pause returns to Auto");
    var measuring = Setup(); measuring.Platform.BatteryValue = new() { Present = true, Discharging = true, RemainingMWh = 40000, MaximumMWh = 45000, Watts = 15 };
    measuring.Engine.StartBattery(5, "fixture"); await measuring.Engine.HandleAsync(new("Mode", "Auto"));
    for (var i = 0; i < 20; i++) { measuring.Clock.Advance(15); await measuring.Engine.TickAsync(); }
    var session = measuring.Store.Read<BatterySession?>("battery-current.json", null)!;
    Assert(session.Complete && session.Valid && session.Samples.Count == 21 && session.Summary!.DurationSeconds == 300, "Five-minute battery lifecycle with deterministic clock");
    Assert(measuring.Platform.Restarts == 0 && Directory.GetFiles(Path.Combine(measuring.Store.Data, "measurements"), "*.csv").Length == 1, "Measurement suppresses resets and exports CSV");
    var unplug = Setup(); unplug.Platform.BatteryValue = measuring.Platform.BatteryValue; unplug.Engine.StartBattery(10, "interrupted"); unplug.Platform.BatteryValue = new() { Present = true, Online = true };
    unplug.Clock.Advance(15); await unplug.Engine.TickAsync();
    Assert(unplug.Store.Read<BatterySession?>("battery-current.json", null) is { Complete: true, Valid: false }, "Connecting charger invalidates battery run");
    var sleep = Setup(); sleep.Platform.BatteryValue = measuring.Platform.BatteryValue; sleep.Engine.StartBattery(5, "sleep"); await sleep.Engine.TickAsync(4);
    Assert(sleep.Store.Read<BatterySession?>("battery-current.json", null) is { Complete: true, Valid: false }, "Sleep invalidates measurement");
    var invalid = Setup(); File.WriteAllText(Path.Combine(invalid.Store.Data, "options.json"), "{\"ResetPolicy\":\"unsafe\"}"); await invalid.Engine.TickAsync();
    Assert(invalid.Platform.Restarts == 0, "Corrupt settings cannot authorize a reset");
    Console.WriteLine($"ALL {total} CHECKS PASSED. No real GPU restart performed.");
}
finally { Directory.Delete(directory, true); }

sealed class FakeClock : IClock
{
    public DateTimeOffset Now { get; private set; } = new(2026, 1, 1, 12, 0, 0, TimeSpan.Zero);
    public double Awake { get; private set; }
    public void Advance(double seconds) { Now = Now.AddSeconds(seconds); Awake += seconds; }
}
sealed class FakePlatform : IPlatform
{
    public string DeviceId => "fixture";
    public string PowerLine { get; set; } = "Online";
    public GpuNative.DisplayPath[] DisplaysValue { get; set; } = [];
    public GpuNative.DeviceState PowerValue { get; set; } = new();
    public Client[] ClientsValue { get; set; } = [];
    public Client[] ProtectedValue { get; set; } = [];
    public GpuNative.BatteryReading BatteryValue { get; set; } = new() { Present = true, Online = true };
    public int Restarts { get; private set; }
    public bool FailClients { get; set; }
    public Action? AfterFirstClients { get; set; }
    public GpuNative.DisplayPath[] Displays() => DisplaysValue;
    public GpuNative.DeviceState Power() => PowerValue;
    public Client[] Clients() { if (FailClients) throw new IOException("fixture query failure"); var value = ClientsValue; AfterFirstClients?.Invoke(); AfterFirstClients = null; return value; }
    public Client[] Protected(Options options) => ProtectedValue;
    public GpuNative.BatteryReading Battery() => BatteryValue;
    public double? Cpu() => 10;
    public int[] Brightness() => [50];
    public string ActiveApplications() => "fixture";
    public Task RestartAsync(CancellationToken token) { Restarts++; return Task.CompletedTask; }
}
