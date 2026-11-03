# ------------------------------------------------------------------------------------------------------------------------------------------------------------------------
function Get-Tempkey {
    return "$((Get-Date).Day).$((Get-Date).Month).$((Get-Date).Year).$((Get-Date).TimeOfDay)"    
}
#-------------------------------------------------------------------------------------------------------------------------------------------------------------------
function ConvertTo-Hashtable {
    <#
    .SYNOPSIS
        Рекурсивно преобразует PSCustomObject и другие типы данных в синхронизированную хэш-таблицу.
    
    .DESCRIPTION
        Функция преобразует PSCustomObject в хэш-таблицу, рекурсивно обрабатывая вложенные объекты и массивы.
        Особенно полезна для работы с JSON данными в PowerShell 5.1, где отсутствует параметр -AsHashtable.
    
    .PARAMETER InputObject
        Входной объект для преобразования. Может быть PSCustomObject, массивом или любым другим типом.
    
    .EXAMPLE
        $jsonData = '{"name": "John", "age": 30, "address": {"city": "Moscow", "street": "Lenina"}}' | ConvertFrom-Json
        $hashtable = ConvertTo-Hashtable -InputObject $jsonData
    
    .OUTPUTS
        [hashtable] или исходный тип данных для примитивных значений.
    #>
    
    param (
        [Parameter(ValueFromPipeline)]
        $InputObject
    )
    
    process {
        # Обработка null значения
        if ($null -eq $InputObject) { 
            return $null 
        }
        
        # Обработка PSCustomObject - рекурсивное преобразование в хэш-таблицу
        if ($InputObject -is [PSCustomObject]) {
            # Создаем синхронизированную хэш-таблицу для потокобезопасности
            $hash = [hashtable]::Synchronized(@{})
            
            # Перебираем все свойства объекта
            $InputObject.PSObject.Properties | ForEach-Object {
                # Рекурсивно преобразуем каждое значение свойства
                $hash[$_.Name] = ConvertTo-Hashtable -InputObject $_.Value
            }
            return $hash
        }
        # Обработка коллекций (массивов, списков), исключая строки
        elseif ($InputObject -is [System.Collections.IEnumerable] -and $InputObject -isnot [string]) {
            $collection = @()
            
            # Рекурсивно преобразуем каждый элемент коллекции
            foreach ($item in $InputObject) {
                $collection += (ConvertTo-Hashtable -InputObject $item)
            }
            return $collection
        }
        # Возврат примитивных значений без изменений
        else {
            return $InputObject
        }
    }
}

#-------------------------------------------------------------------------------------------------------------------------------------------------------------------

<#
.SYNOPSIS
    Проверяет, является ли указанный номер телефона сотрудником организации.

.DESCRIPTION
    Функция отправляет запрос к внешнему API проверки сотрудников.
    Если по номеру телефона найден сотрудник, возвращает $true.
    Если сотрудник не найден или произошла ошибка – возвращает $false.
    В логах и сообщениях не используется номер телефона – только имя (fio).
    Если ФИО отсутствует в ответе, используется слово "пользователь".

.PARAMETER phone
    Номер телефона для проверки.

.PARAMETER queueCommandsHash
    Хэш-таблица с управляющими параметрами.

.PARAMETER queueSendingHash
    Хэш-таблица для постановки сообщений в очередь отправки.

.PARAMETER queueLogHash
    Хэш-таблица для логирования успешных действий.

.PARAMETER queueErrorHash
    Хэш-таблица для логирования ошибок.

.EXAMPLE
    New-CheckStaff -phone "79181234567" -queueCommandsHash $queueCommands

    Выполнит проверку номера через API и вернет $true или $false.

.OUTPUTS
    Boolean. $true если сотрудник найден, $false если нет или при ошибке.

.NOTES
    Требует, чтобы в $queueCommandsHash.apiUrl был указан URL сервиса.
    Также должны быть заданы alertSystemError и alertPhoneNotFound.
