<#
.SYNOPSIS
    Поток (runspace) обработки очереди Telegram Bot API запросов с корректным throttling (global/per-chat/per-group)
    и обработкой 429 retry_after. Совместим по параметрам с предыдущей реализацией.

.DESCRIPTION
    Скрипт предназначен для запуска внутри инфраструктуры бота, где несколько потоков/ранспейсов
    обрабатывают очереди (hashtable-очереди) взаимодействия с Telegram Bot API.

    Основная задача:
      1) Забрать из queueSendingHash один "лучший" элемент (который можно выполнить прямо сейчас),
      2) Применить строгие лимиты (rate limits) и backoff,
      3) Выполнить соответствующую команду к Telegram API через ваши модули,
      4) Успешные элементы удалить из очереди,
      5) Ошибки залогировать в queueErrorHash (в отдельных случаях оставить элемент в очереди для ретрая).

    Реализованные лимиты:
      - Global: 30 API-запросов/сек (token bucket)
      - Per-chat: 1 API-запрос/сек (token bucket) для действий, имеющих chat_id
      - Per-group: 20 API-запросов/мин (token bucket) только для типов чатов group/supergroup
        (тип чата определяется через Bot API method getChat и кешируется)

    Обработка ошибок:
      - 429 Too Many Requests: используется sendResult.parameters.retry_after.
        Скрипт ставит "заморозку" (retryAfterHash) для ключа (chat_id или GLOBAL) и не удаляет элемент из очереди.
      - Transient ошибки (exceptions/5xx): ограниченный ретрай с экспоненциальным backoff (до maxRetries).
        Для этого в объект элемента очереди добавляются служебные поля:
          _retry_count, _next_try_at
      - Прочие ошибки: логируются и элемент удаляется из очереди (чтобы не зациклиться навсегда).

    Важные допущения:
      - queueSendingHash — hashtable "ключ => messageData".
        messageData — объект/hashtable с полями: action_type и параметрами для конкретного вызова.
      - В реальной многопоточности обычный hashtable не thread-safe.
        Этот скрипт частично защищён снимком Keys, но при реальной конкуренции лучше использовать
        синхронизированный контейнер (или один handler на очередь).
      - Для определения типа чата вызывается Invoke-RestMethod к api.telegram.org. Если сеть закрыта,
        per-group лимит не применится (останутся global + per-chat).

.PARAMETER queueUsersHash
    Hashtable. Состояния пользователей. Скрипт может писать message_id/start_message_id и текущий экран.

.PARAMETER queueSendingHash
    Hashtable. Очередь задач на отправку/редактирование/удаление/и прочие действия Telegram API.
    Ключ — строка (идентификатор записи в очереди), значение — messageData.

.PARAMETER queueErrorHash
    Hashtable. Очередь ошибок. Скрипт пишет туда структурированные записи с message и originalMessage.

.PARAMETER queueCommandsHash
    Hashtable. Управляющие команды:
      - appPath: путь к корню приложения (для Import-Module ваших ps1-модулей)
      - botID: токен/идентификатор бота для Bot API URL
      - sendingRunspacesSleepTime: базовый sleep в мс
      - sendingNonStop: флаг работы цикла

.PARAMETER queueDebugHash
    Hashtable. Очередь отладки (в этой версии напрямую не используется, оставлена для совместимости).

