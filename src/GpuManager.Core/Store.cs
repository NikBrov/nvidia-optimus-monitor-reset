using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace GpuManager.Core;

public sealed class Store
{
    public string Root { get; }
    public string Data => Path.Combine(Root, "data");
    public static readonly JsonSerializerOptions Json = new() { PropertyNameCaseInsensitive = true, IncludeFields = true, WriteIndented = true };
    private readonly string mutexName;
    public Store(string root)
    {
        Root = Path.TrimEndingDirectorySeparator(Path.GetFullPath(root));
        mutexName = @"Local\GpuManagerData-" + Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(Root.ToUpperInvariant())))[..20];
    }
    public T Read<T>(string name, T fallback, bool root = false)
    {
        var path = Path.Combine(root ? Root : Data, name);
        if (!File.Exists(path)) return fallback;
        if (new FileInfo(path).Length > 16 * 1024 * 1024) throw new InvalidDataException("Файл данных слишком большой: " + name);
        return JsonSerializer.Deserialize<T>(File.ReadAllText(path), Json) ?? fallback;
    }
    public List<T> List<T>(string name)
    {
        var path = Path.Combine(Data, name);
        if (!File.Exists(path)) return [];
        if (new FileInfo(path).Length > 16 * 1024 * 1024) throw new InvalidDataException("Файл данных слишком большой.");
        var text = File.ReadAllText(path);
        if (string.IsNullOrWhiteSpace(text)) return [];
        using var doc = JsonDocument.Parse(text);
        return doc.RootElement.ValueKind switch
        {
            JsonValueKind.Array => JsonSerializer.Deserialize<List<T>>(text, Json) ?? [],
            JsonValueKind.Null => [],
            _ => [JsonSerializer.Deserialize<T>(text, Json)!]
        };
    }
    public void Locked(Action action)
    {
        using var mutex = new Mutex(false, mutexName);
        var held = false;
        try { try { held = mutex.WaitOne(TimeSpan.FromSeconds(5)); } catch (AbandonedMutexException) { held = true; } if (!held) throw new IOException("Данные заняты другим процессом."); action(); }
        finally { if (held) mutex.ReleaseMutex(); }
    }
    public void Write<T>(string name, T value) => Atomic(Path.Combine(Data, name), value);
    public static void Atomic<T>(string path, T value)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        var temp = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try { File.WriteAllText(temp, JsonSerializer.Serialize(value, Json), new UTF8Encoding(false)); File.Move(temp, path, true); }
        finally { if (File.Exists(temp)) File.Delete(temp); }
    }
    public void Log(string message)
    {
        try
        {
            Locked(() =>
            {
                Directory.CreateDirectory(Data);
                foreach (var file in new[] { "GpuManager.log", "history.jsonl" })
                {
                    var path = Path.Combine(Data, file);
                    if (File.Exists(path) && new FileInfo(path).Length > 2 * 1024 * 1024) File.Move(path, path + ".previous", true);
                    var line = file.EndsWith("jsonl") ? JsonSerializer.Serialize(new { Time = DateTimeOffset.Now, Message = message }) : $"{DateTimeOffset.Now:yyyy-MM-dd HH:mm:ss} {message}";
                    File.AppendAllText(path, line + Environment.NewLine, Encoding.UTF8);
                }
            });
        }
        catch (IOException) { /* Logging failure must not authorize a restart. */ }
    }
    public void Send(Command command) => Write(Path.Combine("commands", $"{DateTime.UtcNow:yyyyMMddHHmmssfffffff}-{Guid.NewGuid():N}.json"), command);
    public IEnumerable<Command> Commands()
    {
        var paths = new List<string>();
        if (File.Exists(Path.Combine(Data, "command.json"))) paths.Add(Path.Combine(Data, "command.json"));
        var queue = Path.Combine(Data, "commands");
        if (Directory.Exists(queue)) paths.AddRange(Directory.GetFiles(queue, "*.json").Order(StringComparer.Ordinal).Take(20));
        foreach (var path in paths)
        {
            Command? command = null;
            try
            {
                if (new FileInfo(path).Length > 65536) throw new InvalidDataException("Command too large");
                command = JsonSerializer.Deserialize<Command>(File.ReadAllText(path), Json);
            }
            catch (Exception e) when (e is IOException or JsonException) { Log("Invalid command ignored: " + e.GetType().Name); }
            finally { try { File.Delete(path); } catch (IOException) { } }
            if (command is not null) yield return command;
        }
    }
    public Options Options() { var options = Read("options.json", new Options()); options.Validate(); return options; }
    public string History(int last = 200)
    {
        var path = Path.Combine(Data, "GpuManager.log");
        return File.Exists(path) ? string.Join(Environment.NewLine, File.ReadLines(path).TakeLast(last)) : "";
    }
}
