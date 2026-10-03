using System.Security.Principal;
using System.Security.Cryptography;
using System.Text;
using GpuManager.Core;

namespace GpuManager.App;

internal static class Program
{
    [STAThread]
    private static int Main(string[] args)
    {
        var root = Arg(args, "--root") ?? AppContext.BaseDirectory;
        var store = new Store(root);
        try
        {
            var action = Arg(args, "--command");
            if (action is not null)
            {
                if (action is not ("Check" or "Auto" or "Battery" or "Nvidia")) throw new ArgumentException("Неизвестная команда.");
                store.Send(action == "Check" ? new("Check") : new("Mode", action)); return 0;
            }
            ApplicationConfiguration.Initialize();
            using var identity = WindowsIdentity.GetCurrent();
            if (new WindowsPrincipal(identity).IsInRole(WindowsBuiltInRole.Administrator))
            { MessageBox.Show("Откройте панель обычным двойным щелчком, без запуска от администратора.", "GPU Manager"); return 1; }
            var key = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(Path.GetFullPath(root).ToUpperInvariant())))[..20];
            using var mutex = new Mutex(true, @"Local\GpuManagerV7Panel-" + key, out var fresh);
            if (!fresh) { Directory.CreateDirectory(store.Data); File.WriteAllText(Path.Combine(store.Data, "ui-activate.flag"), "open"); return 0; }
            try
            {
                using var form = new MainForm(store, Arg(args, "--preview"), int.TryParse(Arg(args, "--exit-after"), out var n) ? n : 0, args.Contains("--tray"));
                Application.Run(form); return 0;
            }
            finally { if (fresh) mutex.ReleaseMutex(); }
        }
        catch (Exception e)
        {
            try { store.Log("UI ERROR " + e); } catch { }
            MessageBox.Show(e.Message, "GPU Manager", MessageBoxButtons.OK, MessageBoxIcon.Error); return 1;
        }
    }
    private static string? Arg(string[] args, string name) { var i = Array.IndexOf(args, name); return i >= 0 && i + 1 < args.Length ? args[i + 1] : null; }
}