.PARAMETER queueLogHash
    Hashtable. Очередь логов (информационные события работы handler'а).

.EXAMPLE
    # Внутри управляющего скрипта/ранспейса, где очереди уже созданы:
    & .\SendingHandler.ps1 -queueUsersHash $queueUsersHash -queueSendingHash $queueSendingHash `
                           -queueErrorHash $queueErrorHash -queueCommandsHash $queueCommandsHash `
                           -queueDebugHash $queueDebugHash -queueLogHash $queueLogHash

.NOTES
    Безопасность/надежность:
      - Скрипт не выполняет никакого "в фоне" и работает синхронно в рамках runspace.
      - В случае исключений логирует и либо ретраит (ограниченно), либо дропает элемент.

#>

Param (
    $queueUsersHash,
    $queueSendingHash,
    $queueErrorHash,
    $queueCommandsHash,
    $queueDebugHash,
    $queueLogHash
)

# -------------------- bootstrap / конфигурация --------------------
$appPath   = $queueCommandsHash.appPath
$botID     = $queueCommandsHash.botID
$sleepTime = $queueCommandsHash.sendingRunspacesSleepTime
if (-not $sleepTime -or $sleepTime -lt 1) { $sleepTime = 100 }

# -------------------- импорт модулей действий Telegram --------------------
try {
    # Модули отправки сообщений
    Import-Module "$appPath\pbModules\Messages\SendMessage.ps1"
    Import-Module "$appPath\pbModules\Messages\SendPhoto.ps1"
    Import-Module "$appPath\pbModules\Messages\SendVideo.ps1"
    Import-Module "$appPath\pbModules\Messages\SendDocument.ps1"
    Import-Module "$appPath\pbModules\Messages\SendAudio.ps1"
    # Import-Module "$appPath\pbModules\Messages\SendVoice.ps1"
    # Import-Module "$appPath\pbModules\Messages\SendMediaGroup.ps1"

    # Модули редактирования сообщений
    Import-Module "$appPath\pbModules\Messages\EditMessageText.ps1"
    Import-Module "$appPath\pbModules\Messages\EditMessageCaption.ps1"
    Import-Module "$appPath\pbModules\Messages\EditMessageMedia.ps1"
    Import-Module "$appPath\pbModules\Messages\EditMessageReplyMarkup.ps1"

    # Модули управления сообщениями
    Import-Module "$appPath\pbModules\Messages\DeleteMessage.ps1"

    # Модули callback и inline запросов
    Import-Module "$appPath\pbModules\Callback\AnswerCallbackQuery.ps1"
    Import-Module "$appPath\pbModules\Inlines\AnswerInlineQuery.ps1"

    # Модули управления чатами
    Import-Module "$appPath\pbModules\Chat\BanChatMember.ps1"
    Import-Module "$appPath\pbModules\Chat\UnbanChatmember.ps1"
    Import-Module "$appPath\pbModules\Chat\KickChatMember.ps1"
    Import-Module "$appPath\pbModules\Chat\PromoteChatMember.ps1"
    Import-Module "$appPath\pbModules\Chat\RevokeChatInviteLink.ps1"

    # Утилиты
    Import-Module "$appPath\pbModules\Utils\Utils.ps1"
}
catch {
    $tempKey = "$((Get-Date).ToString('yyyy-MM-ddTHH:mm:ss.fffffff'))"
    $queueErrorHash[$tempKey] = @{ source = 'sendingHandlerScript'; message = "Error import modules: $($_.Exception.Message)" }
    Write-Host "sendingHandlerScript Error import modules: $($_.Exception.Message)" -ForegroundColor Red -BackgroundColor Black
    $queueCommandsHash['sendingNonStop'] = $false
    return
}

# -------------------- helpers: safe logging --------------------

function Write-LogSafe {
<#
.SYNOPSIS
    Безопасная запись лога в queueLogHash и вывод в консоль.

.DESCRIPTION
    Пишет в queueLogHash структурированный лог (source/message) и параллельно в консоль.
    Все операции завернуты в try/catch, чтобы logging никогда не ломал поток отправки.

.PARAMETER msg
    Текст сообщения лога.

.PARAMETER color
    Цвет консольного вывода (ConsoleColor).

.EXAMPLE
    Write-LogSafe -msg "handler started" -color Green
#>
    param(
        [Parameter(Mandatory=$true)][string]$msg,
        [ConsoleColor]$color = [ConsoleColor]::Gray
    )
    try {
        $tempKey = Get-tempKey
        $queueLogHash[$tempKey] = @{ source = 'sendingHandlerScript'; message = $msg }
    } catch {}
    try {
        Write-Host $msg -ForegroundColor $color -BackgroundColor Black
    } catch {}
}

function Write-ErrSafe {
<#
.SYNOPSIS
    Безопасная запись ошибки в queueErrorHash и вывод в консоль.

.DESCRIPTION
    Пишет в queueErrorHash структурированную ошибку (source/message/originalMessage).
    Логирование не должно падать и останавливать обработку очереди.

.PARAMETER msg
    Текст ошибки.

.PARAMETER originalMessage
    Исходный объект/структура messageData, вызвавший ошибку (для диагностики).

.EXAMPLE
    Write-ErrSafe -msg "429 retry_after" -originalMessage $messageData
#>
    param(
        [Parameter(Mandatory=$true)][string]$msg,
        $originalMessage = $null
    )
    try {
        $tempKey = Get-tempKey
        $queueErrorHash[$tempKey] = @{
            source          = 'sendingHandlerScript'
            message         = $msg
            # originalMessage = $originalMessage  # Полный объект может содержать ПДн и приглашения.
        }
    } catch {}
    try {
        Write-Host $msg -ForegroundColor DarkRed -BackgroundColor Black
    } catch {}
}

# -------------------- Rate limiter: Token Bucket implementation --------------------
# bucket = @{ tokens=double; rate=double; cap=double; last=[datetime] }

function New-TokenBucket {
<#
.SYNOPSIS
    Создает структуру token bucket для rate limiting.

.DESCRIPTION
    Token bucket — классический алгоритм ограничения скорости:
      - tokens: текущее количество токенов
      - rate: скорость пополнения токенов (токенов в секунду)
      - cap: максимальная емкость токенов (burst)
      - last: время последнего refil'а

    Если tokens >= amount, то можно "потребить" amount токенов и выполнить операцию.

.PARAMETER ratePerSecond
    Скорость пополнения (tokens/sec).

.PARAMETER capacity
    Максимальная емкость (burst). Обычно равна ratePerSecond или больше.

.OUTPUTS
    Hashtable-структура bucket.

.EXAMPLE
    $b = New-TokenBucket -ratePerSecond 30 -capacity 30
#>
    param(
        [Parameter(Mandatory=$true)][double]$ratePerSecond,
        [Parameter(Mandatory=$true)][double]$capacity
    )
    return @{
        tokens = $capacity
        rate   = $ratePerSecond
        cap    = $capacity
        last   = (Get-Date)
    }
}

function Refill-TokenBucket {
<#
.SYNOPSIS
    Пополняет bucket токенами на основе прошедшего времени.

.DESCRIPTION
    Вычисляет dt с момента последнего refil'а и добавляет rate*dt токенов,
    ограничивая верхней границей cap. Обновляет bucket.last.

.PARAMETER bucket
    Hashtable bucket, созданный New-TokenBucket.

.EXAMPLE
    Refill-TokenBucket -bucket $bucket
#>
    param($bucket)
    $now = Get-Date
    $dt = ($now - $bucket.last).TotalSeconds
    if ($dt -le 0) { return }
    $bucket.tokens = [math]::Min($bucket.cap, ($bucket.tokens + ($bucket.rate * $dt)))
    $bucket.last = $now
}

function Consume-TokenBucket {
<#
.SYNOPSIS
    Пытается потребить токены из bucket.

.DESCRIPTION
    Делает refill и затем проверяет tokens >= amount.
    Если достаточно — вычитает amount и возвращает $true, иначе $false.

.PARAMETER bucket
    Bucket.

.PARAMETER amount
    Сколько токенов потребить (обычно 1).

.OUTPUTS
    Boolean.

.EXAMPLE
    if (Consume-TokenBucket -bucket $b -amount 1) { ... }
#>
    param($bucket, [double]$amount = 1.0)
    Refill-TokenBucket -bucket $bucket
    if ($bucket.tokens -ge $amount) {
        $bucket.tokens -= $amount
        return $true
    }
    return $false
}

function Get-WaitSecondsForToken {
<#
.SYNOPSIS
    Возвращает минимальное время ожидания (сек), чтобы появился token.

.DESCRIPTION
    Делает refill. Если токенов достаточно — 0.
    Иначе рассчитывает время (amount - tokens)/rate.

.PARAMETER bucket
    Bucket.

.PARAMETER amount
    Сколько токенов нужно (обычно 1).

.OUTPUTS
    Double seconds.

.EXAMPLE
    $wait = Get-WaitSecondsForToken -bucket $b -amount 1
#>
    param($bucket, [double]$amount = 1.0)
    Refill-TokenBucket -bucket $bucket
    if ($bucket.tokens -ge $amount) { return 0.0 }
    if ($bucket.rate -le 0) { return 1.0 }
    return (($amount - $bucket.tokens) / $bucket.rate)
}

# -------------------- Telegram chat type cache (getChat) --------------------
# Кэш нужен, чтобы применять 20/min только к group/supergroup

$script:chatTypeCache = @{}     # chatId -> @{ type='group'; ts=[datetime] }
$script:chatTypeTtlSec = 600    # TTL кэша типа чата

function Get-ChatTypeCached {
<#
.SYNOPSIS
    Возвращает тип чата (private/group/supergroup/channel) с кэшированием.

.DESCRIPTION
    Для корректного применения лимита 20 сообщений/мин в группах и супергруппах
    необходимо отличать group/supergroup от private.
    Скрипт вызывает Telegram Bot API method getChat и сохраняет result.type в кэш на TTL.

    Если сеть недоступна/ошибка запроса:
      - функция возвращает $null
      - per-group лимит не применится до тех пор, пока тип не будет определён

.PARAMETER chatId
    Идентификатор чата.

.OUTPUTS
    String типа чата или $null.

.EXAMPLE
    $type = Get-ChatTypeCached -chatId "-1001234567890"
#>
    param([string]$chatId)

    if (-not $chatId -or $chatId -eq "GLOBAL") { return $null }

    $now = Get-Date
    if ($script:chatTypeCache.ContainsKey($chatId)) {
        $entry = $script:chatTypeCache[$chatId]
        if ($entry -and $entry.ts -and (($now - $entry.ts).TotalSeconds -lt $script:chatTypeTtlSec)) {
            return $entry.type
        }
    }

    try {
        $uri  = "https://api.telegram.org/bot$botID/getChat?chat_id=$chatId"
        $resp = Invoke-RestMethod -Method Get -Uri $uri -TimeoutSec 10

        if ($resp -and $resp.ok -and $resp.result -and $resp.result.type) {
            $type = [string]$resp.result.type
            $script:chatTypeCache[$chatId] = @{ type = $type; ts = $now }
            return $type
        }
    } catch {
        # не фатально: просто не определили тип
    }

    return $null
}

# -------------------- Policy: ключи лимитирования и область действия --------------------

function Get-RateKey {
<#
.SYNOPSIS
    Вычисляет ключ лимитирования для элемента очереди.

.DESCRIPTION
    Если messageData содержит chat_id — ключ равен chat_id.
    Если chat_id отсутствует (например, inline query) — ключ = "GLOBAL".
    Это важно, чтобы операции без чата не ломали per-chat структуры.

.PARAMETER messageData
    Элемент очереди (hashtable/psobject), содержащий параметры действия.

.OUTPUTS
    String: chat_id или "GLOBAL".

.EXAMPLE
    $key = Get-RateKey -messageData $md
#>
    param($messageData)
    if ($null -ne $messageData.chat_id -and "$($messageData.chat_id)".Length -gt 0) { return "$($messageData.chat_id)" }
    return "GLOBAL"
}

function Is-ChatScopedAction {
<#
.SYNOPSIS
    Определяет, относится ли действие к конкретному чату (и нужно ли применять per-chat/per-group лимиты).

.DESCRIPTION
    Логика:
      - если у messageData есть chat_id => chat-scoped
      - если chat_id нет => обычно НЕ chat-scoped (например answer_inline_query)

    При необходимости можно расширять switch под ваши action_type.

.PARAMETER actionType
    Строковый тип действия.

.PARAMETER messageData
    Данные действия.

.OUTPUTS
    Boolean.

.EXAMPLE
    if (Is-ChatScopedAction -actionType $actionType -messageData $md) { ... }
#>
    param([string]$actionType, $messageData)

    if ($messageData -and $messageData.chat_id) { return $true }

    switch ($actionType) {
        "answer_inline_query" { return $false }
        default               { return $false }
    }
}

# -------------------- limiter instances --------------------

# Global: 30 req/sec, burst 30
$script:bucketGlobal = New-TokenBucket -ratePerSecond 30.0 -capacity 30.0

# Per-chat: 1 req/sec, burst 1 (создается по требованию)
$script:bucketPerChatSec = @{}   # chatId -> bucket

# Per-group: 20/min => 20/60 req/sec, burst 20 (создается по требованию)
$script:bucketPerGroupMin = @{}  # chatId -> bucket

# retry_after lock: key -> DateTime (key = chatId или GLOBAL)
$script:retryAfterHash = @{}

# Подавление спама логов о лимитах
$script:lastLimitLog = @{}
$script:limitLogCooldownSec = 5

function Ensure-ChatBuckets {
<#
.SYNOPSIS
    Создает per-chat и per-group bucket'ы для chatId при необходимости.

.DESCRIPTION
    Ленивая инициализация:
      - per-chat bucket: 1 req/sec
      - per-group bucket: 20 req/min

.PARAMETER chatId
    Идентификатор чата.

.EXAMPLE
    Ensure-ChatBuckets -chatId $rateKey
#>
    param([string]$chatId)

    if (-not $script:bucketPerChatSec.ContainsKey($chatId)) {
        $script:bucketPerChatSec[$chatId] = New-TokenBucket -ratePerSecond 1.0 -capacity 1.0
    }
    if (-not $script:bucketPerGroupMin.ContainsKey($chatId)) {
        $script:bucketPerGroupMin[$chatId] = New-TokenBucket -ratePerSecond (20.0/60.0) -capacity 20.0
    }
}

function LogLimitOnce {
<#
.SYNOPSIS
    Логирует сообщение о лимите не чаще, чем раз в limitLogCooldownSec для ключа.

.DESCRIPTION
    Чтобы не забить логи, используем "антиспам":
    если для ключа уже логировали недавно — пропускаем.

.PARAMETER key
    Ключ ("GLOBAL" или chatId)

.PARAMETER msg
    Сообщение для лога.

.EXAMPLE
    LogLimitOnce -key $rateKey -msg "Reached per-chat limit"
#>
    param([string]$key, [string]$msg)

    $now = Get-Date
    if ($script:lastLimitLog.ContainsKey($key)) {
        if ((($now - $script:lastLimitLog[$key]).TotalSeconds) -lt $script:limitLogCooldownSec) { return }
    }
    $script:lastLimitLog[$key] = $now
    Write-LogSafe -msg $msg -color Magenta
}

function Get-RetryKeyWaitMs {
<#
.SYNOPSIS
    Возвращает, сколько миллисекунд ждать из-за retry_after для ключа.

.DESCRIPTION
    Если key есть в retryAfterHash и время ещё не наступило — возвращаем разницу (ms).
    Если время наступило — удаляем запись и возвращаем 0.

.PARAMETER key
    "GLOBAL" или chatId.

.OUTPUTS
    Int ms.

.EXAMPLE
    $ms = Get-RetryKeyWaitMs -key $rateKey
#>
    param([string]$key)

    if (-not $script:retryAfterHash.ContainsKey($key)) { return 0 }
    $now = Get-Date
    $t = $script:retryAfterHash[$key]

    if ($now -ge $t) {
        $script:retryAfterHash.Remove($key) | Out-Null
        return 0
    }

    return [int][math]::Ceiling(($t - $now).TotalMilliseconds)
}

# -------------------- retry/backoff per item --------------------

$script:maxRetries = 3

function Get-ItemNextTryMs {
<#
.SYNOPSIS
    Возвращает, сколько миллисекунд ждать до следующей попытки конкретного элемента очереди.

.DESCRIPTION
    Если в messageData есть служебное поле _next_try_at, и оно в будущем,
    возвращаем разницу в миллисекундах. Иначе 0.

.PARAMETER messageData
    Элемент очереди.

.OUTPUTS
    Int ms.

.EXAMPLE
    $ms = Get-ItemNextTryMs -messageData $md
#>
    param($messageData)

    if ($messageData -and $messageData.ContainsKey("_next_try_at") -and $messageData._next_try_at) {
        $now = Get-Date
        $t = [datetime]$messageData._next_try_at
        if ($now -ge $t) { return 0 }
        return [int][math]::Ceiling(($t - $now).TotalMilliseconds)
    }
    return 0
}

function Set-ItemBackoff {
<#
.SYNOPSIS
    Ставит элементу очереди backoff (время следующей попытки) и увеличивает счетчик retry.

.DESCRIPTION
    Добавляет/обновляет служебные поля:
      - _retry_count (int)
      - _next_try_at (DateTime)

.PARAMETER messageData
    Элемент очереди.

.PARAMETER seconds
    Через сколько секунд пробовать снова.

.EXAMPLE
    Set-ItemBackoff -messageData $md -seconds 10
#>
    param($messageData, [int]$seconds)

    if (-not $messageData.ContainsKey("_retry_count")) { $messageData._retry_count = 0 }
    $messageData._retry_count = [int]$messageData._retry_count + 1
    $messageData._next_try_at = (Get-Date).AddSeconds($seconds)
}

function Is-TransientError {
<#
.SYNOPSIS
    Определяет, стоит ли считать ошибку временной (transient) и пытаться ретраить.

.DESCRIPTION
    Возвращает $true если:
      - было исключение (network/timeout и т.п.)
      - error_code в диапазоне 5xx

.PARAMETER sendResult
    Результат вызова Telegram-метода (ваш формат).

.PARAMETER ex
    Exception, если произошёл catch.

.OUTPUTS
    Boolean.

.EXAMPLE
    if (Is-TransientError -sendResult $sendResult) { ... }
#>
    param($sendResult, [Exception]$ex = $null)

    if ($ex) { return $true }

    if ($sendResult -and $sendResult.error_code) {
        $code = [int]$sendResult.error_code
        if ($code -ge 500 -and $code -le 599) { return $true }
    }
    return $false
}

# -------------------- start --------------------

Write-LogSafe -msg "Поток sendingHandler начинает работу..." -color Green

$sendingNonStop = $true
while ($sendingNonStop) {

    # управляющий флаг
    $sendingNonStop = $queueCommandsHash['sendingNonStop']
    if ($sendingNonStop -eq $false) {
        Write-LogSafe -msg "Поток sendingHandler завершает свою работу..." -color Blue
        break
    }

    # если очередь пуста — просто спим
    if (-not $queueSendingHash -or $queueSendingHash.Count -eq 0) {
        Start-Sleep -Milliseconds $sleepTime
        continue
    }

    # снимок ключей (минимальная защита от "Collection was modified")
    $keysSnapshot = @($queueSendingHash.Keys)
    if ($keysSnapshot.Count -eq 0) {
        Start-Sleep -Milliseconds $sleepTime
        continue
    }

    # ------------------------------------------------------------
    # Выбор "лучшего" элемента:
    #   Идея: среди очереди найти первый элемент, который можно выполнить сейчас.
    #   Если ни один не готов (из-за retry_after / backoff / лимитов), посчитать
    #   минимальный wait и уснуть до ближайшего "окна".
    # ------------------------------------------------------------
    $bestKey    = $null
    $bestWaitMs = $null

    foreach ($k in $keysSnapshot) {

        if (-not $queueSendingHash.ContainsKey($k)) { continue }
        $md = $queueSendingHash[$k]
        if (-not $md) { continue }

        # 1) Backoff конкретного элемента
        $itemWait = Get-ItemNextTryMs -messageData $md
        if ($itemWait -gt 0) {
            if ($null -eq $bestWaitMs -or $itemWait -lt $bestWaitMs) { $bestWaitMs = $itemWait }
            continue
        }

        $actionType = [string]$md.action_type
        $rateKey    = Get-RateKey -messageData $md

        # 2) retry_after заморозка по ключу
        $raWait = Get-RetryKeyWaitMs -key $rateKey
        if ($raWait -gt 0) {
            if ($null -eq $bestWaitMs -or $raWait -lt $bestWaitMs) { $bestWaitMs = $raWait }
            continue
        }

        # 3) глобальный bucket
        $gWaitSec = Get-WaitSecondsForToken -bucket $script:bucketGlobal -amount 1.0
        if ($gWaitSec -gt 0) {
            $gWaitMs = [int][math]::Ceiling($gWaitSec * 1000)
            if ($null -eq $bestWaitMs -or $gWaitMs -lt $bestWaitMs) { $bestWaitMs = $gWaitMs }
            continue
        }

        $chatScoped = Is-ChatScopedAction -actionType $actionType -messageData $md

        # 4) per-chat/per-group buckets только если это действие про чат
        if ($chatScoped -and $rateKey -ne "GLOBAL") {

            Ensure-ChatBuckets -chatId $rateKey

            # per-chat 1/sec
            $cWaitSec = Get-WaitSecondsForToken -bucket $script:bucketPerChatSec[$rateKey] -amount 1.0
            if ($cWaitSec -gt 0) {
                $cWaitMs = [int][math]::Ceiling($cWaitSec * 1000)
                if ($null -eq $bestWaitMs -or $cWaitMs -lt $bestWaitMs) { $bestWaitMs = $cWaitMs }
                continue
            }

            # per-group 20/min для group/supergroup
            $chatType = Get-ChatTypeCached -chatId $rateKey
            if ($chatType -eq "group" -or $chatType -eq "supergroup") {
                $mWaitSec = Get-WaitSecondsForToken -bucket $script:bucketPerGroupMin[$rateKey] -amount 1.0
                if ($mWaitSec -gt 0) {
                    $mWaitMs = [int][math]::Ceiling($mWaitSec * 1000)
                    if ($null -eq $bestWaitMs -or $mWaitMs -lt $bestWaitMs) { $bestWaitMs = $mWaitMs }
                    continue
                }
            }
        }

        # элемент готов к исполнению сейчас
        $bestKey = $k
        break
    }

    if (-not $bestKey) {
        # никто не готов — ждём ближайшее окно
        if (-not $bestWaitMs -or $bestWaitMs -lt $sleepTime) { $bestWaitMs = $sleepTime }
        Start-Sleep -Milliseconds $bestWaitMs
        continue
    }

    # ------------------------------------------------------------
    # Исполнение выбранного элемента
    # ------------------------------------------------------------
    if (-not $queueSendingHash.ContainsKey($bestKey)) {
        Start-Sleep -Milliseconds $sleepTime
        continue
    }

    $messageData = $queueSendingHash[$bestKey]
    if (-not $messageData) {
        $queueSendingHash.Remove($bestKey) | Out-Null
        Start-Sleep -Milliseconds $sleepTime
        continue
    }

    $actionType = [string]$messageData.action_type
    $rateKey    = Get-RateKey -messageData $messageData
    $chatScoped = Is-ChatScopedAction -actionType $actionType -messageData $messageData

    # ------------------------------------------------------------
    # Резервирование токенов (предварительное "снятие" лимитов).
    # Если не удалось потребить — чуть подождём и перейдём к следующей итерации.
    # ------------------------------------------------------------
    if (-not (Consume-TokenBucket -bucket $script:bucketGlobal -amount 1.0)) {
        LogLimitOnce -key "GLOBAL" -msg "Достигнут глобальный лимит. Ожидание..."
        Start-Sleep -Milliseconds ([math]::Max($sleepTime, 50))
        continue
    }

    if ($chatScoped -and $rateKey -ne "GLOBAL") {
        Ensure-ChatBuckets -chatId $rateKey

        if (-not (Consume-TokenBucket -bucket $script:bucketPerChatSec[$rateKey] -amount 1.0)) {
            LogLimitOnce -key $rateKey -msg "Достигнут per-chat лимит (1/sec) для $rateKey. Ожидание..."
            Start-Sleep -Milliseconds ([math]::Max($sleepTime, 50))
            continue
        }

        $chatType = Get-ChatTypeCached -chatId $rateKey
        if ($chatType -eq "group" -or $chatType -eq "supergroup") {
            if (-not (Consume-TokenBucket -bucket $script:bucketPerGroupMin[$rateKey] -amount 1.0)) {
                LogLimitOnce -key $rateKey -msg "Достигнут group лимит (20/min) для $rateKey. Ожидание..."
                Start-Sleep -Milliseconds ([math]::Max($sleepTime, 100))
                continue
            }
        }
    }

    try {
        $sendResult = $null

        # ------------------------------------------------------------
        # Выполнение action_type через ваши модули.
        # Важно: ожидается структура ответа с .ok, .error_code и optional .parameters.retry_after
        # ------------------------------------------------------------
        switch ($actionType) {

            # ОТПРАВКА СООБЩЕНИЙ
            "send_message" {
                $sendResult = Send-Message -botID $botID -chatID $messageData.chat_id -threadID $messageData.message_thread_id -text $messageData.text -replyMarkup $messageData.reply_markup

                $userID = "$($messageData.chat_id)"
                if ($sendResult.ok -and $messageData.start_message_id) {
                    $queueUsersHash["$userID"].start_message_id = $sendResult.result.message_id
                }
            }

            "send_photo" {
                $sendResult = Send-Photo -botID $botID -chatID $messageData.chat_id -photo $messageData.photo -protect $messageData.protect -caption $messageData.caption -spoiler $messageData.spoiler -withOutReply $messageData.withOutReply -disableNotification $messageData.disableNotification -replyID $messageData.replyID -replyMarkup $messageData.reply_markup

                if ($sendResult.ok -and $sendResult.result -and $sendResult.result.message_id -gt 0) {
                    $userID = "$($messageData.chat_id)"
                    $queueUsersHash.$userID.message_id = $sendResult.result.message_id
                    $queueUsersHash.$userID.current_scrin.last_command = "send_photo"
                    $queueUsersHash.$userID.current_scrin.last_scrin   = $messageData.who_call
                    $queueUsersHash.$userID.current_scrin.last_date    = Get-Date
                }
            }

            # РЕДАКТИРОВАНИЕ СООБЩЕНИЙ
            "edit_message_text" {
                $sendResult = Edit-MessageText -botID $botID -chatID $messageData.chat_id -messageID $messageData.message_id -text $messageData.text -replyMarkup $messageData.reply_markup
            }

            "edit_message_caption" {
                $sendResult = Edit-MessageCaption -botID $botID -chatID $messageData.chat_id -messageID $messageData.message_id -caption $messageData.caption -replyMarkup $messageData.reply_markup
                if ($sendResult.ok) {
                    $userID = "$($messageData.chat_id)"
                    $queueUsersHash.$userID.current_scrin.last_command = "edit_message_caption"
                    $queueUsersHash.$userID.current_scrin.last_scrin   = $messageData.who_call
                    $queueUsersHash.$userID.current_scrin.last_date    = Get-Date
                }
            }

            "edit_message_media" {
                $sendResult = Edit-MessageMedia -botID $botID -chatID $messageData.chat_id -messageID $messageData.message_id -dataUrl $messageData.dataUrl -caption $messageData.caption -replyMarkup $messageData.reply_markup
                if ($sendResult.ok) {
                    $userID = "$($messageData.chat_id)"
                    $queueUsersHash.$userID.current_scrin.last_command = "edit_message_media"
                    $queueUsersHash.$userID.current_scrin.last_scrin   = $messageData.who_call
                    $queueUsersHash.$userID.current_scrin.last_date    = Get-Date
                }
            }

            "edit_message_reply_markup" {
                $sendResult = Edit-MessageReplyMarkup -botID $botID -chatID $messageData.chat_id -messageID $messageData.message_id -replyMarkup $messageData.reply_markup
                if (-not $sendResult.ok) {
                    Write-ErrSafe -msg "Действие $actionType вызвало ошибку: $sendResult" -originalMessage $messageData
                }
            }

            # УДАЛЕНИЕ
            "delete_message" {
                $sendResult = Delete-Message -botID $botID -chatID $messageData.chat_id -messageID $messageData.message_id
            }

            # CALLBACK / INLINE
            "answer_callback_query" {
                $sendResult = New-AnswerCallbackQuery -botID $botID -callbackQueryID $messageData.callback_query_id -text $messageData.text -showAlert $messageData.show_alert -url $messageData.url -cacheTime $messageData.cache_time
            }

            "answer_inline_query" {
                $sendResult = New-AnswerInlineQuery -botID $botID -inlineQueryID $messageData.inline_query_id -results $messageData.results -cachTime $messageData.cache_time -isPersonal $messageData.is_personal -nextOffset $messageData.next_offset
            }

            # УПРАВЛЕНИЕ ЧАТАМИ
            "unban_chat_member" {
                $sendResult = New-UnbanChatMember -botID $botID -chatID $messageData.chat_id -userID $messageData.user_id
            }

            "kick_chat_member" {
                $sendResult = New-KickChatMember -botID $botID -chatID $messageData.chat_id -userID $messageData.user_id -untilDate $messageData.until_date
            }

            "promote_chat_member" {
                $sendResult = Promote-ChatMember -botID $botID -chatID $messageData.chat_id -userID $messageData.user_id `
                    -is_anonymous $messageData.is_anonymous -can_manage_chat $messageData.can_manage_chat -can_delete_messages $messageData.can_delete_messages `
                    -can_restrict_members $messageData.can_restrict_members -can_promote_members $messageData.can_promote_members -can_change_info $messageData.can_change_info `
                    -can_invite_users $messageData.can_invite_users -can_post_messages $messageData.can_post_messages -can_edit_messages $messageData.can_edit_messages `
                    -can_pin_messages $messageData.can_pin_messages
            }

            "get_chat_admins" {
                $sendResult = Get-ChatAdministrators -botID $botID -chatID $messageData.chat_id
            }

            "rework_chat_invite_link" {
                $sendResult = Revoke-ChatInviteLink -botID $botID -chatID $messageData.chat_id -inviteLink $messageData.invite_link
                if ($sendResult.result) {
                    $userID = $messageData.user_id
                    $queueUsersHash["$userID"].user_ststus.groups_state["$($messageData.chat_id)"].state = "InviteError"
                    $queueUsersHash["$userID"].user_ststus.groups_state["$($messageData.chat_id)"].invite_link = $null
                    $queueUsersHash["$userID"].user_ststus.groups_state["$($messageData.chat_id)"].check_send_date = Get-Date
                }
            }

            # УПРАВЛЕНИЕ ВЕРИФИКАЦИЕЙ
            "check_send_ability" {
                $sendResult = Check-SendAbility -gateID $messageData.get_id -phoneNumber $messageData.phone_number
            }

            default {
                $sendResult = @{ ok = $false; error_code = 400; description = "Unknown action_type: $actionType" }
            }
        }

        # ------------------------------------------------------------
        # Обработка результата выполнения
        # ------------------------------------------------------------
        if ($sendResult -and $sendResult.ok) {
            $queueSendingHash.Remove($bestKey) | Out-Null
            Write-LogSafe -msg "Успешно выполнено действие: $actionType key=$rateKey" -color Magenta
            Start-Sleep -Milliseconds $sleepTime
            continue
        }

        # 429 retry_after
        if ($sendResult -and $sendResult.error_code -eq 429) {
            $retryAfter = $sendResult.parameters.retry_after
            if (-not $retryAfter) { $retryAfter = 5 }

            $script:retryAfterHash[$rateKey] = (Get-Date).AddSeconds([int]$retryAfter)

            Write-ErrSafe -msg "429 Too Many Requests key=$rateKey. Retry after $retryAfter sec." -originalMessage $messageData
            Start-Sleep -Milliseconds ([math]::Max($sleepTime, 200))
            continue
        }

        # transient -> backoff + keep item
        if (Is-TransientError -sendResult $sendResult) {
            if (-not $messageData.ContainsKey("_retry_count")) { $messageData._retry_count = 0 }

            if ([int]$messageData._retry_count -lt $script:maxRetries) {
                $backoff = [int][math]::Min(30, [math]::Pow(2, [int]$messageData._retry_count + 1))
                Set-ItemBackoff -messageData $messageData -seconds $backoff
                Write-ErrSafe -msg "Transient error for $actionType key=$rateKey. Backoff ${backoff}s (try $($messageData._retry_count)/$script:maxRetries)." -originalMessage $messageData
                Start-Sleep -Milliseconds $sleepTime
                continue
            }
        }

        # прочие ошибки — логируем и удаляем, чтобы не зациклиться
        Write-ErrSafe -msg "Ошибка выполнения действия $actionType key=$rateKey : $($sendResult)" -originalMessage $messageData
        $queueSendingHash.Remove($bestKey) | Out-Null
        Start-Sleep -Milliseconds $sleepTime
    }
    catch {
        # exception — retry/backoff ограниченно
        $ex = $_.Exception
        if (-not $messageData.ContainsKey("_retry_count")) { $messageData._retry_count = 0 }

        if ([int]$messageData._retry_count -lt $script:maxRetries) {
            $backoff = [int][math]::Min(30, [math]::Pow(2, [int]$messageData._retry_count + 1))
            Set-ItemBackoff -messageData $messageData -seconds $backoff
            Write-ErrSafe -msg "Exception in $actionType key=$rateKey : $($ex.Message). Backoff ${backoff}s (try $($messageData._retry_count)/$script:maxRetries)." -originalMessage $messageData
            Start-Sleep -Milliseconds $sleepTime
            continue
        }

        Write-ErrSafe -msg "Fatal exception in $actionType key=$rateKey : $($ex.Message). Drop item." -originalMessage $messageData
        if ($queueSendingHash.ContainsKey($bestKey)) { $queueSendingHash.Remove($bestKey) | Out-Null }
        Start-Sleep -Milliseconds $sleepTime
    }
}
