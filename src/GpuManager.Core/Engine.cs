using System.Globalization;
using System.Text;

namespace GpuManager.Core;

// One serial worker owns all mutable monitoring state; WinForms only receives snapshots.
public sealed class Engine
{
    private readonly Store store;
    private readonly Config config;
    private readonly IPlatform platform;
    private readonly IClock clock;
    private readonly Preferences preferences;
    private readonly bool observeOnly;
    private AppAssignment[] apps = [];
    private readonly Snapshot status = new();
    private DateTimeOffset due, lastTopology, lastPreferences, lastTick, suppressed, nextHeartbeat, nextSample;
    private double lastAwake;
    private Approval? approved;
    private bool manual;
    private BatterySession? battery;
    private readonly Queue<DateTimeOffset> verification = new();
    public Snapshot Status => status;
    public Engine(Store store, Config config, IPlatform platform, IClock clock, bool observeOnly = false)
    {
        this.store = store; this.config = config; this.platform = platform; this.clock = clock; this.observeOnly = observeOnly;
        preferences = new(store, config); status.ObservingOnly = observeOnly; status.AgentStarted = clock.Now;
        config.SettleSeconds = Math.Clamp(config.SettleSeconds, 5, 120);
        config.CooldownSeconds = Math.Max(300, config.CooldownSeconds);
        config.PendingLifetimeMinutes = Math.Clamp(config.PendingLifetimeMinutes, 1, 60);
    }
    public void Initialize()
    {
        Directory.CreateDirectory(store.Data);
        apps = observeOnly ? preferences.Assignments() : preferences.Apply();
        status.Displays = platform.Displays(); status.PowerLine = platform.PowerLine;
        var saved = store.Read("mode.json", new ModeState());
        if (saved.Mode is "Auto" or "Battery" or "Nvidia") { status.Mode = saved.Mode; status.Until = saved.Until; }
        if (status.Mode == "Nvidia" && !saved.Forever && (saved.Until is null || saved.Until <= clock.Now || saved.Until > clock.Now.AddHours(24))) { status.Mode = "Auto"; status.Until = null; }
        lastTopology = lastPreferences = lastTick = clock.Now; lastAwake = clock.Awake;
        var stale = store.Read<BatterySession?>("battery-current.json", null);
        if (stale is { Complete: false }) { battery = stale; StopBattery("Наблюдатель перезапущен; замер прерван", false); }
        store.Log($"START v7 C#; mode={status.Mode}; observeOnly={observeOnly}; no NVIDIA polling");
        SetStatus("Наблюдение запущено. При запуске GPU не сбрасывается.");
    }
    private void Publish()
    {
        status.Heartbeat = clock.Now; status.ResetPolicy = store.Options().ResetPolicy;
        store.Write("status.json", status); nextHeartbeat = clock.Now.AddSeconds(15);
    }
    private void SetStatus(string message)
    {
        if (status.Status != message) { status.Time = clock.Now; status.Status = message; store.Log(message); }
        Publish();
    }
    private void CancelPending() { status.Pending = null; status.Approval = null; approved = null; }
    private void Queue(string reason)
    {
        if (status.Mode == "Nvidia" || status.Pending is not null || clock.Now < suppressed) return;
        status.Pending = clock.Now; status.Reason = reason; due = clock.Now.AddSeconds(config.SettleSeconds);
        manual = reason is "manual request" or "legacy manual request";
        status.Approval = approved = null; status.Clients = []; status.Blockers = [];
        SetStatus("Проверка после события: " + reason);
    }
    public async Task HandleAsync(Command command, CancellationToken token = default)
    {
        switch (command.Action)
        {
            case "Mode":
                if (command.Value is not ("Auto" or "Battery" or "Nvidia")) throw new InvalidDataException("Неизвестный режим.");
                if (command.Minutes is not (0 or 30 or 120)) throw new InvalidDataException("Неверная длительность паузы.");
                status.Mode = command.Value; status.Until = status.Mode == "Nvidia" && command.Minutes > 0 ? clock.Now.AddMinutes(command.Minutes) : null;
                CancelPending(); store.Write("mode.json", new ModeState(status.Mode, status.Until, status.Mode == "Nvidia" && command.Minutes == 0));
                SetStatus("Режим: " + ModeName(status.Mode)); if (status.Mode != "Nvidia") Queue("mode change"); break;
            case "Check": Queue("manual request"); break;
            case "Approve":
                if (status.Approval is { } approval && approval.Id == command.Value && clock.Now < approval.Expires)
                { approved = approval; status.Approval = null; due = clock.Now; }
                break;
            case "Dismiss":
                if (status.Approval?.Id == command.Value) { CancelPending(); SetStatus("Перезапуск отменён пользователем."); } break;
            case "RefreshPreferences":
                apps = observeOnly ? preferences.Assignments() : preferences.Apply(); lastPreferences = clock.Now;
                SetStatus("Назначения приложений обновлены."); break;
            case "Options": store.Options(); SetStatus("Настройки защиты обновлены."); break;
            case "Diagnose":
                store.Write("diagnosis.json", Diagnose()); SetStatus("Диагностика обновлена."); break;
            case "BatteryStart": StartBattery(command.Minutes, command.Label ?? ""); break;
            case "BatteryStop": StopBattery("Остановлено пользователем", false); break;
            default: throw new InvalidDataException("Неизвестная команда.");
        }
        await Task.CompletedTask;
    }
    public static string ModeName(string mode) => mode switch { "Auto" => "Авто", "Battery" => "Экономия энергии", "Nvidia" => "Автосброс приостановлен", _ => mode };
    public Diagnosis Diagnose()
    {
        var displays = platform.Displays(); var power = platform.Power(); var options = store.Options();
        var clients = Array.Empty<Client>(); var errors = Array.Empty<string>();
        if (power.Power != "D3") try { clients = platform.Clients(); } catch (Exception e) { errors = [e.Message]; }
        var protectedApps = platform.Protected(options);
        var decision = errors.Length > 0 ? "ClientQueryError" : Policy.Decide(status.Mode, displays, power, protectedApps, clients, preferences.SafePaths(apps), double.MaxValue, config.CooldownSeconds);
        var explanation = decision switch
        {
            "AlreadyAsleep" => "Windows сообщает D3: NVIDIA в энергосбережении.",
            "DisplayInUse" => "Внешний экран активен: перезапуск запрещён.",
            "ProtectedApp" => "Открыта защищённая программа: " + string.Join(", ", protectedApps.Select(p => p.Name).Distinct()),
            "UnknownClient" => "Обнаружены клиенты GPU, для которых сброс не разрешён.",
            "AllowReset" => "NVIDIA активна; сейчас можно запросить защищённый перезапуск.",
            "Paused" => "Автосброс приостановлен.",
            _ => "Проверка: " + decision
        };
        return new(clock.Now, power, decision, explanation, clients, protectedApps, displays, errors);
    }
    public async Task TickAsync(int events = 0, CancellationToken token = default)
    {
        try
        {
            var now = clock.Now;
            var elapsed = (now - lastTick).TotalSeconds; var awakeElapsed = clock.Awake - lastAwake;
            var resumed = (events & 6) != 0 || elapsed > 30;
            lastTick = now; lastAwake = clock.Awake;
            if (resumed)
            {
                store.Log($"RESUME/suspend gap_seconds={Math.Max(0, elapsed - awakeElapsed):F1}; old requests cancelled");
                CancelPending(); verification.Clear();
                if (battery is not null) StopBattery("Сон или длительный перерыв; результат не сравнивать", false);
            }
            if (status.Mode == "Nvidia" && status.Until <= now) await HandleAsync(new("Mode", "Auto"), token);
            foreach (var command in store.Commands())
                try { await HandleAsync(command, token); }
                catch (Exception e) when (e is not OperationCanceledException) { SetStatus("Команда отменена: " + e.Message); }
            var legacy = Path.Combine(store.Root, "RequestReset.flag");
            if (File.Exists(legacy)) { File.Delete(legacy); Queue("legacy manual request"); }
            var powerLine = platform.PowerLine;
            if (powerLine != status.PowerLine) { status.PowerLine = powerLine; if (powerLine == "Offline") Queue("battery power"); Publish(); }
            if ((events & 1) != 0 || resumed || now - lastTopology >= TimeSpan.FromSeconds(30))
            {
                var old = status.Displays; var fresh = platform.Displays(); status.Displays = fresh; lastTopology = now;
                if (!old.Select(p => p.Key).Order().SequenceEqual(fresh.Select(p => p.Key).Order()))
                {
                    if (fresh.Any(p => !p.Internal || p.Nvidia)) { CancelPending(); SetStatus("Подключён внешний экран: сброс запрещён."); }
                    else if (old.Any(p => !p.Internal)) Queue("external display disconnected");
                    else if (status.Pending is not null) due = now.AddSeconds(config.SettleSeconds);
                }
                if (resumed && (powerLine == "Offline" || status.Mode == "Battery")) Queue("resume");
            }
            if (now - lastPreferences >= TimeSpan.FromDays(1)) { apps = observeOnly ? preferences.Assignments() : preferences.Apply(); lastPreferences = now; }
            UpdateBattery();
            if (status.Approval is { } request && now >= request.Expires) { CancelPending(); SetStatus("Подтверждение истекло; повторите ручную проверку."); }
            if (verification.TryPeek(out var at) && now >= at)
            {
                verification.Dequeue(); var power = platform.Power(); status.GpuPower = power.Power;
                SetStatus(power.Power == "D3" ? "Windows сообщает D3: NVIDIA перешла в энергосбережение." : "Windows сообщает D0 после сброса. Повторного сброса не будет; нужна диагностика.");
            }
            if (status.Pending is not null && now >= due) await CheckAsync(token);
            if (now >= nextHeartbeat) Publish();
        }
        catch (Exception e) when (e is not OperationCanceledException)
        {
            CancelPending(); store.Log("ERROR " + e);
            try { SetStatus("Ошибка; действие отменено: " + e.Message); } catch (Exception nested) { store.Log("Status write failed: " + nested.Message); }
        }
    }
    private async Task CheckAsync(CancellationToken token)
    {
        var now = clock.Now;
        if (battery is not null) { due = now.AddSeconds(30); SetStatus("Замер батареи: сброс приостановлен."); return; }
        if (status.Approval is not null) return;
        if (now - status.Pending >= TimeSpan.FromMinutes(config.PendingLifetimeMinutes)) { CancelPending(); SetStatus("Проверка истекла; можно повторить вручную."); return; }
        var options = store.Options(); var displays = platform.Displays(); var power = platform.Power();
        var protectedApps = platform.Protected(options); var safe = preferences.SafePaths(apps);
        var last = store.Read<DateStamp?>("last-reset.json", null); var seconds = last is null ? double.MaxValue : (now - last.At).TotalSeconds;
        status.Displays = displays; status.GpuPower = power.Power; status.Blockers = protectedApps.Select(p => p.Name).Distinct().ToArray();
        var decision = Policy.Decide(status.Mode, displays, power, protectedApps, [], safe, seconds, config.CooldownSeconds);
        var clients = Array.Empty<Client>();
        if (decision == "AllowReset") { clients = platform.Clients(); decision = Policy.Decide(status.Mode, displays, power, protectedApps, clients, safe, seconds, config.CooldownSeconds); }
        status.Clients = clients; due = now.AddSeconds(30);
        switch (decision)
        {
            case "AllowReset":
                var confirmed = Policy.ApprovalMatches(approved, now, clients);
                var auth = Policy.Authorization(options.ResetPolicy, manual, confirmed);
                if (auth == "Notify") { CancelPending(); SetStatus("NVIDIA активна. Только уведомление: запросите проверку вручную."); return; }
                if (auth == "Ask")
                {
                    status.Approval = new(Guid.NewGuid().ToString("N"), now.AddSeconds(90), Policy.Signature(clients), clients);
                    SetStatus("Нужно подтверждение перезапуска в панели. Запрос действует 90 секунд."); return;
                }
                var againClients = platform.Clients();
                var again = Policy.Decide(status.Mode, platform.Displays(), platform.Power(), platform.Protected(store.Options()), againClients, safe, seconds, config.CooldownSeconds);
                if (again != "AllowReset") { approved = null; SetStatus("Отложено при повторной проверке: " + again); return; }
                if (confirmed && !Policy.ApprovalMatches(approved, clock.Now, againClients)) { approved = null; SetStatus("Клиенты изменились: нужно новое подтверждение."); return; }
                CancelPending(); suppressed = clock.Now.AddSeconds(90);
                if (observeOnly) { SetStatus("DRY_RUN: перезапуск допустим; устройство не изменено."); return; }
                SetStatus("Перезапуск NVIDIA выполняется…");
                await platform.RestartAsync(token);
                verification.Enqueue(clock.Now.AddSeconds(20)); verification.Enqueue(clock.Now.AddSeconds(60));
                SetStatus("NVIDIA перезапущена. Проверяю энергосостояние пассивно."); break;
            case "AlreadyAsleep": CancelPending(); SetStatus("Windows сообщает D3: сброс NVIDIA не нужен."); break;
            case "ProtectedApp": SetStatus("Ожидаю закрытия рабочих программ: " + string.Join(", ", status.Blockers)); break;
            case "UnknownClient": SetStatus("Сброс отложен: неизвестные клиенты GPU — " + string.Join(", ", clients.Where(c => !safe.Contains(c.Path)).Select(c => c.Name))); break;
            case "Cooldown": SetStatus("Пауза после сброса: не менее 5 минут."); break;
            default: CancelPending(); SetStatus("Сброс отменён: " + decision); break;
        }
    }
    public void StartBattery(int minutes, string label)
    {
        if (minutes is not (5 or 10)) throw new ArgumentException("Длительность: 5 или 10 минут.");
        if (battery is not null) throw new InvalidOperationException("Замер уже запущен.");
        var reading = platform.Battery();
        if (!reading.Present || reading.Online || !reading.Discharging) throw new InvalidOperationException("Отключите зарядку: батарея должна разряжаться.");
        status.Approval = approved = null;
        battery = new() { Id = clock.Now.ToString("yyyyMMdd-HHmmss") + "-" + Guid.NewGuid().ToString("N")[..6], Label = label[..Math.Min(120, label.Length)], Started = clock.Now, AwakeStart = clock.Awake, Minutes = minutes, Mode = status.Mode, Brightness = platform.Brightness() };
        nextSample = clock.Now; SetStatus("Замер батареи запущен. Сбросы приостановлены."); UpdateBattery();
    }
    private void UpdateBattery()
    {
        if (battery is null || clock.Now < nextSample) return;
        nextSample = clock.Now.AddSeconds(15); var reading = platform.Battery();
        if (!reading.Present || reading.Online || !reading.Discharging) { StopBattery("Зарядка подключена или батарея перестала разряжаться", false); return; }
        var power = platform.Power();
        var percent = reading.MaximumMWh > 0 ? 100.0 * reading.RemainingMWh / reading.MaximumMWh : double.NaN;
        battery.Samples.Add(new(clock.Now, clock.Awake, reading.Watts, reading.RemainingMWh, double.IsFinite(percent) ? percent : 0, platform.Cpu(), power.Power, platform.ActiveApplications()));
        SaveBattery();
        if (clock.Awake - battery.AwakeStart >= battery.Minutes * 60) StopBattery("Замер завершён по времени", true);
    }
    private void SaveBattery() { if (battery is null) return; battery.Summary = Policy.Summarize(battery.Samples); store.Write("battery-current.json", battery); }
    public void StopBattery(string reason, bool valid = false)
    {
        if (battery is null) return;
        battery.Complete = true; battery.Valid = valid; battery.EndReason = reason; battery.Ended = clock.Now; SaveBattery();
        store.Write(Path.Combine("measurements", battery.Id + ".json"), battery);
        var csv = new StringBuilder("Time,AwakeSeconds,Watts,RemainingMWh,Percent,CpuPercent,GpuPower,ActiveApplications\r\n");
        static string Field(object? value) => "\"" + Convert.ToString(value, CultureInfo.InvariantCulture)?.Replace("\"", "\"\"") + "\"";
        foreach (var s in battery.Samples) csv.AppendLine(string.Join(",", new object?[] { s.Time.ToString("O"), s.AwakeSeconds, s.Watts, s.RemainingMWh, s.Percent, s.CpuPercent, s.GpuPower, s.ActiveApplications }.Select(Field)));
        File.WriteAllText(Path.Combine(store.Data, "measurements", battery.Id + ".csv"), csv.ToString(), new UTF8Encoding(true));
        battery = null; SetStatus("Замер батареи: " + reason);
    }
    public sealed record DateStamp(DateTimeOffset At);
}
