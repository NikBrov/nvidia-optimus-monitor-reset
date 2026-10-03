using System.Diagnostics;
using System.Globalization;
using System.Management;
using System.Text.RegularExpressions;

namespace GpuManager.Core;

public interface IClock { DateTimeOffset Now { get; } double Awake { get; } }
public sealed class WindowsClock : IClock { public DateTimeOffset Now => DateTimeOffset.Now; public double Awake => GpuNative.AwakeSeconds(); }
public interface IPlatform
{
    string DeviceId { get; }
    GpuNative.DisplayPath[] Displays();
    GpuNative.DeviceState Power();
    string PowerLine { get; }
    Client[] Clients();
    Client[] Protected(Options options);
    GpuNative.BatteryReading Battery();
    double? Cpu();
    int[] Brightness();
    string ActiveApplications();
    Task RestartAsync(CancellationToken token);
}
public sealed class WindowsPlatform : IPlatform
{
    private readonly Config config;
    private readonly Store store;
    private readonly IClock clock;
    public string DeviceId => config.DeviceId;
    public string PowerLine => SystemInformation.PowerStatus.PowerLineStatus.ToString();
    public WindowsPlatform(Config config, Store store, IClock clock)
    {
        this.config = config; this.store = store; this.clock = clock;
        var ids = GpuNative.NvidiaDevices();
        if (string.IsNullOrEmpty(config.DeviceId)) config.DeviceId = ids.Length == 1 ? ids[0] : throw new InvalidOperationException("Укажите DeviceId: NVIDIA не найдена или найдено несколько адаптеров.");
        if (!ids.Contains(config.DeviceId, Policy.Paths)) throw new InvalidOperationException("DeviceId должен соответствовать присутствующей NVIDIA.");
    }
    public GpuNative.DisplayPath[] Displays() => GpuNative.Displays(false);
    public GpuNative.DeviceState Power() => GpuNative.ReadPower(DeviceId);
    private static ManagementObjectCollection Query(string scope, string query, int timeout = 5)
    {
        var connection = new ManagementScope(scope, new ConnectionOptions { Timeout = TimeSpan.FromSeconds(timeout) });
        using var searcher = new ManagementObjectSearcher(connection, new ObjectQuery(query), new System.Management.EnumerationOptions { Timeout = TimeSpan.FromSeconds(timeout), ReturnImmediately = false });
        return searcher.Get();
    }
    private static Client? ProcessInfo(int id)
    {
        try
        {
            using var process = Process.GetProcessById(id);
            DateTimeOffset? started = null; try { started = process.StartTime; } catch (System.ComponentModel.Win32Exception) { }
            return new(id, process.ProcessName, GpuNative.ProcessPath(id), started);
        }
        catch (ArgumentException) { return null; }
        catch (InvalidOperationException) { return null; }
        catch (System.ComponentModel.Win32Exception) { return new(id, "PID " + id, ""); }
    }
    public Client[] Clients()
    {
        var luids = GpuNative.Displays(true).Where(d => d.Nvidia).Select(d => d.AdapterLuid).Distinct().ToArray();
        if (luids.Length != 1) throw new InvalidOperationException("Неоднозначное сопоставление NVIDIA с GPU-счётчиками.");
        var parts = luids[0].Split(':'); var luid = $"luid_0x{parts[0]}_0x{parts[1]}";
        using var rows = Query(@"root\cimv2", "SELECT Name,TotalCommitted FROM Win32_PerfRawData_GPUPerformanceCounters_GPUProcessMemory");
        var ids = new HashSet<int>();
        foreach (ManagementObject row in rows)
        {
            using (row)
            {
                var name = Convert.ToString(row["Name"]) ?? "";
                if (!name.Contains(luid, StringComparison.OrdinalIgnoreCase) || Convert.ToUInt64(row["TotalCommitted"], CultureInfo.InvariantCulture) == 0) continue;
                var match = Regex.Match(name, @"^pid_(\d+)_");
                if (match.Success && int.TryParse(match.Groups[1].Value, out var id) && id > 4) ids.Add(id);
            }
        }
        return ids.Select(ProcessInfo).OfType<Client>().ToArray();
    }
    public Client[] Protected(Options options)
    {
        var result = new List<Client>();
        foreach (var process in Process.GetProcesses())
        {
            using (process)
            {
                try
                {
                    var name = process.ProcessName;
                    var path = options.ProtectedPaths.Length > 0 ? GpuNative.ProcessPath(process.Id) : "";
                    if (config.ProtectedProcessNames.Contains(name, Policy.Paths) || options.ProtectedPaths.Contains(path, Policy.Paths)) result.Add(ProcessInfo(process.Id) ?? new(process.Id, name, path));
                }
                catch (InvalidOperationException) { }
                catch (System.ComponentModel.Win32Exception) { }
            }
        }
        return result.ToArray();
    }
    public GpuNative.BatteryReading Battery() => GpuNative.Battery();
    public double? Cpu() => GpuNative.CpuPercent();
    public int[] Brightness()
    {
        try { using var rows = Query(@"root\wmi", "SELECT CurrentBrightness FROM WmiMonitorBrightness", 3); return rows.Cast<ManagementObject>().Select(r => Convert.ToInt32(r["CurrentBrightness"])).ToArray(); }
        catch (ManagementException) { return []; }
        catch (System.Runtime.InteropServices.COMException) { return []; }
    }
    public string ActiveApplications()
    {
        var names = new List<string>();
        foreach (var process in Process.GetProcesses()) using (process) { try { if (process.MainWindowHandle != IntPtr.Zero) names.Add(process.ProcessName); } catch (InvalidOperationException) { } }
        return string.Join(", ", names.Distinct(Policy.Paths).Order(Policy.Paths));
    }
    private async Task<int> PnpAsync(string action, string name, CancellationToken token)
    {
        var info = new ProcessStartInfo(Path.Combine(Environment.SystemDirectory, "pnputil.exe")) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true };
        info.ArgumentList.Add(action); info.ArgumentList.Add(DeviceId);
        using var process = Process.Start(info) ?? throw new IOException("Не удалось запустить pnputil.");
        var output = process.StandardOutput.ReadToEndAsync(token); var error = process.StandardError.ReadToEndAsync(token);
        var start = clock.Awake;
        try
        {
            while (!process.HasExited)
            {
                token.ThrowIfCancellationRequested();
                if (clock.Awake - start > 45) throw new TimeoutException("Команда устройства превысила 45 секунд активной работы.");
                await Task.Delay(250, token);
            }
            await process.WaitForExitAsync(token);
            File.WriteAllText(Path.Combine(store.Data, name + "-output.txt"), await output);
            File.WriteAllText(Path.Combine(store.Data, name + "-error.txt"), await error);
            return process.ExitCode;
        }
        finally { if (!process.HasExited) { process.Kill(); await process.WaitForExitAsync(CancellationToken.None); } }
    }
    public async Task RestartAsync(CancellationToken token)
    {
        var started = clock.Now; var awake = clock.Awake; Exception? failure = null; int? exit = null;
        store.Log("RESET start v7; active-time timeout 45 seconds");
        try { exit = await PnpAsync("/restart-device", "restart", token); }
        catch (Exception e) { failure = e; }
        var state = Power();
        if (state.Present && state.Problem == 22)
        {
            store.Log("RECOVERY enabling NVIDIA");
            await PnpAsync("/enable-device", "recovery", CancellationToken.None); state = Power();
        }
        store.Log($"RESET end exit={exit}; awake_seconds={clock.Awake - awake:F2}; wall_seconds={(clock.Now - started).TotalSeconds:F2}; problem={state.Problem}");
        if (failure is not null) throw new IOException("Перезапуск не завершён. Повтор отменён.", failure);
        if (exit != 0 || !state.Present || state.Problem != 0) throw new IOException($"Ошибка устройства: exit={exit}, present={state.Present}, problem={state.Problem}");
        store.Write("last-reset.json", new { At = clock.Now, ExitCode = exit, AwakeSeconds = clock.Awake - awake, WallSeconds = (clock.Now - started).TotalSeconds });
    }
}
