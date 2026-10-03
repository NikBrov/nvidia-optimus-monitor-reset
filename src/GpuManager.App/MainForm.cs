using System.Diagnostics;
using System.Globalization;
using System.Text.Json;
using GpuManager.Core;

namespace GpuManager.App;

public sealed class MainForm : Form
{
    private readonly Store store;
    private readonly Config config;
    private readonly Preferences preferences;
    private readonly TabControl tabs = new() { Dock = DockStyle.Fill };
    private readonly TextBox status = TextArea(), diagnosis = TextArea(), history = TextArea(), batteryStatus = TextArea();
    private readonly DataGridView apps = Grid("Программа", "GPU", "В Windows", "Путь");
    private readonly DataGridView protections = Grid("Программа / путь", "Тип защиты");
    private readonly DataGridView measurements = Grid("Дата / название", "Минуты", "Расход, Вт", "CPU, %", "D3 / отсчёты", "Пригодность");
    private readonly ComboBox pause = Combo("30 минут", "2 часа", "До ручного отключения");
    private readonly ComboBox gpu = Combo("Выбор Windows", "Intel", "NVIDIA");
    private readonly ComboBox resetPolicy = Combo("Автоматически после проверок", "Спрашивать перед сбросом", "Только уведомлять");
    private readonly ComboBox duration = Combo("5 минут", "10 минут");
    private readonly TextBox label = new() { Text = "Обычная работа", Width = 390 };
    private readonly System.Windows.Forms.Timer timer = new() { Interval = 3000 };
    private readonly NotifyIcon tray;
    private readonly HashSet<string> seen = [];
    private readonly string? preview;
    private readonly int exitAfter;
    private readonly DateTimeOffset started = DateTimeOffset.Now;
    private bool refreshing, prompting, exiting;
    private string lastMessage = "";
    private Diagnosis? latestDiagnosis;
    public MainForm(Store store, string? preview = null, int exitAfter = 0, bool startInTray = false)
    {
        this.store = store; this.preview = preview; this.exitAfter = exitAfter;
        config = store.Read("config.json", new Config(), true); preferences = new(store, config);
        Text = "GPU Manager v7 — Intel / NVIDIA"; Font = new Font("Segoe UI", 10);
        ClientSize = new Size(1030, 700); MinimumSize = new Size(860, 620); StartPosition = FormStartPosition.CenterScreen;
        Controls.Add(tabs); BuildMain(); BuildApps(); BuildProtection(); BuildHistory(); BuildBattery();
        var menu = new ContextMenuStrip();
        menu.Items.Add("Открыть панель", null, (_, _) => { Show(); WindowState = FormWindowState.Normal; Activate(); });
        menu.Items.Add("Авто", null, (_, _) => Send(new("Mode", "Auto")));
        menu.Items.Add("Экономия энергии", null, (_, _) => Send(new("Mode", "Battery")));
        menu.Items.Add("Пауза на 2 часа", null, (_, _) => Send(new("Mode", "Nvidia", 120)));
        menu.Items.Add("Проверить и запросить перезапуск", null, (_, _) => Send(new("Check")));
        menu.Items.Add("Выйти из панели и трея", null, (_, _) => { exiting = true; Close(); });
        tray = new NotifyIcon { Icon = SystemIcons.Application, Text = "GPU Manager v7", Visible = preview is null, ContextMenuStrip = menu };
        tray.DoubleClick += (_, _) => { Show(); WindowState = FormWindowState.Normal; Activate(); };
        Resize += (_, _) => { if (WindowState == FormWindowState.Minimized && preview is null) Hide(); };
        timer.Tick += async (_, _) =>
        {
            var activate = Path.Combine(store.Data, "ui-activate.flag");
            if (File.Exists(activate)) { File.Delete(activate); Show(); WindowState = FormWindowState.Normal; Activate(); }
            if (exitAfter > 0 && (DateTimeOffset.Now - started).TotalSeconds >= exitAfter) { Close(); return; }
            await RefreshStatusAsync();
        };
        Shown += async (_, _) =>
        {
            await RunAsync(RefreshAppsAsync); await RunAsync(RefreshProtectionAsync); await RunAsync(RefreshHistoryAsync); await RunAsync(RefreshMeasurementsAsync); await RefreshStatusAsync();
            if (preview is not null)
            {
                for (var i = 0; i < tabs.TabCount; i++)
                {
                    tabs.SelectedIndex = i; Refresh();
                    using var bitmap = new Bitmap(Width, Height); DrawToBitmap(bitmap, new Rectangle(0, 0, Width, Height));
                    bitmap.Save(preview.Replace(".png", $"-{i}.png"));
                }
                tabs.SelectedIndex = 0;
            }
            timer.Start();
            if (startInTray && preview is null) { WindowState = FormWindowState.Minimized; Hide(); }
        };
        FormClosing += (_, e) => { if (!exiting && exitAfter == 0 && preview is null && e.CloseReason == CloseReason.UserClosing) { e.Cancel = true; Hide(); } };
        FormClosed += (_, _) => { timer.Stop(); timer.Dispose(); tray.Visible = false; tray.Dispose(); };
    }
    private static TextBox TextArea() => new() { Multiline = true, ReadOnly = true, ScrollBars = ScrollBars.Vertical, Dock = DockStyle.Fill, BorderStyle = BorderStyle.FixedSingle };
    private static ComboBox Combo(params string[] items) { var c = new ComboBox { DropDownStyle = ComboBoxStyle.DropDownList, Width = 225 }; c.Items.AddRange(items); c.SelectedIndex = 0; return c; }
    private static DataGridView Grid(params string[] columns)
    {
        var grid = new DataGridView { Dock = DockStyle.Fill, ReadOnly = true, AllowUserToAddRows = false, AllowUserToDeleteRows = false, RowHeadersVisible = false, MultiSelect = false, SelectionMode = DataGridViewSelectionMode.FullRowSelect, AutoSizeColumnsMode = DataGridViewAutoSizeColumnsMode.Fill, BackgroundColor = SystemColors.Window };
        foreach (var name in columns) grid.Columns.Add(name, name); return grid;
    }
    private TableLayoutPanel Page(string name, params int[] heights)
    {
        var page = new TabPage(name) { Padding = new Padding(16) }; tabs.TabPages.Add(page);
        var layout = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 1, RowCount = heights.Length };
        layout.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        foreach (var h in heights) layout.RowStyles.Add(h < 0 ? new RowStyle(SizeType.Percent, -h) : new RowStyle(SizeType.Absolute, h));
        page.Controls.Add(layout); return layout;
    }
    private static Label Note(string text) => new() { Text = text, Dock = DockStyle.Fill, AutoEllipsis = true, Padding = new Padding(0, 5, 0, 0) };
    private Button Button(string text, Func<Task> action, int width = 270)
    {
        var button = new Button { Text = text, Width = width, Height = 38, AutoSize = false, Margin = new Padding(0, 4, 12, 4) };
        button.Click += async (_, _) => { button.Enabled = false; try { await RunAsync(action); } finally { if (!button.IsDisposed) button.Enabled = true; } }; return button;
    }
    private static FlowLayoutPanel Row(params Control[] controls) { var row = new FlowLayoutPanel { Dock = DockStyle.Fill, WrapContents = true, AutoScroll = true }; row.Controls.AddRange(controls); return row; }
    private Task SendAsync(Command command) { Send(command); return Task.CompletedTask; }
    private void Send(Command command) { try { store.Send(command); } catch (Exception e) { MessageBox.Show(this, e.Message, "GPU Manager"); } }
    private async Task RunAsync(Func<Task> work)
    {
        try { await work(); } catch (Exception e) { if (preview is not null) { store.Log("UI PREVIEW ERROR " + e); throw; } MessageBox.Show(this, e.Message, "GPU Manager", MessageBoxButtons.OK, MessageBoxIcon.Error); }
    }
    private void BuildMain()
    {
        var p = Page("Режим и состояние", 38, 135, 54, 57, 56, 50, -100, 36);
        p.Controls.Add(Note("Intel — для обычной работы, NVIDIA — для 3D и видео. Закрытие панели не останавливает наблюдатель."), 0, 0);
        p.Controls.Add(status, 0, 1);
        p.Controls.Add(Row(Button("Авто", () => SendAsync(new("Mode", "Auto")), 125), Button("Экономия энергии", () => SendAsync(new("Mode", "Battery")), 190), pause,
            Button("Приостановить автосброс", () => SendAsync(new("Mode", "Nvidia", new[] { 30, 120, 0 }[pause.SelectedIndex])), 300)), 0, 2);
        p.Controls.Add(Note("Авто: проверка после отключения экрана, перехода на батарею и пробуждения на батарее. Экономия: также после пробуждения от сети. Пауза не меняет назначение GPU."), 0, 3);
        p.Controls.Add(Row(Button("Проверить и запросить перезапуск…", () => SendAsync(new("Check")), 420), Button("Выбрать приложение для NVIDIA и запустить…", LaunchAsync, 480)), 0, 4);
        p.Controls.Add(Row(Button("Обновить диагностику", () => SendAsync(new("Diagnose"))), Button("Настройки графики Windows", () => ShellAsync("ms-settings:display-advancedgraphics")), Button("Открыть инструкцию", () => ShellAsync(Path.Combine(store.Root, "README.txt")))), 0, 5);
        diagnosis.Text = "Нажмите «Обновить диагностику». Проверка выполнится в фоновом компоненте, окно останется отзывчивым."; p.Controls.Add(diagnosis, 0, 6);
        p.Controls.Add(Note("D0 — активное состояние; D3 — энергосбережение. Это последнее чтение Windows, не расход в ваттах."), 0, 7);
    }
    private void BuildApps()
    {
        var p = Page("Приложения", 55, -100, 52, 53, 60);
        p.Controls.Add(Note("После изменения GPU перезапустите приложение. Ваши назначения имеют приоритет над исходным списком менеджера."), 0, 0);
        apps.Columns[3].FillWeight = 230; p.Controls.Add(apps, 0, 1);
        p.Controls.Add(Row(gpu, Button("Применить к выбранной", () => ChangeAsync(SelectedApp(), gpu.SelectedIndex.ToString()), 240), Button("Добавить EXE…", AddAppAsync, 210), Button("Обновить", RefreshAppsAsync, 160)), 0, 2);
        p.Controls.Add(Row(Button("Удалить из управления", () => ChangeAsync(SelectedApp(), "Remove"), 310), Button("Вернуть исходное назначение", () => ChangeAsync(SelectedApp(), "Restore"), 370)), 0, 3);
        p.Controls.Add(Note("Удаление оставляет текущую настройку Windows. Возврат восстанавливает значение до первого изменения менеджером и прекращает управление программой."), 0, 4);
    }
    private void BuildProtection()
    {
        var p = Page("Защита и сброс", 38, 54, 72, -100, 56, 62);
        p.Controls.Add(Note("Поведение при безопасной возможности автоматического сброса:"), 0, 0); resetPolicy.Width = 590;
        p.Controls.Add(Row(resetPolicy, Button("Сохранить", SaveOptionsAsync, 250)), 0, 1);
        p.Controls.Add(Note("Ручной запрос всегда требует подтверждения. В режиме «Спрашивать» запрос действует 90 секунд; панель должна быть открыта или свернута в трей. Подтверждение не отменяет защитные проверки."), 0, 2);
        p.Controls.Add(protections, 0, 3);
        p.Controls.Add(Row(Button("Защитить приложение…", ProtectAsync, 420), Button("Удалить выбранную свою защиту", RemoveProtectionAsync, 460)), 0, 4);
        p.Controls.Add(Note("Открытая защищённая программа, внешний экран, неизвестные клиенты GPU и ошибки блокируют сброс. При перезапуске экран может мигнуть, графические ресурсы программ могут прерваться."), 0, 5);
    }
    private void BuildHistory()
    {
        var p = Page("История и отчёт", 44, -100, 55);
        p.Controls.Add(Note("Последние 200 записей. Активная длительность перезапуска и календарное время учитываются отдельно."), 0, 0); p.Controls.Add(history, 0, 1);
        p.Controls.Add(Row(Button("Обновить историю", RefreshHistoryAsync), Button("Сохранить отчёт диагностики…", ExportAsync, 480)), 0, 2);
    }
    private void BuildBattery()
    {
        var p = Page("Замер батареи", 72, 48, 54, 105, -100, 62);
        p.Controls.Add(Note("Отключите зарядку. Для сравнения оставьте одинаковые яркость, приложения и нагрузку. Во время замера сбросы приостановлены; сон или подключение зарядки прерывают замер."), 0, 0);
        p.Controls.Add(Row(duration, new Label { Text = "Название / условия:", Width = 165, Height = 32 }, label), 0, 1);
        p.Controls.Add(Row(Button("Начать замер", () => SendAsync(new("BatteryStart", Minutes: new[] { 5, 10 }[duration.SelectedIndex], Label: label.Text))), Button("Остановить", () => SendAsync(new("BatteryStop"))), Button("Обновить результаты", RefreshMeasurementsAsync)), 0, 2);
        p.Controls.Add(batteryStatus, 0, 3); p.Controls.Add(measurements, 0, 4);
        p.Controls.Add(Note("Расход — всего ноутбука, не одной NVIDIA. Отсчёты раз в 15 секунд. Сравнивайте завершённые замеры с похожей CPU-нагрузкой; короткий замер не доказывает причину экономии."), 0, 5);
    }
    private string SelectedApp() => apps.SelectedRows.Count > 0 ? (string)apps.SelectedRows[0].Tag! : throw new InvalidOperationException("Выберите программу в списке.");
    private string? ChooseExe() { using var dialog = new OpenFileDialog { Filter = "Программы (*.exe)|*.exe" }; return dialog.ShowDialog(this) == DialogResult.OK ? dialog.FileName : null; }
    private async Task ChangeAsync(string path, string choice) { await Task.Run(() => preferences.Change(path, choice)); Send(new("RefreshPreferences")); await RefreshAppsAsync(); }
    private async Task AddAppAsync() { var path = ChooseExe(); if (path is not null) await ChangeAsync(path, gpu.SelectedIndex.ToString()); }
    private async Task LaunchAsync()
    {
        var path = ChooseExe(); if (path is null) return;
        await ChangeAsync(path, "2"); Send(new("Mode", "Nvidia", 120));
        Process.Start(new ProcessStartInfo(path) { UseShellExecute = true, WorkingDirectory = Path.GetDirectoryName(path)! });
    }
    private static Task ShellAsync(string target) { Process.Start(new ProcessStartInfo(target) { UseShellExecute = true }); return Task.CompletedTask; }
    private async Task RefreshAppsAsync()
    {
        var rows = await Task.Run(() => preferences.Assignments().Select(a => (App: a, Value: preferences.Actual(a.Path))).ToArray());
        apps.Rows.Clear();
        foreach (var row in rows)
        {
            var a = row.App; var i = apps.Rows.Add(Path.GetFileName(a.Path), new[] { "Выбор Windows", "Intel", "NVIDIA" }[a.Gpu], row.Value?.Contains($"GpuPreference={a.Gpu};", StringComparison.OrdinalIgnoreCase) == true ? "Сохранено" : "Ожидает / отличается", a.Path); apps.Rows[i].Tag = a.Path;
        }
    }
    private async Task RefreshProtectionAsync()
    {
        var options = await Task.Run(store.Options); resetPolicy.SelectedIndex = Array.IndexOf(new[] { "Auto", "Ask", "Notify" }, options.ResetPolicy);
        protections.Rows.Clear(); foreach (var name in config.ProtectedProcessNames) protections.Rows.Add(name, "Встроенная защита");
        foreach (var path in options.ProtectedPaths) { var i = protections.Rows.Add(path, "Ваша защита"); protections.Rows[i].Tag = path; }
    }
    private async Task SaveOptionsAsync() { var policy = new[] { "Auto", "Ask", "Notify" }[resetPolicy.SelectedIndex]; await Task.Run(() => store.Locked(() => { var o = store.Options(); o.ResetPolicy = policy; store.Write("options.json", o); })); Send(new("Options")); }
    private async Task ProtectAsync()
    {
        var path = ChooseExe(); if (path is null) return;
        await Task.Run(() => store.Locked(() => { var o = store.Options(); o.ProtectedPaths = o.ProtectedPaths.Append(path).Distinct(Policy.Paths).ToArray(); store.Write("options.json", o); })); Send(new("Options")); await RefreshProtectionAsync();
    }
    private async Task RemoveProtectionAsync()
    {
        var path = protections.SelectedRows.Count > 0 ? protections.SelectedRows[0].Tag as string : null;
        if (path is null) throw new InvalidOperationException("Выберите свою запись. Встроенная защита не удаляется.");
        await Task.Run(() => store.Locked(() => { var o = store.Options(); o.ProtectedPaths = o.ProtectedPaths.Where(p => !Policy.Paths.Equals(p, path)).ToArray(); store.Write("options.json", o); })); Send(new("Options")); await RefreshProtectionAsync();
    }
    private async Task RefreshHistoryAsync() { history.Text = await Task.Run(() => store.History()); history.SelectionStart = history.TextLength; history.ScrollToCaret(); }
    private BatterySession[] Sessions(int count)
    {
        var folder = Path.Combine(store.Data, "measurements"); if (!Directory.Exists(folder)) return [];
        return Directory.GetFiles(folder, "*.json").OrderByDescending(File.GetLastWriteTimeUtc).Take(count).Select(f => store.Read<BatterySession?>(Path.Combine("measurements", Path.GetFileName(f)), null)).OfType<BatterySession>().ToArray();
    }
    private async Task RefreshMeasurementsAsync()
    {
        var rows = await Task.Run(() => Sessions(40)); measurements.Rows.Clear();
        foreach (var m in rows) if (m.Summary is { } s) measurements.Rows.Add($"{m.Started:g} / {m.Label}", Math.Round(s.DurationSeconds / 60, 1), (object?)s.MeanDischargeWatts ?? "нет данных", (object?)s.MeanCpuPercent ?? "нет данных", $"{s.D3Samples} / {s.Samples}", m.Valid ? "Завершён" : "Прерван: " + m.EndReason);
    }
    private async Task ExportAsync()
    {
        using var dialog = new SaveFileDialog { Filter = "Отчёт JSON (*.json)|*.json", FileName = $"GPU-report-{DateTime.Now:yyyyMMdd-HHmmss}.json" }; if (dialog.ShowDialog(this) != DialogResult.OK) return;
        Send(new("Diagnose"));
        var path = dialog.FileName;
        await Task.Run(() => Store.Atomic(path, new { Version = 7, Time = DateTimeOffset.Now, Status = store.Read<Snapshot?>("status.json", null), Diagnosis = store.Read<Diagnosis?>("diagnosis.json", null), Options = store.Options(), Assignments = preferences.Assignments(), History = store.History(), Measurements = Sessions(20) }));
        MessageBox.Show(this, "Отчёт сохранён. Диагностика имеет указанное в ней время; при необходимости обновите её перед экспортом. Отчёт содержит пути программ и историю.", "GPU Manager");
    }
    private static bool Alive(Snapshot s)
    {
        if (s.Version != 7 || DateTimeOffset.Now - s.Heartbeat > TimeSpan.FromSeconds(75)) return false;
        try { using var p = Process.GetProcessById(s.ProcessId); return p.ProcessName == "GpuManager.Agent" && Math.Abs((p.StartTime - s.AgentStarted.LocalDateTime).TotalSeconds) < 30; } catch { return false; }
    }
    private async Task RefreshStatusAsync()
    {
        if (refreshing || IsDisposed) return; refreshing = true;
        try
        {
            var payload = await Task.Run(() => (State: store.Read<Snapshot?>("status.json", null), Battery: store.Read<BatterySession?>("battery-current.json", null), Diagnosis: store.Read<Diagnosis?>("diagnosis.json", null)));
            if (IsDisposed) return;
            var s = payload.State;
            if (s is null) { status.Text = "Нет статуса наблюдателя. Он запускается при входе в Windows."; return; }
            var alive = Alive(s);
            var pauseText = s.Mode == "Nvidia" ? s.Until is { } until ? $" — осталось {Math.Max(0, Math.Ceiling((until - DateTimeOffset.Now).TotalMinutes))} мин." : " — до ручного отключения" : "";
            status.Text = $"Наблюдатель: {(alive ? "работает" : "нет свежего статуса")}\r\nРежим: {Engine.ModeName(s.Mode)}{pauseText}\r\n{s.Status}\r\nПоследнее событие: {s.Time:g}\r\nПоследнее энергосостояние: {s.GpuPower}";
            if (preview is null && alive && lastMessage != s.Status && (s.Status.Contains("подтверждение", StringComparison.OrdinalIgnoreCase) || s.Status.Contains("Ошибка") || s.Status.Contains("Только уведомление"))) { tray.ShowBalloonTip(7000, "GPU Manager", s.Status, ToolTipIcon.Info); }
            lastMessage = s.Status;
            if (payload.Diagnosis is { } d && d.Time != latestDiagnosis?.Time)
            {
                latestDiagnosis = d;
                diagnosis.Text = $"Проверено: {d.Time:g}\r\n{d.Explanation}\r\nNVIDIA: {d.Power.Power}; код проблемы: {d.Power.Problem}\r\n\r\nЭкраны:\r\n" + string.Join("\r\n", d.Displays.Select(p => $"{p.Monitor} — {p.Technology} — {(p.Nvidia ? "NVIDIA" : "Intel / другой адаптер")}")) + "\r\n\r\nКлиенты NVIDIA (выделенная память, не текущая нагрузка):\r\n" + string.Join("\r\n", d.Clients.Select(c => $"{c.Name} (PID {c.Id}) — {c.Path}")) + "\r\n" + string.Join("\r\n", d.Errors);
            }
            if (payload.Battery is { } m && m.Summary is { } summary)
                batteryStatus.Text = $"{m.Label} — {(m.Complete ? m.EndReason : "замер идёт")}\r\nОтсчётов: {summary.Samples}; длительность: {summary.DurationSeconds} сек.; средний расход: {summary.MeanDischargeWatts?.ToString("F2") ?? "нет данных"} Вт\r\nПо падению ёмкости: {summary.CapacityDeltaWatts?.ToString("F2") ?? "нет данных"} Вт; CPU: {summary.MeanCpuPercent?.ToString("F1") ?? "нет данных"} %";
            else batteryStatus.Text = "Замеров ещё нет. Отсутствующие показания батареи отображаются как «нет данных».";
            if (preview is null && alive && !prompting && s.Approval is { } request && request.Expires > DateTimeOffset.Now && seen.Add(request.Id))
            {
                prompting = true;
                try
                {
                    var clients = request.Clients.Length > 0 ? string.Join(", ", request.Clients.Select(c => $"{c.Name} (PID {c.Id})")) : "Клиенты не обнаружены";
                    var answer = MessageBox.Show(this, $"Перезапустить NVIDIA? Экран может мигнуть, графические ресурсы приложений могут прерваться.\r\n\r\nЗатрагиваемые клиенты: {clients}\r\n\r\nЗащиты будут повторно проверены. Запрос действует 90 секунд.", "Подтверждение перезапуска", MessageBoxButtons.YesNo, MessageBoxIcon.Warning);
                    Send(new(answer == DialogResult.Yes ? "Approve" : "Dismiss", request.Id));
                }
                finally { prompting = false; }
            }
        }
        catch (Exception e) { if (!IsDisposed) status.Text = "Не удалось прочитать состояние: " + e.Message; }
        finally { refreshing = false; }
    }
}
