<#
.SYNOPSIS
    Главный скрипт запуска и управления Telegram ботом.

.DESCRIPTION
    Скрипт инициализирует и запускает многопоточную систему обработки Telegram бота.
    Создает и управляет несколькими потоками выполнения для обработки различных типов данных.
#>

Param(
    [string]$settingsPath = 'D:\Scripts\VRF\verifybot\pbSettings\BotSettings.json'
    # [string]$settingsPath = 'D:\PSProject\verifybot\pbSettings\BotSettings.json'
)

# ------------------------------------------------------------------------------------------------------------------------------------------------------------------------
# Читаем настройки. Импортируем вспомогательные функции.
# ------------------------------------------------------------------------------------------------------------------------------------------------------------------------
$botSettings = Get-Content -Path $settingsPath | ConvertFrom-Json
$appPath = $botSettings.appPath

# Параметры логирования
$logFile   = $appPath + "\" + ($botSettings.logging.logFile).Replace("\\", "\")
$errorFile   = $appPath + "\" + ($botSettings.logging.errorFile).Replace("\\", "\")
$maxSizeMB = $botSettings.Logging.maxSizeMB
$keepFiles = $botSettings.Logging.keepFiles

try {
    Import-Module "$appPath\pbStart\GetRunspaces.ps1"
    Import-Module "$appPath\pbModules\Utils\Utils.ps1"
}
catch {
    $tempKey = "$((Get-Date).Day).$((Get-Date).Month).$((Get-Date).Year).$((Get-Date).TimeOfDay)" 
    $queueErrorHash[$tempKey] = @{ source = 'Create-Runspace'; message = "Error import modules: " + $_.Exception.Message }
    Write-Host "Error import modules: " $_.Exception.Message -ForegroundColor Red -BackgroundColor Black
    return $false
}

# ------------------------------------------------------------------------------------------------------------------------------------------------------------------------
# Создаем список пространств выполнения.
# ------------------------------------------------------------------------------------------------------------------------------------------------------------------------
$runspaces = New-Object System.Collections.ArrayList 

# Создаем синхронизируемые хэш-таблицы, для передачи в пространства выполнения.
# ------------------------------------------------------------------------------------------------------------------------------------------------------------------------
$queueUsersHash = [hashtable]::Synchronized(@{})             # База пользователей
$queueGroupsHash = [hashtable]::Synchronized(@{})            # База списка групп
$queueMessageHash = [hashtable]::Synchronized(@{})           # Очередь сообщений типа Message
$queueInlineHash = [hashtable]::Synchronized(@{})            # Очередь inline-запросов
$queueCallbackHash = [hashtable]::Synchronized(@{})          # Очередь сообщений типа Callback
$queueErrorHash = [hashtable]::Synchronized(@{})             # Очередь ошибок
$queueSendingHash = [hashtable]::Synchronized(@{})           # Очередь отправки сообщений
$queueDebugHash = [hashtable]::Synchronized(@{})             # Таблица для отладочных сообщений
$queueLogHash = [hashtable]::Synchronized(@{})               # Таблица логов

