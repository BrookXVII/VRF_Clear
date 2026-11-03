<#
.SYNOPSIS
    Фоновая проверка актуальности статуса сотрудников и удаление их из Telegram-групп.

.DESCRIPTION
    Скрипт реализует поток CheckStaffScriptBlock, который:
      - периодически итерирует коллекцию пользователей ($queueUsersHash);
      - для каждого пользователя со статусом сотрудника и номером телефона вызывает функцию New-CheckStaff;
      - при обнаружении уволенного сотрудника пытается удалить его из всех Telegram-групп, в которых он состоит,
        с помощью функции New-KickChatMember;
      - записывает результаты и ошибки в соответствующие очереди логов и ошибок.

    Настройки работы потока считываются из хэш-таблицы $queueCommandsHash:
      - appPath                — путь к каталогу приложения (для загрузки модулей);
      - botID                  — идентификатор Telegram-бота;
      - checkStaffSleepTime    — задержка между циклами проверки в миллисекундах;
      - checkStaffNonStop      — флаг продолжения/остановки работы потока;
      - debugStop              — флаг управления отладочным выводом (используется внешней логикой).

    Поток работает в бесконечном цикле, пока $queueCommandsHash['checkStaffNonStop'] = $true.
    При возникновении ошибок загрузки модулей или логики проверки информация о них помещается в очередь ошибок.

.PARAMETER queueUsersHash
    Потокобезопасная коллекция с данными пользователей Telegram:
    идентификатор пользователя, ФИО, номер телефона, признак сотрудника, состояние по группам,
    текущий экран и дополнительная служебная информация.

.PARAMETER queueMessageHash
    Хэш-таблица очереди входящих сообщений бота. В данном скрипте напрямую не используется,
    но передаётся для унификации интерфейса между потоками.

.PARAMETER queueInlineHash
    Хэш-таблица очереди inline-запросов бота. В данном скрипте не используется.

.PARAMETER queueCallbackHash
    Хэш-таблица очереди callback-запросов бота. В данном скрипте не используется.

.PARAMETER queueErrorHash
    Хэш-таблица очереди ошибок. Скрипт пишет сюда сведения об ошибках:
    - при импорте модулей;
    - при неуспешном удалении пользователя из группы;
    - при других исключениях, обрабатываемых внешними функциями.

.PARAMETER queueSendingHash
    Хэш-таблица очереди исходящих сообщений бота. Используется функцией New-CheckStaff
    (и/или другими модулями) для постановки служебных уведомлений в очередь на отправку.

.PARAMETER queueCommandsHash
    Хэш-таблица с управляющими настройками и флагами работы потоков бота.
    Для данного скрипта используются, как минимум:
      - appPath
      - botID
      - checkStaffSleepTime
      - checkStaffNonStop
      - debugStop

.PARAMETER queueDebugHash
    Хэш-таблица очереди отладочной информации. Может использоваться для детальной диагностики
    внешней логикой, в данном скрипте непосредственно не заполняется.

.PARAMETER queueLogHash
    Хэш-таблица очереди логов работы бота. Скрипт записывает сюда:
      - факт запуска потока CheckStaffScriptBlock;
      - факт завершения потока при остановке;
      - успешное удаление пользователей из групп и другую служебную информацию.

.EXAMPLE
    Пример запуска в отдельном потоке (runspace) из основного скрипта бота:

    Поток будет работать до тех пор, пока в $queueCommandsHash['checkStaffNonStop'] не будет установлено $false.

.NOTES
    - Скрипт требует предварительной инициализации всех передаваемых хэш-таблиц.
    - Должны быть доступны и корректно расположены модули:
        pbModules\Messages\SendMessage.ps1
        pbModules\Chat\KickChatMember.ps1
        pbModules\Utils\Utils.ps1
      относительно пути appPath.
    - Для исключения гонок при чтении $queueUsersHash используется блокировка через
      [System.Threading.Monitor]::Enter/Exit и временная копия коллекции.

