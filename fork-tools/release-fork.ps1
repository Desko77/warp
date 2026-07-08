#!/usr/bin/env pwsh
#
# release-fork.ps1 - сборка warp-oss (канал oss) и публикация GitHub Release в форк.
#
# Форк-специфичный инструмент (не из upstream). Собирает Inno-Setup инсталлятор через
# существующий script/windows/bundle.ps1 и заливает его как ассет релиза через gh CLI.
#
# Тег генерируется в формате, который понимает автообновление Warp:
#   v0.ГГГГ.ММ.ДД.ЧЧ.ММ.oss_NN
# (регэксп crates/channel_versions/src/lib.rs:34, дата парсится как %Y.%m.%d.%H.%M).
#
# Примеры:
#   .\fork-tools\release-fork.ps1 -DryRun      # показать что будет, без сборки/публикации
#   .\fork-tools\release-fork.ps1              # собрать и опубликовать релиз
#   .\fork-tools\release-fork.ps1 -SkipBuild   # взять уже собранный инсталлятор и опубликовать
#   .\fork-tools\release-fork.ps1 -Draft       # создать релиз как черновик

[CmdletBinding()]
Param(
    # Репозиторий-форк, куда публикуем релиз.
    [String]$Repo = 'Desko77/warp',

    # Ветка или коммит, на который вешается тег на стороне GitHub.
    # По умолчанию - текущая ветка. Коммит должен быть уже запушен в origin.
    [String]$Target = '',

    # Пропустить сборку (использовать уже готовый инсталлятор из script/windows/Output).
    [Switch]$SkipBuild,

    # Создать релиз как черновик (не публиковать сразу).
    [Switch]$Draft,

    # Ничего не собирать и не публиковать - только показать план действий.
    [Switch]$DryRun,

    # Текст примечаний к релизу. Если пусто - генерируется из git log.
    [String]$Notes = ''
)

$ErrorActionPreference = 'Stop'

function Fail($msg) { Write-Error $msg; exit 1 }
function Info($msg) { Write-Host "[release-fork] $msg" -ForegroundColor Cyan }

# --- Корень репозитория (папка скрипта / ..) ---
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
Set-Location $RepoRoot
Info "Корень репозитория: $RepoRoot"

# --- Проверка окружения ---

# gh CLI
if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
    Fail "gh CLI не найден в PATH. Установи GitHub CLI и выполни 'gh auth login'."
}
# Проверка авторизации gh (не роняем на DryRun, но предупреждаем)
gh auth status 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) {
    Fail "gh не авторизован. Выполни 'gh auth login' (нужен доступ на запись в $Repo)."
}

# cargo (нужен для сборки)
if (-not $SkipBuild -and -not (Get-Command cargo -ErrorAction SilentlyContinue)) {
    # Типовое расположение cargo, если не в PATH
    $cargoBin = Join-Path $env:USERPROFILE '.cargo\bin'
    if (Test-Path (Join-Path $cargoBin 'cargo.exe')) {
        $env:PATH = "$cargoBin;$env:PATH"
        Info "cargo добавлен в PATH из $cargoBin"
    } else {
        Fail "cargo не найден. Нужен для сборки (или запусти с -SkipBuild)."
    }
}