$queueCommandsHash = [hashtable]::Synchronized(@{
    'settingsPath' = $settingsPath;
    'appPath' = $botSettings.appPath;
    'apiUrl' = $botSettings.apiUrl;
    'eulaUrl' = $botSettings.eulaUrl;
    'alertGroup' = $botSettings.alertGroup;
    'alertThreadBlocked' = $botSettings.alertThreadBlocked;
    'alertThreadUninvited' = $botSettings.alertThreadUninvited;
    'alertThreadPhoneNotFound' = $botSettings.alertThreadPhoneNotFound;
    'alertThreadSystemError' = $botSettings.alertThreadSystemError;
    'alertThreadAdded' = $botSettings.alertThreadAdded;
    'alertThreadBalance' = $botSettings.alertThreadBalance;
    'alertThreadUsersOut' = $botSettings.alertThreadUsersOut;
    'botID' = $botSettings.botID;
    'checkToken' = $botSettings.checkToken;
    'gateID' = $botSettings.gateID;
    'botNum' = $botSettings.botNum;
    'botCreator' = $botSettings.botCreator;
    'banIfNotVerified' = $botSettings.banIfNotVerified;
    'mainLogo' = $botSettings.mainLogo;
    'mainLogoAlert' = $botSettings.mainLogoAlert;
    'groupItemLogo' = $botSettings.groupItemLogo;
    'groupItemVerified' = $botSettings.groupItemVerified;
    'groupItemBlocked' = $botSettings.groupItemBlocked;
    'groupItemWaiting' = $botSettings.groupItemWaiting;
    'inlineRunspacesMax' = $botSettings.inlineRunspacesMax;
    'inlineRunspacesSleepTime' = $botSettings.inlineRunspacesSleepTime
    'messageRunspacesMax' = $botSettings.messageRunspacesMax;
    'messageRunspacesSleepTime' = $botSettings.messageRunspacesSleepTime
    'callbackRunspacesMax' = $botSettings.callbackRunspacesMax
    'callbackRunspacesSleepTime' = $botSettings.callbackRunspacesSleepTime
    'getUpdateTimeout' = $botSettings.getUpdateTimeoutSec;
    'getUpdateSleepTime' = $botSettings.getUpdateSleepTime;
    'checkStaffSleepTimeSec' = $botSettings.checkStaffSleepTimeSec;
    'sendingRunspacesMax' = $botSettings.sendingRunspacesMax;
    'sendingMaxRetries' = $botSettings.sendingMaxRetries;
    'preserveOrderPerChat' = $botSettings.preserveOrderPerChat;
    'sendingRunspacesSleepTime' = $botSettings.sendingRunspacesSleepTime;
    'verifiTtl' = $botSettings.verifiTtl;
    'blockPeriod' = $botSettings.blockPeriod;
    'checkStaffRun' = $false;
    'updateNonStop' = $true;
    'checkStaffNonStop' = $true;
    'messageNonStop' = $true;
    'callbackNonStop' = $true;
    'inlineNonStop' = $true;
    'sendingNonStop' = $true;
    'debugStop' = $false;
    'stopRequested' = $false;

})                                                           # Массив команд

# Загружаем базу пользователей
# -----------------------------------------------------------------------------------------------------------------
try {
    $jsonFilePath = "$appPath\pbAssets\queueUsersHash.json"
    $jsonContent = Get-Content -Path $jsonFilePath -ErrorAction Stop
    $jsonData = $jsonContent | ConvertFrom-Json -ErrorAction Stop

    if ($jsonData) {
        $jsonData | Get-Member -MemberType NoteProperty | ForEach-Object {
            $fieldName = $_.Name
            $fieldValue = $jsonData.$fieldName
            $fieldValue = ConvertTo-Hashtable -InputObject $fieldValue
            $queueUsersHash[$fieldName] = $fieldValue
        }
    
        $tempKey = Get-tempKey; $queueLogHash[$tempKey] = @{ source = 'Create-Runspace';message = "База пользователей успешно загружена по пути: $jsonFilePath" }
        Write-Host "База пользователей успешно загружена по пути: $jsonFilePath" -ForegroundColor Green -BackgroundColor Black
    
    }
}
catch {
    $tempKey = Get-tempKey; 
    $queueErrorHash[$tempKey] = @{ source = 'Create-Runspace'; message = "Ошибка загрузки пользоватлей по пути: $jsonFilePath" + $_.Exception.Message }
    Write-Host "Ошибка загрузки пользоватлей по пути: $jsonFilePath" $_.Exception.Message -ForegroundColor Red -BackgroundColor Black
    # return $false
}

