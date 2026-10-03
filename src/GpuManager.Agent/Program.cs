using System.Security.Principal;
using GpuManager.Core;

namespace GpuManager.Agent;

internal static class Program
{
    [STAThread]
    private static int Main(string[] args)
    {
        var root = Arg(args, "--root") ?? AppContext.BaseDirectory;
        var store = new Store(root);
        var audit = args.Contains("--audit");
        var observe = args.Contains("--observe-only") || audit;
        var seconds = int.TryParse(Arg(args, "--exit-after"), out var n) ? n : 0;
        using var identity = WindowsIdentity.GetCurrent();
        if (!observe && !new WindowsPrincipal(identity).IsInRole(WindowsBuiltInRole.Administrator))
        { store.Log("Agent requires scheduled-task elevation; no device action executed."); return 1; }
        using var mutex = new Mutex(true, observe ? @"Local\GpuManagerV7Observe-" + Environment.ProcessId : @"Local\GpuManagerV7Agent", out var fresh);
        if (!fresh) return 0;
        try
        {
            ApplicationConfiguration.Initialize();
            var config = store.Read("config.json", new Config(), true);
            var clock = new WindowsClock();
            var platform = new WindowsPlatform(config, store, clock);
            var engine = new Engine(store, config, platform, clock, observe);
            if (audit) { engine.Initialize(); store.Write("audit.json", engine.Diagnose()); return 0; }
            using var watch = new GpuNative.WatchWindow();
            using var context = new ApplicationContext();
            using var token = new CancellationTokenSource();
            var sync = new WindowsFormsSynchronizationContext();
            var worker = Task.Run(async () =>
            {
                try
                {
                    engine.Initialize();
                    var started = DateTimeOffset.Now;
                    using var timer = new PeriodicTimer(TimeSpan.FromSeconds(3));
                    while (await timer.WaitForNextTickAsync(token.Token))
                    {
                        if (seconds > 0 && (DateTimeOffset.Now - started).TotalSeconds >= seconds) break;
                        await engine.TickAsync(watch.ConsumeEvents(), token.Token);
                    }
                }
                catch (OperationCanceledException) { }
                catch (Exception e) { store.Log("FATAL v7 " + e); Environment.ExitCode = 1; }
                finally { try { engine.StopBattery("Наблюдатель остановлен", false); } catch (Exception e) { store.Log("Shutdown: " + e.Message); } sync.Post(_ => context.ExitThread(), null); }
            });
            Application.Run(context);
            token.Cancel(); worker.GetAwaiter().GetResult(); sync.Dispose();
            return Environment.ExitCode;
        }
        catch (Exception e) { store.Log("FATAL v7 " + e); return 1; }
        finally { mutex.ReleaseMutex(); }
    }
    private static string? Arg(string[] args, string name) { var i = Array.IndexOf(args, name); return i >= 0 && i + 1 < args.Length ? args[i + 1] : null; }
}