.LINK
    Telegram Bot API — удаление пользователя из чата/группы:
    https://core.telegram.org/bots/api#kickchatmember
#>

Param (
    $settingsPath,
    $queueGroupsHash,
    $queueUsersHash,
    $queueMessageHash,
    $queueCommandsHash,
    $queueSendingHash,
    $queueErrorHash,
    $queueDebugHash,
    $queueLogHash
)
    
# Читаем настройки из таблицы
# ---------------------------
$appPath = $queueCommandsHash.appPath
$botID = $queueCommandsHash.botID
$sleepTime = $queueCommandsHash.checkStaffSleepTimeSec

$alertChatID = $queueCommandsHash.alertGroup
$alertUsersOut = $queueCommandsHash.alertThreadUsersOut
$alertSystemError = $queueCommandsHash.alertThreadSystemError


# Импортируем необходимые модули
# -------------------------------
try {
    Import-Module "$appPath\pbModules\Chat\KickChatMember.ps1"
    Import-Module "$appPath\pbModules\Chat\RevokeChatInviteLink.ps1"
    Import-Module "$appPath\pbModules\Interface\BuildteButton.ps1"
    Import-Module "$appPath\pbModules\Interface\BuildteKeyboard.ps1"
    Import-Module "$appPath\pbModules\Utils\Utils.ps1"

}
catch {
    $tempKey = "$((Get-Date).Day).$((Get-Date).Month).$((Get-Date).Year).$((Get-Date).TimeOfDay)" 
    $queueErrorHash[$tempKey] = @{ source = 'CheckStaffScriptBlock'; message = "Error import modules: " + $_.Exception.Message }
    $queueCommandsHash['checkStaffNonStop'] = $false
}

# Считываем из массива настроек состояние отладки. Если установлено в false, то записываем событие в массив отладки. 
# ------------------------------------------------------------------------------------------------------------------
$debugStop = $queueCommandsHash['debugStop']

# Логируем начало работы потока/
# -----------------------------
$tempKey = Get-tempKey; $queueLogHash[$tempKey] = @{ source = 'CheckStaffScriptBlock';message = 'Поток CheckStaff начинает работу...' }
Write-Host "Поток CheckStaff начинает работу..." -ForegroundColor Green -BackgroundColor Gray

# Задаем начальные значения для переменных. $checkStaffNonStop в цикле считывает свое состояние из массива комманд.
# -------------------------------------------------------------------------------------------------------------
$checkStaffNonStop = $true