# Загружаем базу групп
# -----------------------------------------------------------------------------------------------------------------
try {
    $jsonFilePath = "$appPath\pbAssets\queueGroupsHash.json"
    $jsonContent = Get-Content -Path $jsonFilePath -ErrorAction Stop
    $jsonData = $jsonContent | ConvertFrom-Json -ErrorAction Stop

    if ($jsonData) {
        $jsonData | Get-Member -MemberType NoteProperty | ForEach-Object {
            $fieldName = $_.Name
            $fieldValue = $jsonData.$fieldName
            $fieldValue = ConvertTo-Hashtable -InputObject $fieldValue
            $queueGroupsHash[$fieldName] = $fieldValue
        }
    
        $tempKey = Get-tempKey; $queueLogHash[$tempKey] = @{ source = 'Create-Runspace';message = "База групп успешно загружена по пути: $jsonFilePath" }
        Write-Host "База групп успешно загружена по пути: $jsonFilePath" -ForegroundColor Green -BackgroundColor Black
    }
}
catch {
    $tempKey = Get-tempKey; 
    $queueErrorHash[$tempKey] = @{ source = 'Create-Runspace'; message = "Ошибка загрузки групп по пути: $jsonFilePath" + $_.Exception.Message }
    Write-Host "Ошибка загрузки групп по пути: $jsonFilePath" $_.Exception.Message -ForegroundColor Red -BackgroundColor Black
    # return $false
}

# Очищаем временные переменные
# -----------------------------------------------------------------------------------------------------------------
$jsonData = $null
$jsonContent = $null

# Создание начального состояния сессии (InitialSessionState) с настройками по умолчанию
# -----------------------------------------------------------------------------------------------------------------
$sessionState = [system.management.automation.runspaces.initialsessionstate]::CreateDefault()

# Создание пула runspace (областей выполнения) с параметрами:
# - Минимальное количество потоков: 1
# - Максимальное количество потоков: 5
# - Использование созданного начального состояния сессии ($sessionState)
# - Передача объекта хоста (Host) для взаимодействия с окружением
# -----------------------------------------------------------------------------------------------------------------
$runspacePool = [runspacefactory]::CreaterunspacePool(1, 6, $sessionState, $Host)

# Инициализация и запуск созданного пула runspace
# (активация потоков и подготовка к выполнению команд)
# -----------------------------------------------------------------------------------------------------------------
$runspacePool.Open()


# Создаем экземпляр powershell для psMessageHandler. Читаем блок сценариев из файла и передаем вместе с аргументами.
# -----------------------------------------------------------------------------------------------------------------
$messageHandlerScript = Get-Command "$appPath\pbStart\pbScriptBlocks\MessageHandlerScriptBlock.ps1" | Select-Object -ExpandProperty ScriptBlock
$psMessageHandler = [powershell]::Create().AddScript($messageHandlerScript).
    AddArgument($queueUsersHash).
    AddArgument($queueGroupsHash).
    AddArgument($queueMessageHash).
    AddArgument($queueErrorHash).
    AddArgument($queueSendingHash).
    AddArgument($queueCommandsHash).
    AddArgument($queueDebugHash).
    AddArgument($queueLogHash)

# Указываем пул для пространства выполнения
$psMessageHandler.runspacePool = $runspacePool

# Создаем временную коллекцию пространства выполнения psMessageHandler
$tempMessageHandler = "" | Select-Object PowerShell, Runspace, Description
$tempMessageHandler.PowerShell = $psMessageHandler
$tmpDate = Get-tempKey
$tempMessageHandler.Description = "Поток psMessageHandler с ключом: $tmpDate"

# Сохраняем вывод дескриптора при вызове BeginInvoke(). Он будет использоваться для завершения пространства выполнения

$tempMessageHandler.Runspace = $psMessageHandler.BeginInvoke()
$runspaces.Add($tempMessageHandler) | Out-Null 

$tempKey = Get-tempKey; $queueLogHash[$tempKey] = @{ source = 'Create-Runspace';message = ("В пул добавлено: {0}" -f $tempMessageHandler.Description) }
Write-Host ("Create-Runspace В пул добавлено: {0}" -f $tempMessageHandler.Description) -ForegroundColor DarkYellow -BackgroundColor Black
# ------------------------------------------------------------------------------------------------------------------------------------------------------------------------