# ISCC (Inno Setup) - bundle.ps1 вызывает '& ISCC' напрямую, значит должен быть в PATH.
if (-not $SkipBuild -and -not (Get-Command ISCC -ErrorAction SilentlyContinue)) {
    $isccCandidates = @(
        (Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 6\ISCC.exe'),
        (Join-Path $env:ProgramFiles 'Inno Setup 6\ISCC.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe')
    )
    $iscc = $isccCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
    if ($iscc) {
        $env:PATH = "$(Split-Path $iscc);$env:PATH"
        Info "Inno Setup добавлен в PATH: $(Split-Path $iscc)"
    } else {
        Fail "ISCC (Inno Setup) не найден. Установи: winget install JRSoftware.InnoSetup"
    }
}

# --- Цель для тега (ветка/коммит) ---
if (-not $Target) {
    $Target = (git rev-parse --abbrev-ref HEAD).Trim()
}
$localSha = (git rev-parse HEAD).Trim()
# Проверяем, что цель есть на origin и совпадает с локальным HEAD (иначе тег ляжет не туда)
$remoteSha = (git rev-parse "origin/$Target" 2>$null)
if ($LASTEXITCODE -ne 0 -or -not $remoteSha) {
    Info "ВНИМАНИЕ: ветка origin/$Target не найдена. Убедись, что ветка запушена в форк (git push origin $Target)."
} elseif ($remoteSha.Trim() -ne $localSha) {
    Info "ВНИМАНИЕ: локальный HEAD ($($localSha.Substring(0,9))) != origin/$Target ($($remoteSha.Trim().Substring(0,9)))."
    Info "Тег ляжет на коммит из origin/$Target. При необходимости сначала: git push origin $Target"
}

# --- Генерация свободного тега v0.<дата>.oss_NN ---
$stamp = (Get-Date).ToString('yyyy.MM.dd.HH.mm')
$base  = "v0.$stamp.oss"

# Собираем множество занятых тегов: локальные git-теги + релизы форка
$takenTags = @()
$takenTags += (git tag --list "$base*")
$ghTags = (gh release list --repo $Repo --limit 200 2>$null | ForEach-Object { ($_ -split "`t")[0] })
if ($ghTags) { $takenTags += $ghTags }
$takenTags = $takenTags | Where-Object { $_ } | ForEach-Object { $_.Trim() }

$nn = 0
do {
    $tag = "{0}_{1:00}" -f $base, $nn
    $nn++
} while ($takenTags -contains $tag)
Info "Тег релиза: $tag"

# --- Примечания к релизу ---
if (-not $Notes) {
    $lastTag = (git describe --tags --abbrev=0 --match "v0.*.oss_*" 2>$null)
    if ($lastTag) {
        $log = (git log "$lastTag..HEAD" --oneline --no-merges) -join "`n"
        $Notes = "Изменения с $lastTag`:`n`n$log"
    } else {
        $log = (git log -20 --oneline --no-merges) -join "`n"
        $Notes = "Сборка warp-oss $tag`n`nПоследние коммиты:`n$log"
    }
    if (-not $Notes.Trim()) { $Notes = "Сборка warp-oss $tag" }
}

# Имя инсталлятора зависит от архитектуры (совпадает с bundle.ps1 FILE_ENDING
# и app/src/autoupdate/windows.rs installer_file_name).
$archSuffix = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { '-arm64' } else { '' }
$installer = Join-Path $RepoRoot "script\windows\Output\WarpOssSetup$archSuffix.exe"

# --- DryRun: показать план и выйти ---
if ($DryRun) {
    Info "=== DryRun: действия НЕ выполняются ==="
    Write-Host "  Репозиторий : $Repo"
    Write-Host "  Тег         : $tag"
    Write-Host "  Цель тега   : $Target ($($localSha.Substring(0,9)))"
    Write-Host "  Сборка      : $(if ($SkipBuild) { 'пропущена (-SkipBuild)' } else { 'bundle.ps1 -CHANNEL oss -release-tag ' + $tag })"
    Write-Host "  Инсталлятор : $installer"
    Write-Host "  Черновик    : $Draft"
    Write-Host "  Примечания  :"
    Write-Host ($Notes -split "`n" | ForEach-Object { "    $_" }) -Separator "`n"
    exit 0
}

# --- Сборка ---
if (-not $SkipBuild) {
    Info "Сборка warp-oss (канал oss). Это долго - профиль rlto (ThinLTO)."
    & (Join-Path $RepoRoot 'script\windows\bundle.ps1') -CHANNEL oss -release-tag $tag
    if ($LASTEXITCODE -ne 0) { Fail "Сборка (bundle.ps1) завершилась с ошибкой." }
}

# --- Проверка артефакта ---
if (-not (Test-Path $installer)) {
    Fail "Инсталлятор не найден: $installer. Сборка не создала ассет?"
}
$sizeMb = [math]::Round((Get-Item $installer).Length / 1MB, 1)
Info "Инсталлятор готов: $installer ($sizeMb МБ)"

# --- Манифест версий для автообновления (channel_versions.json) ---
# Автообновление oss читает его по URL releases/latest/download/channel_versions.json.
# Структура ChannelVersions: обязательны поля dev/preview/stable, у каждого version.
# Все три указывают на один тег - у форка единый oss-поток, а код читает stable.
$manifest = Join-Path $RepoRoot 'script\windows\Output\channel_versions.json'
$cv = [ordered]@{
    dev     = [ordered]@{ version = $tag }
    preview = [ordered]@{ version = $tag }
    stable  = [ordered]@{ version = $tag }
}
$cv | ConvertTo-Json -Depth 5 | Set-Content -Path $manifest -Encoding utf8NoBOM
Info "Манифест версий: $manifest"

# --- Публикация релиза ---
# Инсталлятор + манифест как ассеты. Релиз помечается latest (не -Draft),
# иначе releases/latest/download/... не резолвится и автообновление не увидит версию.
$ghArgs = @('release', 'create', $tag, $installer, $manifest,
            '--repo', $Repo,
            '--title', $tag,
            '--notes', $Notes,
            '--target', $Target)
if ($Draft) { $ghArgs += '--draft' }

Info "Публикация релиза в $Repo ..."
gh @ghArgs
if ($LASTEXITCODE -ne 0) { Fail "gh release create завершился с ошибкой." }

$url = (gh release view $tag --repo $Repo --json url --jq '.url' 2>$null)
Info "Готово. Релиз: $url"