# Запускаем цикл. Условием остановки является занчение $queueCommandsHash['checkStaffNonStop'] = false.
# -----------------------------------------------------------------------------------------
while ($checkStaffNonStop) {
    
    # Считываем значения из массива комманд.
    # --------------------------------------
    $debugStop = $queueCommandsHash['debugStop']
    $checkStaffNonStop = $queueCommandsHash['checkStaffNonStop']

    # Если дана команда остановки, то завершаем поток.
    # ------------------------------------------------
    if ($checkStaffNonStop -eq $false) { 
        $tempKey =  Get-tempKey; $queueLogHash[$tempKey] = @{ source = 'CheckStaffScriptBlock';message = 'Поток CheckStaff завершает свою работу...' }
        Write-Host "Поток CheckStaff завершает свою работу..." -ForegroundColor Blue -BackgroundColor Black
        break 
    }

    # Проверяем переменную запуска проверки, если true, то выполняем процедуру.
    # Сигнал однократный: забираем его у диспетчера, чтобы не запускать
    # повторную проверку до окончания текущего прохода.
    if ($queueCommandsHash['checkStaffRun']) {
        $queueCommandsHash['checkStaffRun'] = $false

        # Копируем список ключей под блокировкой; сами статусы берём из общей базы.
        [System.Threading.Monitor]::Enter($queueUsersHash.SyncRoot)
        try {
            $tmpUsersHash = [System.Collections.SortedList] $queueUsersHash
        }
        finally {
            [System.Threading.Monitor]::Exit($queueUsersHash.SyncRoot)
        }

        foreach ($userkey in @($tmpUsersHash.Keys)) {
            $user = $queueUsersHash["$userkey"]
            if (-not $user) { continue }

            # Незавершённое удаление перепроверяем, даже если is_staff уже false.
            $isStaff = [bool]$user.is_staff
            $cleanupPending = [bool]$user.staffCleanupPending
            if (-not ($isStaff -or $cleanupPending)) { continue }

            $phone = ("$($user.phone_number)").Replace("+", "")
            if (-not $phone) {
                $tempKey = Get-tempKey
                $queueErrorHash[$tempKey] = @{
                    source = 'CheckStaffScriptBlock'
                    message = "Нет номера для повторной проверки пользователя $userkey."
                }
                continue
            }

            $checkStaffSplat = @{
                phone            = $phone
                userID           = "$userkey"
                queueCommandsHash = $queueCommandsHash
                queueUsersHash   = $queueUsersHash
                queueSendingHash = $queueSendingHash
                queueLogHash     = $queueLogHash
                queueErrorHash   = $queueErrorHash
                deferRevocation = $true
            }

            $isStaffChecked = New-CheckStaff @checkStaffSplat

            # Ошибка API НЕ равна увольнению: сохраняем состояние и повторим позднее.
            if ($isStaffChecked -eq 'ERROR') {
                $tempKey = Get-tempKey
                $queueErrorHash[$tempKey] = @{
                    source = 'CheckStaffScriptBlock'
                    message = "Кадровый API недоступен при проверке пользователя $userkey. Статус сохранён."
                }
                continue
            }

            if ($isStaffChecked -eq $true) {
                # При повторном трудоустройстве сбрасываем маркеры старой
                # процедуры отзыва, чтобы следующее увольнение проверялось заново.
                $user.staffCleanupPending = $false
                if ($user.user_ststus.groups_state) {
                    foreach ($groupKey in @($user.user_ststus.groups_state.Keys)) {
                        $groupState = $user.user_ststus.groups_state["$groupKey"]
                        if ($groupState) {
                            $groupState.Remove('staffCleanupKickDone')
                            $groupState.Remove('staffCleanupRevokeDone')
                        }
                    }
                }
                continue
            }

            if ($isStaffChecked -ne $false) {
                $tempKey = Get-tempKey
                $queueErrorHash[$tempKey] = @{
                    source = 'CheckStaffScriptBlock'
                    message = "Неожиданный результат кадрового API для пользователя $userkey."
                }
                continue
            }

            # Сотрудник отсутствует в актуальном кадровом источнике.
            # Признак сохраняется в JSON и обеспечивает повторную попытку
            # при следующей ночной проверке, пока остались незавершённые группы.
            $user.staffCleanupPending = $true
            $groups = $user.user_ststus.groups_state

            if ($groups) {
                # Снимок ключей, чтобы удаление успешно обработанной группы
                # не изменило коллекцию во время foreach.
                foreach ($groupKey in @($groups.Keys)) {
                    $groupState = $groups["$groupKey"]
                    $groupName = "$groupKey"
                    if ($queueGroupsHash.ContainsKey("$groupKey")) {
                        $groupName = [string]$queueGroupsHash["$groupKey"].title
                    }

                    # Сохраняем успех каждого действия для безопасной повторной попытки.
                    $kickOk = [bool]$groupState.staffCleanupKickDone
                    $revokeOk = [bool]$groupState.staffCleanupRevokeDone

                    try {
                        if (-not $kickOk) {
                            $kickResult = New-KickChatMember -botID $botID -chatID $groupKey -userID $userkey
                            $kickOk = [bool]($kickResult -and $kickResult.ok)
                            if ($kickOk) { $groupState.staffCleanupKickDone = $true }
                        }

                        $inviteLink = [string]$groupState.invite_link
                        if (-not $revokeOk) {
                            # Использованная одноразовая ссылка больше не допускает вступления.
                            $revokeOk = [string]::IsNullOrWhiteSpace($inviteLink) -or ([bool]$groupState.activate)
                            if (-not $revokeOk) {
                                $revokeResult = Revoke-ChatInviteLink -botID $botID -chatID $groupKey -inviteLink $inviteLink
                                $revokeOk = [bool]($revokeResult -and $revokeResult.ok)
                            }
                            if ($revokeOk) { $groupState.staffCleanupRevokeDone = $true }
                        }

                        if ($kickOk -and $revokeOk) {
                            # Очищаем только ту группу, по которой Telegram
                            # подтвердил выполнение всех необходимых операций.
                            $groups.Remove("$groupKey")
                            $messageText = "При регулярной проверке пользователь <code>$userkey</code> исключён из группы <code>$groupName</code>. Доступ отозван."
                            $alertThread = $alertUsersOut
                        }
                        else {
                            $messageText = "Не удалось полностью отозвать доступ пользователя <code>$userkey</code> в группе <code>$groupName</code>. Исключение: $kickOk; отзыв ссылки: $revokeOk. Состояние сохранено для повторной проверки."
                            $alertThread = $alertSystemError
                            $tempKey = Get-tempKey
                            $queueErrorHash[$tempKey] = @{
                                source = 'CheckStaffScriptBlock'
                                message = "Отзыв доступа: user=$userkey, group=$groupKey, kick=$kickOk, revoke=$revokeOk."
                            }
                        }
                    }
                    catch {
                        $alertThread = $alertSystemError
                        $messageText = "Ошибка отзыва доступа пользователя <code>$userkey</code> в группе <code>$groupName</code>. Состояние сохранено для повторной проверки."
                        $tempKey = Get-tempKey
                        $queueErrorHash[$tempKey] = @{
                            source = 'CheckStaffScriptBlock'
                            message = "Ошибка обработки группы $groupKey для пользователя $userkey: $($_.Exception.Message)"
                        }
                    }

                    $tempKey = Get-tempKey
                    $queueSendingHash[$tempKey] = @{
                        action_type       = 'send_message'
                        chat_id           = $alertChatID
                        message_thread_id = $alertThread
                        text              = $messageText
                        reply_markup      = $null
                        start_message_id  = $false
                    }

                    Start-Sleep -Milliseconds 500
                }
            }

            $remainingGroups = 0
            if ($groups) { $remainingGroups = $groups.Count }

            if ($remainingGroups -gt 0) {
                # При частичном отказе НЕ стираем оставшиеся группы.
                $user.staffCleanupPending = $true
                continue
            }

            # Все известные группы обработаны; завершаем отзыв доступа.
            $user.staffCleanupPending = $false
            $user.is_staff = $false

            $messageID = $user.message_id
            if ($messageID) {
                $feed = '&#10;'
                $doubleFeed = "$feed$feed"
                $captionText = "💠  <strong>Бот верификации</strong>$doubleFeed" +
                    "<strong>❗ Сотрудник с указанным номером не найден.</strong>$doubleFeed" +
                    "Если это ошибка, обратитесь в службу ИТ поддержки и повторите проверку."

                $eulaButton = Build-teButton -picture "💡" -text "Условия использования" -url $queueCommandsHash.eulaUrl
                $replyMarkupEULA = Build-teKeyboard -buttons @(@($eulaButton))

                $tempKey = Get-tempKey
                $queueSendingHash[$tempKey] = @{
                    action_type  = 'edit_message_caption'
                    chat_id      = "$userkey"
                    message_id   = $messageID
                    caption      = $captionText
                    reply_markup = $replyMarkupEULA
                }
            }
        }
    }

    # Сигнал проверки уже подтверждён диспетчером в BotSettings.json.

    # Добавляем задержку перед следующей проверкой
    # -----------------------------------------------------------------
    # Start-Sleep -Seconds 30
    Start-Sleep -Seconds $sleepTime
    
}