# Создаем экземпляр powershell для psCallbackHandler, передаем блок сценариев и аргументы
# ------------------------------------------------------------------------------------------------------------------------------------------------------------------------
$callbackHandlerScript = Get-Command "$appPath\pbStart\pbScriptBlocks\CallbackHandlerScriptBlock.ps1" | Select-Object -ExpandProperty ScriptBlock
$psCallbackHandler = [powershell]::Create().AddScript($callbackHandlerScript).
    AddArgument($queueGroupsHash).
    AddArgument($queueUsersHash).
    AddArgument($queueCallbackHash).
    AddArgument($queueErrorHash).
    AddArgument($queueSendingHash).
    AddArgument($queueCommandsHash).
    AddArgument($queueDebugHash).
    AddArgument($queueLogHash)
$psCallbackHandler.runspacePool = $runspacePool

$tempCallbackHandler = "" | Select-Object PowerShell, Runspace, Description
$tempCallbackHandler.PowerShell = $psCallbackHandler
$tmpDate = Get-tempKey
$tempCallbackHandler.Description = "Поток psCallbackHandler с ключом: $tmpDate"

$tempCallbackHandler.Runspace = $psCallbackHandler.BeginInvoke()
$runspaces.Add($tempCallbackHandler) | Out-Null 

$tempKey = Get-tempKey; $queueLogHash[$tempKey] = @{ source = 'Create-Runspace';message = ("В пул добавлено: {0}" -f $tempCallbackHandler.Description) }
Write-Host ("В пул добавлено: {0}" -f $tempCallbackHandler.Description) -ForegroundColor DarkYellow -BackgroundColor Black
# ------------------------------------------------------------------------------------------------------------------------------------------------------------------------

# Создаем экземпляр powershell для psSendingHandler, передаем блок сценариев и аргументы
# ------------------------------------------------------------------------------------------------------------------------------------------------------------------------
$sendingHandlerScript = Get-Command "$appPath\pbStart\pbScriptBlocks\SendingHandlerScriptBlock.ps1" | Select-Object -ExpandProperty ScriptBlock
$psSendingHandler = [powershell]::Create().AddScript($sendingHandlerScript).
    AddArgument($queueUsersHash).
    AddArgument($queueSendingHash).
    AddArgument($queueErrorHash).
    AddArgument($queueCommandsHash).
    AddArgument($queueDebugHash).
    AddArgument($queueLogHash)
$psSendingHandler.runspacePool = $runspacePool

$tempSendHandler = "" | Select-Object PowerShell, Runspace, Description
$tempSendHandler.PowerShell = $psSendingHandler
$tmpDate = Get-tempKey
$tempSendHandler.Description = "Поток psSendingHandler; Создан: $tmpDate"

$tempSendHandler.Runspace = $psSendingHandler.BeginInvoke()
$runspaces.Add($tempSendHandler) | Out-Null 

$tempKey = Get-tempKey; $queueLogHash[$tempKey] = @{ source = 'Create-Runspace';message = ("В пул добавлено: {0}" -f $tempSendHandler.Description) }
Write-Host ("В пул добавлено: {0}" -f $tempSendHandler.Description) -ForegroundColor DarkYellow -BackgroundColor Black
#------------------------------------------------------------------------------------------------------------------------------------------------------------------------

# Создаем экземпляр powershell для psInlineHandler, передаем блок сценариев и аргументы
# ------------------------------------------------------------------------------------------------------------------------------------------------------------------------
$inlineHandlerScript = Get-Command "$appPath\pbStart\pbScriptBlocks\InlineHandlerScriptBlock.ps1" | Select-Object -ExpandProperty ScriptBlock
$psInlineHandler = [powershell]::Create().AddScript($inlineHandlerScript).
    AddArgument($queueUsersHash).
    AddArgument($queueInlineHash).
    AddArgument($queueErrorHash).
    AddArgument($queueSendingHash).
    AddArgument($queueGroupsHash).
    AddArgument($queueCommandsHash).
    AddArgument($queueDebugHash).
    AddArgument($queueLogHash)
$psInlineHandler.runspacePool = $runspacePool

$tempInlineHandler = "" | Select-Object PowerShell, Runspace, Description
$tempInlineHandler.PowerShell = $psInlineHandler
$tmpDate = Get-tempKey
$tempInlineHandler.Description = "Поток psInlineHandler с ключом: $tmpDate"

