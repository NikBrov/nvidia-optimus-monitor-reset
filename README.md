# NVIDIA Optimus Monitor Reset — GPU Manager v6

Windows utility for muxless NVIDIA Optimus laptops where applications keep the discrete GPU active after an external monitor is disconnected. Tested on an Acer Predator Triton 300 SE PT314-51s with Intel Iris Xe and NVIDIA RTX 3060.

GPU Manager assigns everyday applications to Intel, keeps NVIDIA available for demanding applications, and considers a guarded device restart after display/power events. It does not migrate already-running applications between GPUs or guarantee a particular battery-life improvement.

## Возможности

- Режимы **Авто**, **Экономия энергии**, пауза автосброса на 30 минут, 2 часа или до ручного отключения.
- Управление приложениями: Intel / NVIDIA / выбор Windows, удаление из управления и восстановление исходного назначения.
- Диагностика энергосостояния, подключённых экранов и клиентов NVIDIA по данным Windows.
- Политика сброса: автоматически после проверок, спрашивать или только уведомлять. Ручной запрос всегда требует подтверждения.
- Встроенная защита рабочих приложений и добавление собственных защищённых EXE.
- История событий, экспорт JSON-отчёта и отдельный учёт активного времени и времени сна.
- Замеры расхода батареи на 5–10 минут, CPU-нагрузка, состояние GPU и сохранение JSON/CSV.

Подробное описание всех кнопок: [README.txt](README.txt).

## Install / установка

Requirements: Windows 11, Windows PowerShell 5.1, an interactive user account with administrator elevation available, Intel + one NVIDIA display adapter. NVIDIA adapter mapping must be available through `QueryDisplayConfig`. Other laptop models and multi-NVIDIA systems have not been validated.

```powershell
git clone https://github.com/NikBrov/nvidia-optimus-monitor-reset.git
cd nvidia-optimus-monitor-reset
.\Update-v6.cmd
```

Or download the repository ZIP, extract it and open **Update-v6.cmd**. Confirm the Windows UAC prompt. This entry point supports a fresh installation and upgrading an existing `C:\NvidiaReset` installation. The fresh-install path has been inspected and parsed but has not been exercised on a clean second laptop; the running v6 application was validated on the Acer above.

Installation creates:

- `C:\NvidiaReset` — protected application code;
- `C:\NvidiaReset\data` — writable state, preferences, logs and battery sessions;
- scheduled task **Auto Reset NVIDIA on Monitor Disconnect**, at user logon, allowed on battery, without a runtime limit;
- desktop shortcuts **GPU - Intel и NVIDIA** and **GPU - Инструкция**.

Open the panel normally, without “Run as administrator”. The background scheduled task has the rights needed for device restart; programs launched from the panel run with the user's ordinary token.

The installer automatically detects a single NVIDIA display device when `DeviceId` in `config.json` is empty. With multiple NVIDIA devices, specify the exact adapter ID yourself. Example executable paths in the configuration reflect the tested application versions; adjust them for your installed software. `%APPDATA%` and `%LOCALAPPDATA%` are expanded for the current user. Existing installations keep their configuration and data.

Restart applications after changing their GPU preference. User choices in the panel override the default managed list. Removing an app from management preserves its current Windows setting; restoring its original assignment also stops managing it.

## Restart policy and limitations

After a relevant event, the manager waits 15 seconds. A restart requires an active internal display, no external displays, a healthy NVIDIA device in D0, no protected applications, no unknown GPU clients, and a five-minute cooldown. Safety checks are repeated immediately before `pnputil /restart-device` for the exact adapter.

An approval expires after 90 seconds and is invalidated by a changed client list. Old requests are cancelled after resume. A successful restart is followed by passive checks at approximately 20 and 60 seconds; an unchanged power state does not cause another restart for that event. Automatic resets are suspended during battery measurements.

Restarting the device can interrupt graphics resources, video playback or calls; conservative checks do not guarantee application recovery. There remains a small race between the last check and a newly started application. The manager does not close user applications.

No continuous `nvidia-smi` / NVML polling is used. D0/D3 is the last device power state reported by Windows, not a watt measurement or proof of D3cold. GPU memory allocations identify possible clients, not instantaneous utilization or definite causality. An HDMI port physically wired to NVIDIA still needs NVIDIA for display output.

Battery measurements report **whole-laptop** consumption, not NVIDIA alone. Compare completed runs with the same brightness, apps and workload. Sleep, AC connection and interruptions invalidate a run. Missing discharge data is displayed as unavailable, not zero watts. A short run cannot prove the cause of a change in consumption.

## Configuration and privacy

`config.json` contains default app paths, protected process names, restart delay and cooldown. `data/app-overrides.json` contains user choices; `data/options.json` contains the reset policy and user-protected paths. Packaged Store app paths are refreshed at startup and daily; a user override applies to an exact EXE path and should be reviewed after an update changes that path.

Local logs, reports, device-specific state, preference backups and measurements are excluded from Git. Reports contain application paths and event history; inspect an exported report before sharing it.

## Rollback

From an administrator PowerShell window:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\NvidiaReset\rollback-v6.ps1"
```

An upgrade restores the previous application files, saved preferences and scheduled task, and starts that task. Its previous behavior applies, including startup resets if an older version had them. A fresh-install rollback removes the task and matching desktop shortcuts and restores preferences. Files, logs and measurements are retained. The installer creates its backup under `C:\NvidiaReset\backup-v5-*` before replacing files.

## Development and validation

Scripts containing Russian text use **UTF-8 with BOM** for Windows PowerShell 5.1. Keep that encoding when editing. `GpuNative.cs` is compiled by `Add-Type` at runtime; no prebuilt binaries are required.

On a compatible Windows laptop, from the repository directory:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\test-v6.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\test-approval.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\smoke-v6.ps1
```

The policy suite checks reset gates, preferences, original-value restoration and battery calculations. It uses a temporary registry value for a fixture EXE and removes it afterwards. The approval test uses isolated mock clients and forbids real restart calls. The smoke test runs `ObserveOnly` with a separate mutex and never restarts the GPU. They create temporary state under the checkout; run against a separate checkout, not the protected installed folder.

Validated on the Acer: policy tests, confirmation flow including changed clients, observer command processing, panel layout, installed task and a manual check that correctly skipped restarting a D3 GPU. Controlled physical unplug tests, a fresh installation on a clean laptop and comparative 5–10 minute battery runs remain unverified.

## Windows APIs

- [QueryDisplayConfig](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-querydisplayconfig) — display topology.
- [SYSTEM_BATTERY_STATE](https://learn.microsoft.com/en-us/windows/win32/api/winnt/ns-winnt-system_battery_state) — battery discharge readings.
- [QueryUnbiasedInterruptTime](https://learn.microsoft.com/en-us/windows/win32/api/realtimeapiset/nf-realtimeapiset-queryunbiasedinterrupttime) — active time excluding sleep and hibernation.

MIT license. See [LICENSE](LICENSE).
