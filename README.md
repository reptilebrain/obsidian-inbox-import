# Obsidian Inbox Import

[![Tests](https://github.com/reptilebrain/obsidian-inbox-import/actions/workflows/tests.yml/badge.svg?branch=main)](https://github.com/reptilebrain/obsidian-inbox-import/actions/workflows/tests.yml)
[![PSScriptAnalyzer](https://github.com/reptilebrain/obsidian-inbox-import/actions/workflows/analysis.yml/badge.svg?branch=main)](https://github.com/reptilebrain/obsidian-inbox-import/actions/workflows/analysis.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![PowerShell: 5.1 & 7](https://img.shields.io/badge/PowerShell-5.1%20%26%207-blue.svg)](#requirements)
[![Dependencies: none](https://img.shields.io/badge/Dependencies-none-brightgreen.svg)](#requirements)

Move loose `.txt` files from your Windows Desktop and Documents folders into an existing Obsidian vault's `00_Inbox`, changing the extension to `.md` without rewriting the file contents.

Text files have a habit of becoming permanent desktop residents. This script gives them somewhere predictable to go. Deciding what to do with the notes afterwards is a separate job.

## What it does

- Processes top-level `.txt` files in Desktop and Documents, including hidden files.
- Preserves each filename's stem and changes its extension to `.md`.
- Leaves the original file bytes and encoding unchanged.
- Supports dry runs, a configurable age limit and filename conflict handling.
- Logs normal runs outside the vault and continues after individual file or logging errors.

Subfolders, Downloads and other file types are not scanned. The script does not add headings, frontmatter, tags or links, and it does not organise existing notes or call an AI service.

## Requirements

- Windows with Windows PowerShell 5.1 or PowerShell 7.
- An existing vault folder and permission to access the source and destination files.
- Your own Windows account when running manually or through Task Scheduler.

No additional PowerShell module or Obsidian plugin is required. Obsidian does not need to be open.

## Configure your vault

Download and extract the repository ZIP, or clone the repository. Keep the script in a permanent folder before scheduling it.

The repository ships with **no configured vault path**. Use one of the following methods. Always specify the existing vault root, not `00_Inbox`.

### Option 1: local configuration file

Create `obsidian-inbox-import.local.ps1` beside `move-txt-to-obsidian-inbox.ps1`, containing:

```powershell
$DefaultVaultPath = 'D:\Notes\My Vault'
```

Replace the example with your own full path. This optional file is excluded by the repository's `.gitignore`, keeping machine-specific configuration out of normal commits. It also lets you update the main script without reapplying your path setting.

The file is executed as PowerShell, including during dry runs. Keep it to the configuration assignment shown above.

### Option 2: variable in the script

Set the existing variable near the top of `move-txt-to-obsidian-inbox.ps1`:

```powershell
$DefaultVaultPath = 'D:\Notes\My Vault'
```

This works without a local configuration file. Unlike the separate local file, edits to the main script are tracked by Git, so keep personal paths out of commits.

### Option 3: command-line parameter

```powershell
.\move-txt-to-obsidian-inbox.ps1 -VaultPath 'D:\Notes\My Vault' -DryRun
```

Configuration precedence:

| Priority | Source |
| --- | --- |
| 1 | Explicit `-VaultPath`; the local configuration file is not loaded |
| 2 | `$DefaultVaultPath` assigned by `obsidian-inbox-import.local.ps1` |
| 3 | `$DefaultVaultPath` in the main script |

An explicitly empty `-VaultPath` is an error; it does not fall back. Empty or whitespace-only settings and relative paths are rejected before logging starts, without prompting for input.

Use a full Windows drive path such as `D:\Notes\My Vault`, or a UNC path such as `\\server\share\My Vault`. Paths like `Notes\Vault`, `D:Vault` and `\Notes\Vault` are rejected.

The root must be an existing filesystem directory. The script does not initialise a vault or verify its identity through an `.obsidian` folder. A missing `00_Inbox` is created only when a real move is about to be attempted. If `00_Inbox` exists as a file, the run fails, including in dry-run mode.

## First run

After configuring your vault, open PowerShell in the script folder and preview:

```powershell
.\move-txt-to-obsidian-inbox.ps1 -DryRun
```

With the simple configuration above, a dry run creates no folders or logs and moves nothing. It shows proposed destinations and accounts for filename conflicts between the two source folders.

To preview a newly created test file without waiting for the default age limit:

```powershell
.\move-txt-to-obsidian-inbox.ps1 -DryRun -MinAgeMinutes 0
```

When the paths look right, run normally:

```powershell
.\move-txt-to-obsidian-inbox.ps1
```

This uses the default 60-minute age limit. Add `-MinAgeMinutes 0` to disable it for a real run too.

**Files are moved, not backed up.** The `.txt` source disappears after a successful import. A dry run does not test write permissions or guarantee that a later move will succeed.

## Age filtering and name conflicts

| Parameter | Default | Behaviour |
| --- | --- | --- |
| `-VaultPath` | Uses configured setting | Overrides the vault path for this run |
| `-DryRun` | Off | Shows proposed imports without performing them |
| `-MinAgeMinutes` | `60` | Skips recently created or modified files; `0` disables both checks |

A file is skipped if its creation time **or** last modification time is at or newer than the cutoff. `SKIP (too recent)` is expected behaviour, not an error. File timestamps are refreshed before this check, but the age limit cannot determine whether an application still needs the file.

The first choice for `idea.txt` is `idea.md`. If that name is occupied, the script adds a timestamp and counter:

```text
idea - import 20260915-120658-1.md
idea - import 20260915-120658-2.md
```

Every candidate is checked. The move operation also refuses to overwrite a destination created by another process after that check. This is filename conflict handling, not content-based duplicate detection.

Before reporting a successful import, the script checks that the destination is a file and the source is absent. It reports an incomplete move as an error without automatically deleting a remaining source. Before creating the inbox for a real move, the script checks the vault root again and aborts remaining imports if that check finds it missing or no longer a filesystem directory. The vault can still change between the check and the operation; this does not eliminate concurrency races.

## Task Scheduler

You can update an existing activity or create a separate task for the importer. Use your own Windows account because Desktop and Documents are resolved for the account running the script.

For a straightforward desktop setup, choose **Run only when user is logged on**, select a suitable trigger, and set **If the task is already running** to **Do not start a new instance**.

For a script stored in `C:\Scripts`, with the vault configured locally:

| Action field | Value |
| --- | --- |
| Program/script | `C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe` |
| Start in | `C:\Scripts` |

**Add arguments:**

```text
-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "C:\Scripts\move-txt-to-obsidian-inbox.ps1" -MinAgeMinutes 60
```

Alternatively, pass the vault path directly:

```text
-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "C:\Scripts\move-txt-to-obsidian-inbox.ps1" -VaultPath "D:\Notes\My Vault" -MinAgeMinutes 60
```

Adjust the paths. These lines belong in **Add arguments**, not directly in a PowerShell prompt. Use the full path to your installed `pwsh.exe` as the executable if you prefer PowerShell 7.

| Switch | Meaning |
| --- | --- |
| `-NoProfile` | Skips loading PowerShell profiles; the script's local config can still load |
| `-NonInteractive` | Makes interactive PowerShell prompts fail instead of waiting for input |
| `-WindowStyle Hidden` | Hides the PowerShell window |
| `-ExecutionPolicy Bypass` | Requests execution-policy bypass for this process without permanently changing the configured policy |
| `-File` | Selects the script; parameters after its path belong to the script |

`Bypass` does not grant administrator rights or override Group Policy. Omit it if your execution policy already permits the script and its local configuration. See [Microsoft's command-line documentation](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_powershell_exe?view=powershell-5.1) and [execution-policy documentation](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_execution_policies).

Preview manually first. A hidden scheduled dry run creates no log, so there is no saved preview to inspect. After setup, run the task manually and check the log and **Last Run Result**.

## Logs and results

Normal runs attempt to create a unique `obsidian-*.log` under:

```text
%LOCALAPPDATA%\DesktopCleanup\Logs
```

Paste that path into Explorer. Logs include settings, successful moves, recent files skipped, errors and a final summary. The shared directory name follows the related Desktop Cleanup scripts; they are not a dependency.

Old logs are not removed automatically. An earlier `txt-import.log` inside the vault is left untouched.

| Exit code | Meaning |
| --- | --- |
| `0` | No reported errors, including an empty run |
| `1` | At least one configuration, filesystem or logging error |

The console summary reports `Moved`, `Planned` and `Skipped`. Successful moves do not cancel out other errors: a run can move files and still return `1`.

If logging fails, a warning is shown and file processing continues. A log write failure disables further writes to that log. Task Scheduler commonly displays script exit codes as `0x0` and `0x1`; startup failures may produce other results and no script log.

## Troubleshooting and limits

- **Downloaded script blocked:** review the file, then run `Unblock-File -LiteralPath .\move-txt-to-obsidian-inbox.ps1`. This helps under `RemoteSigned`; it does not override an all-signed policy. See [Microsoft's Unblock-File documentation](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.utility/unblock-file).
- **Nothing imported:** check the source location, `.txt` extension and age limit. Downloads and subfolders are excluded.
- **Configuration error:** check the filename and location of the local config, or pass `-VaultPath` explicitly. An existing directory is required; the script will not deliberately create a missing vault root.
- **Scheduled run fails:** run visibly in PowerShell to inspect errors. A file can be old enough to qualify and still be locked or needed by another application.
- **OneDrive:** Windows supplies redirected source locations. Files are not excluded merely for having a reparse-point attribute. Online-only files may need downloading, and moving files out of a synced folder changes that folder on your other devices too.
- **Markdown and encoding:** `.txt` to `.md` is an extension change only. Legacy encodings are not repaired; Markdown syntax already present in the text may be rendered by Obsidian.
- **Concurrent changes:** checks reduce common problems but do not make the operation atomic. Moves between drives are not transactional. There is no automatic rollback, content-hash verification during normal imports or repair of existing links to moved files.

## Tests

[GitHub Actions](https://github.com/reptilebrain/obsidian-inbox-import/actions/workflows/tests.yml) runs [tests/run-tests.ps1](tests/run-tests.ps1) on Windows in separate Windows PowerShell 5.1 and PowerShell 7 jobs. The workflow runs for pull requests targeting `main`, pushes to `main` and manual dispatch, with `contents: read` permissions.

Run locally from the repository root:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\run-tests.ps1
pwsh.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\run-tests.ps1
```

Each command requires its corresponding PowerShell installation. No Pester installation is needed.

The tests execute temporary copies with substituted source folders and a temporary `LOCALAPPDATA`. They do not copy your machine-local configuration. Test folders remain under the printed temporary test root for inspection and can be removed afterwards.

Coverage includes configuration precedence, empty and relative paths, dry runs, age filtering, name conflicts, unchanged content hashes, inbox validation, empty runs and continued processing after file and logging failures. Selected failure paths use injected changes or test doubles, including a disappearing vault and an incomplete move. UNC checks verify path format without accessing a real network share.

## Static analysis

The separate PSScriptAnalyzer workflow checks tracked PowerShell files in both Windows PowerShell 5.1 and PowerShell 7. It uses PSScriptAnalyzer 1.25.0 and fails on errors or warnings. The ignored local configuration is excluded.

Local analysis requires Git on `PATH` and a Git checkout of this repository: `tests/run-analysis.ps1` uses `git ls-files` to select tracked files. An extracted repository ZIP alone is not enough for this analysis command. Normal imports and the integration test suite do not require Git.

From the repository root, install the pinned analyzer and run:

```powershell
Install-Module PSScriptAnalyzer -RequiredVersion 1.25.0 -Scope CurrentUser
.\tests\run-analysis.ps1
```

The internal `New-Case` test fixture has one documented, function-scoped exception to `PSUseShouldProcessForStateChangingFunctions`: it must create a complete set of isolated temporary test data. Other functions and rules remain checked. The analyzer is a development dependency; normal imports do not need it.

## Related project

[Desktop Cleanup](https://github.com/reptilebrain/desktop-cleanup) contains separate PowerShell scripts for sorting images, audio and video and recycling unwanted desktop shortcuts.

## License

Released under the [MIT License](LICENSE).

Copyright (c) 2026 P-A Jonasson.