#>
function New-CheckStaff {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$phone, 

        [Parameter(Mandatory = $true)]
        [string]$userID,                 

        [Parameter(Mandatory = $false)]
        $queueCommandsHash,  

        [Parameter(Mandatory = $false)]
        $queueUsersHash,        

        [Parameter(Mandatory = $false)]
        $queueSendingHash,        
        
        [Parameter(Mandatory = $false)]
        $queueLogHash,          
        
        [Parameter(Mandatory = $false)]
        $queueErrorHash,

        [Parameter(Mandatory = $false)]
        [bool]$deferRevocation = $false
    )

    # Подготовка
    $apiUrl             = $queueCommandsHash.apiUrl
    $alertChatID        = $queueCommandsHash.alertGroup
    $alertSystemError   = $queueCommandsHash.alertThreadSystemError
    $token              = $queueCommandsHash.checkToken

    $userName = $queueUsersHash.$userID.username

    $feed = '&#10;' # Перенос строки HTML
    $doubleFeed = "$feed$feed"
    $tempKey = $null

    try {
        if (-not $apiUrl) {
            throw "API URL не задан в queueCommandsHash.apiUrl"
        }

        # Формируем тело запроса
        $body = @{ 
            id_api_query = "rabotayushchie_sotrudniki"
            token = $token
            param = @{
                number = $phone
            }
        
        } | ConvertTo-Json -Depth 5 -Compress

        # Write-Verbose "CheckStaff body= $body" 

        $credAPI = Get-Secret -Vault domainPdb apiquery -AsPlainText
        $credsBase64 = "apiquery:$credAPI"
        $credsBase64 = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($credsBase64))

        $currentUri = $null; $currentUri = $apiUrl + $body
        # Write-Verbose "CheckStaff currentUri= $currentUri" 

        # Отправляем запрос
        $response = Invoke-RestMethod -Method Get -Headers @{"Authorization"="Basic $credsBase64"} -Uri $currentUri
        # Write-Verbose "CheckStaff response: $(($response | ConvertTo-Json))" 
        # Write-Verbose "CheckStaff response: $($response[0])" 

        # if ($response -and $response.fio -and $response.guid) {
        if ($response -and $response.fio) {
            # Получаем имя сотрудника
            $fio = $response.fio
            # Логируем успех
            if ($queueLogHash) { $tempKey = Get-tempKey; $queueLogHash[$tempKey] = @{ source  = 'CheckStaff'; message = "Сотрудник найден: $fio" } 
                Write-Verbose "CheckStaff Сотрудник найден: $fio"
            }
            # Записываем состояние и guid пользователя в базу 
            $queueUsersHash["$userID"].is_staff = $true
            $queueUsersHash["$userID"].guid = $response[0].guid
            return $true
        }
        else {
            $fio = if ($response.fio) { $response.fio } else { $userName }
            # Логируем отсутствие сотрудника
            if ($queueLogHash) { $tempKey = Get-tempKey; $queueLogHash[$tempKey] = @{ source  = 'CheckStaff'; message = "Сотрудник НЕ найден: $fio" } 
            Write-Verbose "CheckStaff Сотрудник НЕ найден: $fio"
            }

            # Записываем состояние в базу 
            if (-not $deferRevocation) { $queueUsersHash["$userID"].is_staff = $false }
            return $false
        }
    }
    catch {

        $fio = $userName
        # Логируем ошибку
        if ($queueErrorHash) { $tempKey = Get-tempKey; $queueLogHash[$tempKey] = @{ source  = 'CheckStaff'; message = "Ошибка при проверке сотрудника: $($_.Exception.Message)" } }
        # При технической ошибке сохраняем последний подтверждённый статус.
        # Отправляем алерт в alertSystemError
        if ($queueSendingHash -and $alertChatID -and $alertSystemError) {

            $messageText = "⛔ <strong>Ошибка CheckStaff</strong>$doubleFeed" +
                           "<strong>Имя:</strong> $fio$feed" +
                           "<strong>Ошибка:</strong> $($_.Exception.Message)$doubleFeed" +
                           "🧐 <i><strong>-Там только Invoke-RestMethod мог сбойнуть.</strong></i>"

            $tempKey = Get-tempKey
            $queueSendingHash[$tempKey] = @{
                action_type       = 'send_message'
                chat_id           = $alertChatID
                message_thread_id = $alertSystemError
                text              = $messageText
                reply_markup      = $null
                start_message_id  = $false; 
            }
        }

        return "ERROR"
    }
}

#-------------------------------------------------------------------------------------------------------------------------------------------------------------------

<#
.SYNOPSIS
    Ротация лог-файла по размеру с ограничением числа архивов.

.DESCRIPTION
    Если текущий лог превышает MaxSizeMB (строго больше), он архивируется
    в файл вида "<имя_лога>.<yyyyMMdd-HHmmss>.log". Хранится не более KeepFiles архивов.
    Если лога нет — создается пустой файл.

.PARAMETER LogPath
    Полный путь к текущему лог-файлу.

.PARAMETER MaxSizeMB
    Порог (МБ). Ротация выполняется только если размер > MaxSizeMB.

.PARAMETER KeepFiles
    Максимальное количество архивов, которые следует хранить (0 — удалять все).
#>
function New-RotateLogFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$LogPath,

        [Parameter()]
        $MaxSizeMB = 10,

        [Parameter()]
        $KeepFiles = 5
    )

    # 1) Нет файла — выходим
    if (-not (Test-Path -LiteralPath $LogPath -PathType Leaf)) { return }

    # 2) Проверка размера
    $sizeBytes  = (Get-Item -LiteralPath $LogPath).Length
    $threshold  = [int64]$MaxSizeMB * 1Mb
    if ($sizeBytes -le $threshold) { return }

    # 3) Архивное имя: "<полный_путь_к_логу>.<yyyyMMdd-HHmmss>"
    $timestamp    = Get-Date -Format 'yyyyMMdd-HHmmss'
    $archivePath  = "$LogPath.$timestamp.log"

    # 4) Перенос содержимого в архив и очистка исходного файла
    try {
        Copy-Item -LiteralPath $LogPath -Destination $archivePath -Force -ErrorAction Stop
        
        # Очистка исходного лога (оставляем существующий файл, но пустой)
        Clear-Content -LiteralPath $LogPath -ErrorAction Stop
    }
    catch {
        throw "Ротация не выполнена для '$LogPath': $($_.Exception.Message)"
    }

    # 5) Поддержание не более KeepFiles архивов
    $dir     = Split-Path -Path $LogPath -Parent
    $leaf    = Split-Path -Path $LogPath -Leaf
    $archives = Get-ChildItem -LiteralPath $dir -File -Filter "$leaf.*" |
                Sort-Object LastWriteTime -Descending

    if ($archives.Count -gt $KeepFiles) {
        $toRemove = $archives | Select-Object -Skip $KeepFiles
        foreach ($f in $toRemove) {
            try { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop } catch { }
        }
    }
}