$tempInlineHandler.Runspace = $psInlineHandler.BeginInvoke()
$runspaces.Add($tempInlineHandler) | Out-Null 

$tempKey = Get-tempKey; $queueLogHash[$tempKey] = @{ source = 'Create-Runspace';message = ("В пул добавлено: {0}" -f $tempInlineHandler.Description) }
Write-Host ("В пул добавлено: {0}" -f $tempInlineHandler.Description) -ForegroundColor DarkYellow -BackgroundColor Black
# ------------------------------------------------------------------------------------------------------------------------------------------------------------------------

# Создаем экземпляр powershell для psGetUpdate, передаем блок сценариев и аргументы
# ------------------------------------------------------------------------------------------------------------------------------------------------------------------------
$getUpdateScript = Get-Command "$appPath\pbStart\pbScriptBlocks\GetUpdateScriptBlock.ps1" | Select-Object -ExpandProperty ScriptBlock
$psGetUpdate = [powershell]::Create().AddScript($getUpdateScript).
    AddArgument($queueUsersHash).
    AddArgument($queueMessageHash).
    AddArgument($queueInlineHash).
    AddArgument($queueCallbackHash).
    AddArgument($queueErrorHash).
    AddArgument($queueSendingHash).
    AddArgument($queueCommandsHash).
    AddArgument($queueDebugHash).
    AddArgument($queueLogHash)
$psGetUpdate.runspacePool = $runspacePool

$tempGetUpdate = "" | Select-Object PowerShell, Runspace, Description
$tempGetUpdate.PowerShell = $psGetUpdate
$tmpDate = Get-tempKey
$tempGetUpdate.Description = "Поток psGetUpdate с ключом: $tmpDate"

$tempGetUpdate.Runspace = $psGetUpdate.BeginInvoke()
$runspaces.Add($tempGetUpdate) | Out-Null 

$tempKey = Get-tempKey; $queueLogHash[$tempKey] = @{ source = 'Create-Runspace';message = ("В пул добавлено: {0}" -f $tempGetUpdate.Description) }
Write-Host ("В пул добавлено рабочее пространство: {0}" -f $tempGetUpdate.Description) -ForegroundColor DarkYellow -BackgroundColor Black
# ------------------------------------------------------------------------------------------------------------------------------------------------------------------------

# Создаем экземпляр powershell для psCheckStaff, передаем блок сценариев и аргументы
# ------------------------------------------------------------------------------------------------------------------------------------------------------------------------
$checkStaffScript = Get-Command "$appPath\pbStart\pbScriptBlocks\CheckStaffScriptBlock.ps1" | Select-Object -ExpandProperty ScriptBlock
$psCheckStaff = [powershell]::Create().AddScript($checkStaffScript).
    AddArgument($settingsPath).
    AddArgument($queueGroupsHash).
    AddArgument($queueUsersHash).
    AddArgument($queueMessageHash).
    AddArgument($queueCommandsHash).
    AddArgument($queueSendingHash).
    AddArgument($queueErrorHash).
    AddArgument($queueDebugHash).
    AddArgument($queueLogHash)
$psCheckStaff.runspacePool = $runspacePool

$tempCheckStaff = "" | Select-Object PowerShell, Runspace, Description
$tempCheckStaff.PowerShell = $psCheckStaff
$tmpDate = Get-tempKey
$tempCheckStaff.Description = "Поток psCheckStaff с ключом: $tmpDate"

$tempCheckStaff.Runspace = $psCheckStaff.BeginInvoke()
$runspaces.Add($tempCheckStaff) | Out-Null 

$tempKey = Get-tempKey; $queueLogHash[$tempKey] = @{ source = 'Create-Runspace';message = ("В пул добавлено: {0}" -f $tempCheckStaff.Description) }
Write-Host ("В пул добавлено рабочее пространство: {0}" -f $tempCheckStaff.Description) -ForegroundColor DarkYellow -BackgroundColor Black
# ------------------------------------------------------------------------------------------------------------------------------------------------------------------------
<# Графическая форма, тестовая. В продакшене не используется  
# Создаем экземпляр powershell для формы управления, передаем блок сценариев и аргументы
# ------------------------------------------------------------------------------------------------------------------------------------------------------------------------
# $formScript = Get-Command "$appPath\pbStart\pbScriptBlocks\FormScriptBlock.ps1" | Select-Object -ExpandProperty ScriptBlock

