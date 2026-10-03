using Microsoft.Win32;
using System.Text.RegularExpressions;

namespace GpuManager.Core;

public sealed class Preferences(Store store, Config config)
{
    public const string RegistryPath = @"Software\Microsoft\DirectX\UserGpuPreferences";
    public AppAssignment[] Assignments(bool discoverPackages = true)
    {
        var defaults = new List<AppAssignment>();
        void Add(IEnumerable<string> paths, int gpu)
        {
            foreach (var entry in paths)
            {
                var path = Environment.ExpandEnvironmentVariables(entry);
                if (Policy.IsExe(path) && File.Exists(path)) defaults.Add(new(path, gpu));
            }
        }
        Add(config.EverydayExecutables, 1); Add(config.PerformanceExecutables.Concat(config.ManualPerformanceExecutables), 2);
        // Keep v6 assignments while discovering current packaged versions using the Windows package API.
        defaults.AddRange(store.List<AppAssignment>("assignments.json").Where(a => Policy.IsExe(a.Path) && File.Exists(a.Path)));
        if (discoverPackages)
            foreach (var family in config.PackageFamilies)
            {
                var pattern = family[..family.LastIndexOf('_')];
                if (config.PackagePatterns.Length > 0 && !config.PackagePatterns.Any(p => pattern.Equals(p, StringComparison.OrdinalIgnoreCase))) continue;
                foreach (var directory in GpuNative.PackageDirectories(family))
                {
                    var options = new EnumerationOptions { RecurseSubdirectories = true, IgnoreInaccessible = true, AttributesToSkip = FileAttributes.ReparsePoint };
                    foreach (var file in Directory.EnumerateFiles(directory, "*.exe", options))
                        if (config.PackageExecutableNames.Contains(Path.GetFileName(file), Policy.Paths)) defaults.Add(new(file, 1));
                }
            }
        Add(store.List<string>("manual-apps.json"), 2);
        return Policy.Merge(defaults, store.List<AppOverride>("app-overrides.json"));
    }
    public HashSet<string> SafePaths(IEnumerable<AppAssignment> apps)
    {
        var paths = apps.Where(a => a.Gpu == 1 && config.ResetTolerantExecutableNames.Contains(Path.GetFileName(a.Path), Policy.Paths)).Select(a => a.Path).ToHashSet(Policy.Paths);
        var windows = Environment.GetFolderPath(Environment.SpecialFolder.Windows);
        foreach (var exe in new[] { @"System32\dwm.exe", @"System32\csrss.exe", "explorer.exe" }) paths.Add(Path.Combine(windows, exe));
        return paths;
    }
    public static string Value(string? old, int gpu)
    {
        if (gpu is < 0 or > 2) throw new ArgumentOutOfRangeException(nameof(gpu));
        var other = Regex.Replace(old ?? "", @"GpuPreference=\d+;?", "", RegexOptions.IgnoreCase).Trim(';');
        return $"GpuPreference={gpu};" + (other.Length > 0 ? other + ";" : "");
    }
    public string? Actual(string path) { using var key = Registry.CurrentUser.OpenSubKey(RegistryPath); return key?.GetValue(path) as string; }
    private void SetUnlocked(string path, int gpu)
    {
        using var key = Registry.CurrentUser.CreateSubKey(RegistryPath);
        var old = key.GetValue(path) as string;
        var backups = store.List<PreferenceBackup>("preferences-before.json");
        if (!backups.Any(b => Policy.Paths.Equals(b.Path, path)))
        {
            backups.Add(new(path, key.GetValueNames().Contains(path, Policy.Paths), old));
            store.Write("preferences-before.json", backups);
        }
        var value = Value(old, gpu);
        if (old != value) key.SetValue(path, value, RegistryValueKind.String);
    }
    public AppAssignment[] Apply()
    {
        AppAssignment[] apps = [];
        store.Locked(() => { apps = Assignments(); foreach (var app in apps) SetUnlocked(app.Path, app.Gpu); store.Write("assignments.json", apps); });
        return apps;
    }
    public void Change(string path, string choice)
    {
        if (!Policy.IsExe(path)) throw new ArgumentException("Выберите полный путь к EXE.");
        store.Locked(() =>
        {
            var list = store.List<AppOverride>("app-overrides.json").Where(a => !Policy.Paths.Equals(a.Path, path)).ToList();
            if (choice == "Restore")
            {
                var backup = store.List<PreferenceBackup>("preferences-before.json").FirstOrDefault(a => Policy.Paths.Equals(a.Path, path)) ?? throw new InvalidOperationException("Исходное назначение не сохранено.");
                using var key = Registry.CurrentUser.CreateSubKey(RegistryPath);
                if (backup.Existed) key.SetValue(path, backup.Value ?? "", RegistryValueKind.String); else key.DeleteValue(path, false);
                list.Add(new(path, 0, true));
            }
            else if (choice == "Remove") list.Add(new(path, 0, true));
            else if (int.TryParse(choice, out var gpu) && gpu is >= 0 and <= 2) { SetUnlocked(path, gpu); list.Add(new(path, gpu)); }
            else throw new ArgumentException("Неизвестный выбор GPU.");
            store.Write("app-overrides.json", list);
        });
        store.Log($"APP choice={choice} path={path}");
    }
}