# # Создаем отдельный STA Runspace для формы (важно для Windows Forms)
# $formRunspace = [RunspaceFactory]::CreateRunspace()
# $formRunspace.ApartmentState = "STA"
# $formRunspace.ThreadOptions = "ReuseThread"
# $formRunspace.Open()

# $psForm = [powershell]::Create().AddScript($formScript).
#     AddArgument($queueUsersHash).
#     AddArgument($queueMessageHash).
#     AddArgument($queueInlineHash).
#     AddArgument($queueCallbackHash).
#     AddArgument($queueErrorHash).
#     AddArgument($queueSendingHash).
#     AddArgument($queueCommandsHash).
#     AddArgument($queueDebugHash).
#     AddArgument($queueLogHash)
# $psForm.Runspace = $formRunspace

# $tempForm = "" | Select-Object PowerShell, Runspace, Description
# $tempForm.PowerShell = $psForm
# $tmpDate = Get-tempKey
# $tempForm.Description = "Поток формы управления с ключом: $tmpDate"

# $tempForm.Runspace = $psForm.BeginInvoke()
# $runspaces.Add($tempForm) | Out-Null 

# $tempKey = Get-tempKey; $queueLogHash[$tempKey] = @{ source = 'Create-Runspace';message = ("В пул добавлено рабочее пространство-форма: {0}" -f $tempForm.Description) }
# Write-Host ("В пул добавлено рабочее пространство-форма: {0}" -f $tempForm.Description) -ForegroundColor DarkYellow -BackgroundColor Black
# # ------------------------------------------------------------------------------------------------------------------------------------------------------------------------
#>

# Ожидаем команды остановки от пользователя
# ------------------------------------------------------------------------------------------------------------------------------------------------------------------------
Write-Host "Бот запущен" -ForegroundColor Green -BackgroundColor Black

$botRun = $botSettings.botRun
while ($botRun) {  

    # Сохраняем группы в файл
    # ---------------------------------------------------------------------------------------------------------------------
    [System.Threading.Monitor]::Enter($queueGroupsHash.SyncRoot)
    try { 
        $tmpGroupsHash = [System.Collections.SortedList] $queueGroupsHash
        if ($tmpGroupsHash.Count -gt 0) {
            $tmpGroupsHash | ConvertTo-Json -Depth 10 | Out-File "$appPath\pbAssets\queueGroupsHash.json"
        }
    }
    finally { [System.Threading.Monitor]::Exit($queueGroupsHash.SyncRoot) }

    # Сохраняем пользователей в файл
    # ---------------------------------------------------------------------------------------------------------------------

    [System.Threading.Monitor]::Enter($queueUsersHash.SyncRoot)
    try { 
        $tmpUsersHash = [System.Collections.SortedList] $queueUsersHash
        $tmpUsersHash | ConvertTo-Json -Depth 10 | Out-File "$appPath\pbAssets\queueUsersHash.json"
    }
    finally { [System.Threading.Monitor]::Exit($queueUsersHash.SyncRoot) }

    # Создаём каталог для логов если его нет
    # ---------------------------------------------------------------------------------------------------------------------

    $logDir = Split-Path $logFile -Parent
    if (!(Test-Path $logDir)) {
        New-Item -Path $logDir -ItemType Directory -Force | Out-Null
    }

    # Сохраняем отладочную информацию в файл
    # ---------------------------------------------------------------------------------------------------------------------

    [System.Threading.Monitor]::Enter($queueDebugHash.SyncRoot)
    try { 
        $tmpDebugHash = [System.Collections.SortedList] $queueDebugHash
        if ($tmpDebugHash.Count -gt 0) {
            $tmpDebugHash | ConvertTo-Json -Depth 10 | Out-File -Append "$appPath\pbLogs\queueDebugHash.json"
            $queueDebugHash.Clear()
        }
    }
    finally { [System.Threading.Monitor]::Exit($queueDebugHash.SyncRoot) }


    # Сохраняем логи в файл
    # ---------------------------------------------------------------------------------------------------------------------

    [System.Threading.Monitor]::Enter($queueLogHash.SyncRoot)
    try { 
        $tmpLogHash = [System.Collections.SortedList] $queueLogHash
        if ($tmpLogHash.Count -gt 0) {
            $tmpLogHash | ConvertTo-Json -Depth 10 | Out-File -Append "$appPath\pbLogs\queueLogHash.json"
            $queueLogHash.Clear()
        }
    }
    finally { [System.Threading.Monitor]::Exit($queueLogHash.SyncRoot) }

    # Сохраняем ошибки в файл
    # ---------------------------------------------------------------------------------------------------------------------

    [System.Threading.Monitor]::Enter($queueErrorHash.SyncRoot)
    try { 
        $tmpErrorHash = [System.Collections.SortedList] $queueErrorHash
        if ($tmpErrorHash.Count -gt 0) {
            $tmpErrorHash | ConvertTo-Json -Depth 10 | Out-File -Append "$appPath\pbLogs\queueErrorHash.json"
            $queueErrorHash.Clear()
        }
    }
    finally { [System.Threading.Monitor]::Exit($queueErrorHash.SyncRoot) }
    
    # Производим ротацию логов
    # ---------------------------------------------------------------------------------------------------------------------
    New-RotateLogFile -LogPath $logFile -MaxSizeMB $maxSizeMB -KeepFiles $keepFiles -Verbose
    New-RotateLogFile -LogPath $errorFile -MaxSizeMB $maxSizeMB -KeepFiles $keepFiles

    # Читаем переменную остановки бота
    # --------------------------------
    $botSettings = Get-Content -Path $settingsPath | ConvertFrom-Json
    $botRun = $botSettings.botRun

    # Проверяем, что бот не остановлен
    # --------------------------------
    if ($botRun -eq $false) {

        $queueCommandsHash['inlineNonStop'] = $false
        $queueCommandsHash['callbackNonStop'] = $false
        $queueCommandsHash['messageNonStop'] = $false
        $queueCommandsHash['updateNonStop'] = $false
        $queueCommandsHash['sendingNonStop'] = $false
        $queueCommandsHash['checkStaffNonStop'] = $false
        
        # Ожидаем завершения всех потоков
        # -----------------------------------------------
        Get-Runspaces -runspaces $runspaces -Wait -Verbose
        
        $tempKey = Get-tempKey; $queueLogHash[$tempKey] = @{ source = 'Create-Runspace';message = "Работа бота завершена." }
        Write-Host "Работа бота завершена." -ForegroundColor Green -BackgroundColor Black
        break
    }

    # Подтверждаем запуск один раз, не затрагивая остальные настройки.
    # Команда в общей таблице остаётся true, пока CheckStaff её не заберёт.
    if ($botSettings.checkStaffRun) {
        $pendingSettingsPath = "$settingsPath.$PID.pending"
        try {
            $botSettings.checkStaffRun = $false
            $botSettings | ConvertTo-Json -Depth 10 |
                Set-Content -LiteralPath $pendingSettingsPath -Encoding UTF8 -ErrorAction Stop
            [System.IO.File]::Replace($pendingSettingsPath, $settingsPath, $null)

            $queueCommandsHash['checkStaffRun'] = $true
            $tempKey = Get-tempKey
            $queueLogHash[$tempKey] = @{
                source = 'Create-Runspace'
                message = "Ночная проверка сотрудников поставлена в очередь."
            }
        }
        catch {
            $tempKey = Get-tempKey
            $queueErrorHash[$tempKey] = @{
                source = 'Create-Runspace'
                message = "Не удалось подтвердить сигнал проверки сотрудников: $($_.Exception.Message)"
            }
            if (Test-Path -LiteralPath $pendingSettingsPath) {
                Remove-Item -LiteralPath $pendingSettingsPath -Force -ErrorAction SilentlyContinue
            }
        }
    }

    Start-Sleep -Seconds 15

}


