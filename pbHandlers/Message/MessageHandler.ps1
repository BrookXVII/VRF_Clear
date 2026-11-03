<#
.SYNOPSIS
    Обрабатывает входящие сообщения Telegram бота различных типов.

.DESCRIPTION
    Функция обрабатывает различные типы входящих сообщений от пользователей Telegram.
    Поддерживает текстовые команды (например, /start). Для каждой команды выполняет 
    соответствующую логику обработки.

.PARAMETER botID
    Идентификатор бота для которого обрабатывается сообщение.

.PARAMETER param
    Объект сообщения от Telegram API, содержащий данные о сообщении и отправителе.

.PARAMETER debugStop
    Флаг отключения отладочных сообщений. При значении $true отключает дополнительное логирование.
    По умолчанию: $true.

.PARAMETER queueDebugHash
    Хэш-таблица для записи отладочной информации о работе функции.

.PARAMETER queueLogHash
    Хэш-таблица для записи логов работы функции.

.PARAMETER queueErrorHash
    Хэш-таблица для записи ошибок, возникающих в процессе работы функции.

.EXAMPLE
    New-MessageHandler -botID "bot123456:ABC-DEF1234" -param $messageObject

    Обрабатывает сообщение с минимальным набором параметров.

.EXAMPLE
    New-MessageHandler -botID $botID -param $messageObject -debugStop $false -queueDebugHash $debugQueue

    Обрабатывает сообщение с включенным отладочным выводом и записью в очередь отладки.

.OUTPUTS
    Boolean. Возвращает $true в случае успешной обработки сообщения, $false в случае ошибки.

.NOTES
    Функция предназначена для использования в системе обработки сообщений Telegram бота.
    Для обработки команды /start используется функция New-MainForm. 
#>
function New-MessageHandler {

    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$botID,                 
        
        [Parameter(Mandatory = $true)]
        [object]$param,                 
        
        [Parameter(Mandatory = $false)]
        [bool]$debugStop = $true,             
                
        [Parameter(Mandatory = $false)]
        $queueUsersHash,  
                
        [Parameter(Mandatory = $false)]
        $queueGroupsHash,  
                        
        [Parameter(Mandatory = $false)]
        $queueCommandsHash,  

        [Parameter(Mandatory = $false)]
        $queueSendingHash,  

        [Parameter(Mandatory = $false)]
        $queueDebugHash,        
        
        [Parameter(Mandatory = $false)]
        $queueLogHash,          
        
        [Parameter(Mandatory = $false)]
        $queueErrorHash       
    )

    $userID = "$($param.from.id)"
    $userName = "$($param.from.username)"

    $alertChatID = $queueCommandsHash.alertGroup
    $alertUninvited = $queueCommandsHash.alertThreadUninvited
    $alertPhoneNotFound = $queueCommandsHash.alertThreadPhoneNotFound
    $alertSystemError = $queueCommandsHash.alertThreadSystemError

    $alertAdded = $queueCommandsHash.alertThreadAdded
    # $alertBlocked = $queueCommandsHash.alertThreadBlocked
    $alertUsersOut = $queueCommandsHash.alertThreadUsersOut
    $alertBalance = $queueCommandsHash.alertThreadBalance

    # Получаем числовой номер бота
    $botNum = $queueCommandsHash.botNum
    $botCreator = $queueCommandsHash.botCreator

    # $blockPeriod = $queueCommandsHash.blockPeriod

    $feed = '&#10;'  # Символ переноса строки в HTML-формате
    $doubleFeed = "$feed$feed"  # Двойной перенос строки

    # ИД и имя группы
    $groupChatID =$param.chat.id
    $groupName = $queueGroupsHash["$groupChatID"].title
    $capUserName = ""; $capUserNIC = ""; $capUserLang = ""; $capUserPremium = ""; $capUserID = ""

    # Если пришло сервисное сообщение о действиях с членами группы
    if ($param.chat_member) {
        
        $groupChatID =$param.chat_member.chat.id
        $groupName = $queueGroupsHash["$groupChatID"].title

        $capUserName = $param.chat_member.new_chat_member.user.first_name
        $capUserLastName = $param.chat_member.new_chat_member.user.last_name
        $capUserNIC = $param.chat_member.new_chat_member.user.username
        $capUserLang = $param.chat_member.new_chat_member.user.language_code
        $capUserPremium = $param.chat_member.new_chat_member.user.is_premium
        $capUserID = $param.chat_member.new_chat_member.user.id
                
        $messageText = ""

        # Переход пользователя по ссылке приглашению
        if ($param.chat_member.new_chat_member.status -eq "member") {

            # Будем переопределять ветку алертов
            $currentAlertTread = $null
            
            # Если пользователь есть в базе, то записываем статус активации. Иначе создаем запись пользователя в базе.
            if ($queueUsersHash.ContainsKey($capUserID)) {
                # Записываем статус активации в базу
                $queueUsersHash["$capUserID"].user_ststus.groups_state["$groupChatID"].activate = $true
            } else {
                # Создаем запись пользователя в базе
                $registerResult = Register-User -userID $capUserID -userData $param.chat_member.new_chat_member.user -queueUsersHash $queueUsersHash -queueErrorHash $queueErrorHash -queueLogHash $queueLogHash
                
                if ($registerResult) {
                    
                    $currentInvite = $null
                    $currentActivate = $null
                    if ($param.chat_member.invite_link) {
                        $currentInvite = $param.chat_member.invite_link.invite_link
                        $currentActivate = $true
                    }
    
                    $queueUsersHash["$capUserID"].user_ststus.groups_state["$groupChatID"] = [hashtable]::Synchronized(@{
                        state = "InviteError"
                        check_send_date = $null
                        activate = $currentActivate
                        check_count = 0
                        block_date = $null
                        block_time = 0
                        request_id = $null
                        invite_link = $currentInvite
                    })
                }
            }

            # Если зашел по приглашению
            if ($param.chat_member.invite_link) {

                # Отправляем алерт в ветку "Баланс"
                $currentAlertTread = $alertBalance
                
                # Готовим текст сообщения о добавлении пользователя
                $capInfo = "<i><strong>-Приглашение активировано.</strong></i>"
                $messageText = "Добавление в группу <strong>$groupName</strong>$doubleFeed" + 
                "<strong>Имя:</strong> $capUserName $capUserLastName $feed" + 
                "<strong>Ник:</strong> $capUserNIC $doubleFeed" +
                "<strong>Пригласил:</strong> $($param.chat_member.invite_link.creator.first_name) $($param.chat_member.invite_link.creator.last_name) $feed" +
                "$feed🧐 $capInfo"

                $tempKey = Get-tempKey; $queueLogHash[$tempKey] = @{ source = 'MessageHandler'; message = "Пользователь $capUserName присоеденился к группе $groupName по ссылке." }           
                Write-Host "MessageHandler Пользователь $capUserName присоеденился к группе $groupName по ссылке." -ForegroundColor Yellow -BackgroundColor Black
            } else {
            
                # Отправляем алерт в ветку "Без приглашения"
                $currentAlertTread = $alertUninvited
                
                # Готовим текст сообщения о добавлении пользователя
                $capInfo = "<i><strong>-Без приглашения добавлен.</strong></i>"
                $messageText = "Добавление в группу <strong>$groupName</strong>$doubleFeed" + 
                "<strong>Имя:</strong> $capUserName $capUserLastName $feed" + 
                "<strong>Ник:</strong> $capUserNIC $doubleFeed" +
                "<strong>Добавил:</strong> $($param.chat_member.from.first_name) $($param.chat_member.from.last_name) $feed" +

                "$feed🧐 $capInfo"

                $tempKey = Get-tempKey; $queueLogHash[$tempKey] = @{ source = 'MessageHandler'; message = "Пользователь $capUserName добавлен в группу $groupName без приглашения." }           
                Write-Host "MessageHandler Пользователь $capUserName добавлен в группу $groupName без приглашения." -ForegroundColor Yellow -BackgroundColor Black
            }

            $tempKey = Get-tempKey;
            $queueSendingHash[$tempKey] = @{
                action_type = 'send_message'; 
                chat_id = $alertChatID; 
                message_thread_id = $currentAlertTread; 
                text = $messageText; 
                reply_markup = $null; 
                start_message_id = $false; 
            }                
        }

        # Самоудаление пользователя из группы
        if ($param.chat_member.new_chat_member.status -eq "left") {
            
            $tempKey = Get-tempKey; $queueLogHash[$tempKey] = @{ source = 'MessageHandler'; message = "Пользователь $capUserName вышел из группы $groupName" }           
            Write-Host "MessageHandler Пользователь $capUserName вышел из группы $groupName" -ForegroundColor Blue -BackgroundColor Black
            
            # Проверяем что удалился сам, иначе удалили админы.
            if ($param.chat_member.from.id -eq $param.chat_member.new_chat_member.user.id) {
                $queueUsersHash["$capUserID"].user_ststus.groups_state["$groupChatID"].activate = $false
                $capInfo = "<i><strong>-Его никто не заставлял, он сам.</strong></i>"
            } else {
                $capInfo = "<i><strong>-$($param.chat_member.from.username)</strong> удалил.</i>"
            }

            # Готовим текст сообщения об удалении из группы.
            $messageText = "Выход из группы$feed<strong>$groupName</strong>$doubleFeed" +
            "<strong>Имя:</strong> $capUserName $capUserLastName $feed" + 
            "<strong>Ник:</strong> $capUserNIC $feed" +
            "$feed🧐 $capInfo"
            
            $tempKey = Get-tempKey;
            $queueSendingHash[$tempKey] = @{
                action_type = 'send_message'; 
                chat_id = $alertChatID; 
                message_thread_id = $alertUsersOut; 
                text = $messageText; 
                reply_markup = $null; 
                start_message_id = $false; 
            }    

        }      
        
        # Возвращаем успешный результат обработки.
        # ----------------------------------------
        return $true        
        
    }

    if ($param.my_chat_member) {

        $groupChatID =$param.my_chat_member.chat.id
        $groupName = $queueGroupsHash["$groupChatID"].title

        # Обрабатываем сообщение об удалении бота из группы
        if ($param.my_chat_member.new_chat_member.status -like "left") {

            # Получаем создателя из настроек
            $botCreator = $queueCommandsHash.botCreator

            # Если удалил создатель
            # Удаляем группу из базы групп.
            # if ($param.my_chat_member.from.id -eq $botCreator) {
                if ($queueGroupsHash["$groupChatID"]) {
                    try {
                        $queueGroupsHash.Remove("$groupChatID")
    
                        $tempKey = Get-tempKey; $queueLogHash[$tempKey] = @{ source = 'MessageHandler'; message = "$($param.my_chat_member.from.username) удалил бота из группы $groupName; Группа удалена из базы." }           
                        Write-Host "MessageHandler $($param.my_chat_member.from.username) удалил бота из группы $groupName; Группа удалена из базы." -ForegroundColor White -BackgroundColor Black
                    }
                    catch {
                        $tempKey = Get-tempKey; $queueErrorHash[$tempKey] = @{ source = 'MessageHandler'; message = "Не получилось удалить группу $groupName из базы." }           
                        Write-Host "MessageHandler не получилось удалить группу $groupName из базы." -ForegroundColor Red -BackgroundColor Black
                    }
                }
            # }

            return $true
        }

        # Ловим сообщение о добавлении бота в группу
        if ($param.my_chat_member.new_chat_member.status -like "member") {

            $tempKey = Get-tempKey; $queueLogHash[$tempKey] = @{ source = 'MessageHandler'; message = "MessageHandler бот был добавлен в группу $groupChatID $groupName" }           
            Write-Host "MessageHandler MessageHandler бот был добавлен в группу $groupChatID $groupName" -ForegroundColor DarkGray -BackgroundColor Black

            # Получаем администраторов группы
            $resultAdmins = $null; $resultAdmins = Get-ChatAdministrators -botID $botID -chatID $param.my_chat_member.chat.id

            if ($resultAdmins) {

                $tempKey = Get-tempKey; $queueLogHash[$tempKey] = @{ source = 'MessageHandler'; message = @{info = "MessageHandler получили админостраторов группы:  $($param.my_chat_member.chat.id) $($param.my_chat_member.chat.title)"; result = $resultAdmins.result} }           
                Write-Host "MessageHandler получили админостраторов группы:  $($param.my_chat_member.chat.id) $($param.my_chat_member.chat.title)" -ForegroundColor Magenta -BackgroundColor Black

                # Write-Host ($resultAdmins.result | ConvertTo-Json) -ForegroundColor Magenta -BackgroundColor Black

                # Перебор массива администраторов
                foreach ($admin in $resultAdmins.result) {
                    <#
                    Write-Host "=== АДМИНИСТРАТОР ===" -ForegroundColor Yellow
                    Write-Host "Имя: $($admin.user.first_name) $($admin.user.last_name)"
                    Write-Host "Username: @$($admin.user.username)"
                    Write-Host "ID: $($admin.user.id)"
                    Write-Host "Статус: $($admin.status)" -ForegroundColor Cyan
                    
                    # Вывод всех прав администратора
                    Write-Host "`n--- ПРАВА ---" -ForegroundColor Green
                    Write-Host "Может управлять чатом: $($admin.can_manage_chat)"
                    Write-Host "Может удалять сообщения: $($admin.can_delete_messages)"
                    Write-Host "Может банить пользователей: $($admin.can_restrict_members)"
                    Write-Host "Может приглашать пользователей: $($admin.can_invite_users)"
                    Write-Host "Может закреплять сообщения: $($admin.can_pin_messages)"
                    Write-Host "Может управлять видеочатами: $($admin.can_manage_video_chats)"
                    Write-Host "Может публиковать сообщения: $($admin.can_post_messages)"
                    Write-Host "Может редактировать сообщения: $($admin.can_edit_messages)"
                    Write-Host "Может управлять темами: $($admin.can_manage_topics)"
                    Write-Host "Может промотать сообщения: $($admin.can_promote_members)"
                    Write-Host "Анонимный: $($admin.is_anonymous)"
                    #>

                    # Находим созателя группы
                    if ($admin.status -eq "creator") {

                        $tempKey = Get-tempKey; $queueLogHash[$tempKey] = @{ source = 'MessageHandler'; message = "Нашли создателя группы:  $($param.my_chat_member.chat.id) - $($admin.user.username)" }           
                        Write-Host "Нашли создателя группы:  $($param.my_chat_member.chat.id) - $($admin.user.username)" -ForegroundColor Green -BackgroundColor Black

                        # Получаем настоящего создателя из настроек
                        $botCreator = $queueCommandsHash.botCreator

                        # Если создатель этой группы не наш, то удаляемся из нее
                        if ($admin.user.id -ne $botCreator) {

                            $tempKey = Get-tempKey; $queueLogHash[$tempKey] = @{ source = 'MessageHandler'; message = "Создатель не наш! $($admin.user.username) Удаляемся из группы $($param.my_chat_member.chat.id)" }           
                            Write-Host "Создатель $($admin.user.username) не наш! Удаляемся из группы $($param.my_chat_member.chat.id)" -ForegroundColor Red -BackgroundColor Black

                            # Тут удаляемся
                            $resultLeave = New-LeaveChat -botID $botID -chatID $param.my_chat_member.chat.id

                            Start-Sleep -Milliseconds 300

                            # И проверяем результат работы
                            # Если удалиться не получилось, отправляем сообщение в группу алертов.
                            if ($resultLeave -eq $false) {
                                $tempKey = Get-tempKey; $queueErrorHash[$tempKey] = @{ source = 'MessageHandler'; message = "Не удалось удалиться из левой группы! $($param.my_chat_member.chat.id). Создалтель её - $($admin.user.username)" }           
                                Write-Host "Не удалось удалиться из левой группы! $($param.my_chat_member.chat.id). Создалтель её - $($admin.user.username)" -ForegroundColor Red -BackgroundColor Black

                                $messageText = "Какой-то <strong>$($admin.user.username)</strong> $feed" + "добавил бота в группу <code>$($param.my_chat_member.chat.title)</code>$doubleFeed" + 
                                "<strong>Имя ему:</strong> $($admin.user.first_name)$feed" + 
                                "<strong>Язык:</strong> $($admin.user.language_code)$feed" +
                                "<strong>Премиум:</strong> $($admin.user.is_premium)$doubleFeed" + 
                                "‼️<strong> Но автоматически удалиться не получилось!</strong>$doubleFeed" + "🧐 <i><strong>-Нужно вмешательство администратора.</strong></i>"

                                $tempKey = Get-tempKey;
                                $queueSendingHash[$tempKey] = @{
                                    action_type = 'send_message'; 
                                    chat_id = $alertChatID; 
                                    message_thread_id = $alertAdded; 
                                    text = $messageText; 
                                    reply_markup = $null; 
                                    start_message_id = $false; 

                                }

                                $tempKey = Get-tempKey; $queueLogHash[$tempKey] = @{ source = 'MessageHandler'; message = "Отправлен алерт не удалось удалиться из группы $($param.my_chat_member.chat.title)" }           
                                Write-Host "MessageHandler Отправлен алерт не удалось удалиться из группы $($param.my_chat_member.chat.title)." -ForegroundColor Red -BackgroundColor Black

                            } else {
                                # Если все хорошо, то тоже отправляем сообщение в группу алертов но в совй топик.
                                $messageText = "Неизвестный <strong>$($admin.user.username)</strong> $feed" + "добавил бота в группу $doubleFeed<code>$($param.my_chat_member.chat.title)</code>$doubleFeed" + 
                                "<strong>Но мы такого не знаем!</strong>$doubleFeed" + "🧐 <i><strong>-Удалился не глядя!</strong></i>"

                                $tempKey = Get-tempKey;
                                $queueSendingHash[$tempKey] = @{
                                    action_type = 'send_message'; 
                                    chat_id = $alertChatID; 
                                    message_thread_id = $alertAdded; 
                                    text = $messageText; 
                                    reply_markup = $null; 
                                    start_message_id = $false; 
                                }

                                $tempKey = Get-tempKey; $queueLogHash[$tempKey] = @{ source = 'MessageHandler'; message = "Отправлен алерт об автоматическом удалении бота из группы $($param.my_chat_member.chat.title)" }           
                                Write-Host "MessageHandler Отправлен алерт об автоматическом удалении бота из группы $($param.my_chat_member.chat.title)." -ForegroundColor Red -BackgroundColor Black
                            }

                        } else {
                            # Ну а если создатель всетаки наш!
                            $tempKey = Get-tempKey; $queueLogHash[$tempKey] = @{ source = 'MessageHandler'; message = "Здравствуй создатель:  $($param.my_chat_member.chat.id) - $($admin.user.username)" }           
                            Write-Host "Здравствуй создатель:  $($param.my_chat_member.chat.id) - $($admin.user.username)" -ForegroundColor Yellow -BackgroundColor Black

                            # Проверяем, чтобы это не была наша группа алертов
                            if (($queueCommandsHash.alertGroup).CompareTo("$($param.my_chat_member.chat.id)") -eq 0) {
                                Write-Host "MessageHandler Это наша группа алертов, мы не будем ее отображать:  $($param.my_chat_member.chat.id) - $($admin.user.username)" -ForegroundColor Yellow -BackgroundColor Black
                                return $true
                            }

                            # Получаем информацию о группе
                            $resultChat = Get-Chat -botID $botID -chatID $param.my_chat_member.chat.id
                            # Write-Host "MessageHandler" ($resultChat | ConvertTo-Json -Depth 10)

                            # Если все хорошо, то 
                            # Создаем запись для добавления.
                            if ($resultChat) {
                                
                                $tempKey = Get-tempKey; $queueLogHash[$tempKey] = @{ source = 'MessageHandler'; message = @{info = "MessageHandler получили информацию о группе: $($param.my_chat_member.chat.id) $($param.my_chat_member.chat.title)"; result = $resultChat.result} }           
                                Write-Host "MessageHandler получили информацию о группе: $($param.my_chat_member.chat.id) $($param.my_chat_member.chat.title)" -ForegroundColor Green -BackgroundColor Black

                                $resultPhoto = [hashtable]::Synchronized(@{})
                                # Сначала готовим фото
                                if ($resultChat.result.photo) {
                                    $resultPhoto = [hashtable]::Synchronized(@{
                                        small_file_id = $resultChat.result.photo.small_file_id;
                                        small_file_unique_id = $resultChat.result.photo.small_file_unique_id;
                                        big_file_id = $resultChat.result.photo.big_file_id;
                                        big_file_unique_id = $resultChat.result.photo.big_file_unique_id;
                                    })
                                }

                                # Создаем итоговую запись с включением фото
                                $resultGroup = [hashtable]::Synchronized(@{
                                                id = $resultChat.result.id;
                                                title = $resultChat.result.title;
                                                is_forum = $resultChat.result.is_forum;
                                                type = $resultChat.result.type;
                                                description = $resultChat.result.description;
                                                photo = $resultPhoto;
                                })

                                # Добавляем группу в базу групп для вывода в инлайн-меню.
                                $groupChatID =$resultChat.result.id
                                $queueGroupsHash["$groupChatID"] = $resultGroup

                                # Готовим сообщение в группу алертов
                                $messageText = "Создатель <strong>$($admin.user.username)</strong> $feed" + "добавил бота в группу <code>$($param.my_chat_member.chat.title)</code>$doubleFeed" + 
                                "<strong>Имя:</strong> $($admin.user.first_name) $($admin.user.last_name) $feed" + 
                                "<strong>Язык:</strong> $($admin.user.language_code)$feed" +
                                "<strong>Премиум:</strong> $($admin.user.is_premium)$doubleFeed" + "🧐 <i><strong>-Проверьте, что бот админ в этой группе.</strong></i>"

                                # Отправляем сообщение в очередь
                                $tempKey = Get-tempKey;
                                $queueSendingHash[$tempKey] = @{
                                    action_type = 'send_message'; 
                                    chat_id = $alertChatID; 
                                    message_thread_id = $alertAdded; 
                                    text = $messageText; 
                                    reply_markup = $null; 
                                    start_message_id = $false; 
                                }

                                $tempKey = Get-tempKey; $queueLogHash[$tempKey] = @{ source = 'MessageHandler'; message = "Отправлен алерт об автоматическом удалении бота из группы $($param.my_chat_member.chat.title)" }           
                                Write-Host "MessageHandler Отправлен алерт об автоматическом удалении бота из группы $($param.my_chat_member.chat.title)." -ForegroundColor Red -BackgroundColor Black

                            }
                        }

                    }
                }

                return $true
            } else {
                $tempKey = Get-tempKey; $queueLogHash[$tempKey] = @{ source = 'MessageHandler'; message = "MessageHandler Не удалось получить админов группы при добавлении бота $groupChatID $groupName" }           
                Write-Host "MessageHandler MessageHandler Не удалось получить админов группы при добавлении бота $groupChatID $groupName" -ForegroundColor DarkGray -BackgroundColor Black
                return $false
            }

        }        
    }

    # Если сообщение пришло из группы.
    if ($param.chat.type -like '*group') {

        # Обработка и удаление сервисных сообщений
        # if ($param.new_chat_member -or $param.left_chat_member -or $param.new_chat_photo -or $param.new_chat_title -or $param.delete_chat_photo -or $param.supergroup_chat_created -or $param.channel_chat_created -or $param.pinned_message -or $param.forum_topic_created -or $param.forum_topic_closed -or $param.general_forum_topic_hidden -or $param.forum_topic_reopened) {
        if ($param.new_chat_photo -or $param.new_chat_title -or $param.delete_chat_photo -or $param.supergroup_chat_created -or $param.channel_chat_created -or $param.pinned_message -or $param.forum_topic_created -or $param.forum_topic_closed -or $param.general_forum_topic_hidden -or $param.forum_topic_reopened) {
                    
            $tempKey = Get-tempKey; $queueLogHash[$tempKey] = @{ source = 'MessageHandler'; message = "Поймали сервисное сообщение в группе $groupName" }           
            Write-Host "MessageHandler Поймали сервисное сообщение в группе $groupName" -ForegroundColor Yellow -BackgroundColor Black

            # if ($param.new_chat_member.id -ne $botNum ) {

            #     $userVerifyState = $false;
            #     $userVerifyState = $queueUsersHash["$($param.from.id)"].user_ststus.groups_state["$groupChatID"].state

            #     $capUserName = $param.new_chat_member.first_name
            #     $capUserNIC = $param.new_chat_member.username
            #     $capUserLang = $param.new_chat_member.language_code
            #     $capUserPremium = $param.new_chat_member.is_premium
            #     $capUserID = $param.new_chat_member.user.id
                
            #     $tempKey = Get-tempKey; $queueLogHash[$tempKey] = @{ source = 'MessageHandler'; message = "Статус пользователя  $capUserName - $userVerifyState" }           
            #     Write-Host "MessageHandler Статус пользователя  $capUserName - $userVerifyState" -ForegroundColor Yellow -BackgroundColor Black
                
            #     # Если пользователь не прошел верификацию через бота, то отправляем сообщение в группу алертов.
            #     if ($userVerifyState -notlike "Verified") {

            #         # Готовим текст алерта в группу логов
            #         $messageText = "<strong>$capUserName</strong> $feed" + "добавил пользователя в группу <code>$($param.chat.title)</code> напрямую без верификации!$doubleFeed" + 
            #                         "<strong>Имя:</strong> $capUserName $feed" + 
            #                         "<strong>Ник:</strong> $capUserNIC $feed" +
            #                         "<strong>Язык:</strong> $capUserLang $feed" +
            #                         "<strong>Премиум:</strong> $capUserPremium $doubleFeed" + "🧐 <i><strong>-Инцидент зафиксирован.</strong></i>"

            #         # Отправляем в очередь сообщений
            #         $tempKey = Get-tempKey;
            #         $queueSendingHash[$tempKey] = @{
            #             action_type = 'send_message'; 
            #             chat_id = $alertChatID; 
            #             message_thread_id = $alertUninvited; 
            #             text = $messageText; 
            #             reply_markup = $null; 
            #             start_message_id = $false; 
            #         }

            #         $tempKey = Get-tempKey; $queueLogHash[$tempKey] = @{ source = 'MessageHandler'; message = "Отправлен алерт о добавлении $capUserName; Добавил $capUserNIC" }           
            #         Write-Host "MessageHandler Отправлен алерт о добавлении $capUserName; Добавил $capUserNIC" -ForegroundColor Red -BackgroundColor Black

            #     } else {
            #         # Записываем в базу пользователя, что ссылка активирована.
            #         $queueUsersHash["$userID"].user_ststus.groups_state["$groupChatID"].activate = $true
            #         $tempKey = Get-tempKey; $queueLogHash[$tempKey] = @{ source = 'MessageHandler'; message = "Ссылка активирована пользователем: $userName; Для группы: $groupName" }           
            #         Write-Host "Ссылка активирована пользователем: $userName; Для группы: $groupName" -ForegroundColor Green -BackgroundColor Black
            #     }
              
            # }

            # # Ловим сообщение об удалении бота из группы
            # if ($param.left_chat_member) {

            #     if ($param.left_chat_member.id -ne $botNum) {
            #         # Пользователь выбыл из группы. Записываем в базу пользователя, что ссылка вновь активирована.
            #         $queueUsersHash["$userID"].user_ststus.groups_state["$groupChatID"].activate = $false

            #         $tempKey = Get-tempKey; $queueLogHash[$tempKey] = @{ source = 'MessageHandler'; message = "Пользователь: $userName; Вышел из группы: $groupChatID" }           
            #         Write-Host "Пользователь: $userName; Вышел из группы: $groupChatID" -ForegroundColor Yellow -BackgroundColor Black
            #     }

            # }

            # Ловим сообщение об изменении названия группы
            if ($param.new_chat_title) {

                $resultChat = $null; $resultChat = Get-Chat -botID $botID -chatID $param.chat.id
                Write-Host ($resultChat.result | ConvertTo-Json) -ForegroundColor White

                if ($resultChat) {
                    $queueGroupsHash["$groupChatID"].title = $resultChat.result.title
                    $queueGroupsHash["$groupChatID"].description = $resultChat.result.description
                    $queueGroupsHash["$groupChatID"].is_forum = $resultChat.result.is_forum
                    
                    $tempKey = Get-tempKey; $queueLogHash[$tempKey] = @{ source = 'MessageHandler'; message = "Имя группы: $($param.chat.id) изменено на $($param.new_chat_title)" }           
                    Write-Host "Имя группы: $($param.chat.id) изменено на $($param.new_chat_title)" -ForegroundColor White -BackgroundColor Black
                }

            }

            # Ловим сообщение об изменении фото группы
            if ($param.new_chat_photo) {
                $queueGroupsHash["$groupChatID"].photo.big_file_id = $param.new_chat_photo[-1].file_id
                $queueGroupsHash["$groupChatID"].photo.big_file_unique_id = $param.new_chat_photo[-1].file_unique_id
                
                $tempKey = Get-tempKey; $queueLogHash[$tempKey] = @{ source = 'MessageHandler'; message = "Фото группы: $($param.chat.id) изменено." }           
                Write-Host "Фото группы: $($param.chat.id) изменено на $($param.new_chat_photo[-1].file_id)." -ForegroundColor Yellow -BackgroundColor Black
            }
            
            # Удаляем сервисную команду из группы.
            $tempKey = Get-tempKey;
            $queueSendingHash[$tempKey] = @{action_type = 'delete_message'; 
                                            chat_id = $param.chat.id; 
                                            message_id = $param.message_id; 
                                        }   
            
            # Write-Host "MessageHandler Сервисное сообщение." ($param | ConvertTo-Json -Depth 5)

            $tempKey = Get-tempKey; $queueLogHash[$tempKey] = @{ source = 'MessageHandler'; message = "MessageHandler отправил в очередь удаление сервисного сообщения $($param.message_id) для группы: $($param.chat.id)" }           
            Write-Host "MessageHandler отправил в очередь удаление сервисного сообщения $($param.message_id) для группы: $($param.chat.id)" -ForegroundColor DarkGray -BackgroundColor Black

        }

        # Если пользователь не верифицирован будем пытаться забанить его в группе, если активна соответствующая настройка banIfNotVerified = true
        if ($param.text) {

            $userVerifyState = $false; $userVerifyState = $queueUsersHash["$userID"].user_ststus.groups_state["$groupChatID"].state
            Write-Host "MessageHandler chat.id =" $param.chat.id -ForegroundColor Blue -BackgroundColor Black
    
            if ($userVerifyState -notlike "Verified") {
    
                # Если это создатель, то ничего не делаем и завершаемся
                if ($userID -like $botCreator) {
                    return $true
                }
                
                $messageText = $false
                
                # Получаем настройку автоматического удаления из группы
                $banIfNotVerified = $false; $banIfNotVerified = $queueCommandsHash.banIfNotVerified
                Write-Host "MessageHandler banIfNotVerified = $banIfNotVerified" -ForegroundColor Yellow -BackgroundColor Black
                
                # Если в настройках указано банить не верифицированных
                if ($banIfNotVerified) {
        
                    $tempKey = Get-tempKey; $queueLogHash[$tempKey] = @{ source = 'MessageHandler'; message = "Статус пользоватлея  $($param.from.username) - $userVerifyState. Будем удалять из группы." }           
                    Write-Host "MessageHandler Статус пользоватлея $($param.from.username) - не верифицирован. Будем удалять из группы." -ForegroundColor Yellow -BackgroundColor Black

                    # Баним пользователя
                    $userKick = $false; $userKick = New-KickChatMember -botID $botID -chatID $groupChatID -userID $userID
        
                    if ($userKick) {

                        # Готовим текст алерта об исключении в группу логов
                        $messageText = "<strong>Пользователь </strong>" + "не проходил верификацию в группе <code>$($param.chat.title)</code> и был исключен.$doubleFeed" + 
                                        "<strong>Имя:</strong> $($param.from.first_name) $($param.from.last_name)$feed" + 
                                        "<strong>Ник:</strong> $($param.from.username)$feed" +
                                        "<strong>Язык:</strong> $($param.from.language_code)$feed" +
                                        "<strong>Премиум:</strong> $($param.from.is_premium)$doubleFeed" + "🧐 <i><strong>-Отправьте ему ссылку на бота верификации.</strong></i>"

                        # Отправляем в очередь сообщений
                        if ($messageText) {
                            $tempKey = Get-tempKey;
                            $queueSendingHash[$tempKey] = @{
                                action_type = 'send_message'; 
                                chat_id = $alertChatID; 
                                message_thread_id = $alertUsersOut; 
                                text = $messageText; 
                                reply_markup = $null; 
                                start_message_id = $false; 
                            }
            
                            $tempKey = Get-tempKey; $queueLogHash[$tempKey] = @{ source = 'MessageHandler'; message = "Отправлен алерт о кикнутом пользователе $($param.from.username);" }           
                            Write-Host "MessageHandler Отправлен алерт о добавлении $($param.new_chat_member.username); Добавил $($param.from.username)" -ForegroundColor Red -BackgroundColor Black
                        }

                    } else {
                        # Готовим текст алерта об ошибке исключения в группу логов
                        $messageText = "<strong>Пользователь </strong>" + "не проходил верификацию в группе <code>$($param.chat.title)</code> но исключить из группы не получилось.$doubleFeed" + 
                                        "<strong>Имя:</strong> $($param.from.first_name) $($param.from.last_name)$feed" + 
                                        "<strong>Ник:</strong> $($param.from.username)$feed" +
                                        "<strong>Язык:</strong> $($param.from.language_code)$feed" +
                                        "<strong>Премиум:</strong> $($param.from.is_premium)$doubleFeed" + "🧐 <i><strong>-Исключите его из группы.</strong></i>"

                        # Отправляем в очередь сообщений
                        if ($messageText) {
                            $tempKey = Get-tempKey;
                            $queueSendingHash[$tempKey] = @{
                                action_type = 'send_message'; 
                                chat_id = $alertChatID; 
                                message_thread_id = $alertSystemError; 
                                text = $messageText; 
                                reply_markup = $null; 
                                start_message_id = $false; 
                            }
            
                            $tempKey = Get-tempKey; $queueLogHash[$tempKey] = @{ source = 'MessageHandler'; message = "Отправлен алерт об ошибке исключения из группы для $($param.from.username);" }           
                            Write-Host "MessageHandler Отправлен алерт об ошибке исключения из группы для $($param.from.username);" -ForegroundColor Red -BackgroundColor Black
                        }
                    }
                }
    
            }
            
        }

        Write-Host "MessageHandler Сообщение пришло из группы." -ForegroundColor Magenta -BackgroundColor Black
        return $true
    }

    # Если сообщение пришло в чате с ботом.
    if ($param.chat.type -like 'private') {

        # Обрабатываем команду /start - создаем главную форму.
        # ----------------------------------------------------
        if ($param.text -like '/start') {
    
            # Заполняем форму
            $mainFormSplat = @{
                botID=$botID
                chatID=$userID
                debugStop=$debugStop
                queueCommandsHash=$queueCommandsHash
                queueSendingHash=$queueSendingHash
                queueDebugHash=$queueDebugHash
                queueLogHash=$queueLogHash
                queueErrorHash=$queueErrorHash
            }
            # Создаем форму
            $createMainFormResult = New-MainForm @mainFormSplat
            
            # Проверяем, что форма вернула истину.
            if ($createMainFormResult) { 

                # И запускаем функцию создания первоначальной записи в базе пользоватлеей
                $registerResult = Register-User -userID $param.from.id -userData $param.from -queueUsersHash $queueUsersHash -queueErrorHash $queueErrorHash -queueLogHash $queueLogHash

                # Если вдруг ничего не вышло, то отправляем сообщение в группу алертов.
                if (-not $registerResult) {
                    $tempKey = Get-tempKey; $queueLogHash[$tempKey] = @{ source = 'MessageHandler';message = "Запись для пользоватлея $($param.from.username) не создана в базе." }
                    Write-Host "Register-User вернул отрицательный код возврата." -ForegroundColor Red -BackgroundColor Black

                    # Готовим текст сообщения
                    $randomID = Get-Random -Minimum 1 -Maximum 1000000
                    $currentGroupName = $queueGroupsHash.$userGroup.title
                    $messageText = "‼️ <strong>Ошибка: $randomID</strong>$doubleFeed" + "Не удалось создать в базе первоначальную запись для пользователя.$doubleFeed" +
                    "<strong>Имя:</strong> $($param.from.first_name) $($param.from.last_name)$feed" + 
                    "<strong>Ник:</strong> $($param.from.username)$feed" +
                    "<strong>Язык:</strong> $($param.from.language_code)$feed" +
                    "<strong>Премиум:</strong> $($param.from.is_premium)$doubleFeed" + "🧐 <i><strong>-Это вообще редкость, свяжитесь с разработчиком.</strong></i>"
                    
                    $tempKey = Get-tempKey;
                    $queueSendingHash[$tempKey] = @{
                        action_type = 'send_message'; 
                        chat_id = $alertChatID; 
                        message_thread_id = $alertSystemError; 
                        text = $messageText; 
                        reply_markup = $null; 
                        start_message_id = $false; 
                    }

                    $tempKey = Get-tempKey; $queueLogHash[$tempKey] = @{ source = 'MessageHandler'; message = "Группа алертов. Сообщение об ошибке verifiStatusResult добавлено очередь." }           
                    Write-Host "MessageHandler Группа алертов. Сообщение об ошибке verifiStatusResult добавлено очередь." -ForegroundColor Blue -BackgroundColor White

                }
        
                $tempKey = Get-tempKey; $queueLogHash[$tempKey] = @{ source = 'MessageHandler';message = "pbMainForm вернул успешный код возврата." }
                Write-Host "pbMainForm вернул успешный код возврата." -ForegroundColor Green -BackgroundColor Black
                # return $true
    
            } else { 
                $tempKey = Get-tempKey; $queueLogHash[$tempKey] = @{ source = 'MessageHandler';message = "pbMainForm вернул отрицательный код возврата." }
                Write-Host "pbMainForm вернул отрицательный код возврата." -ForegroundColor Red -BackgroundColor Black
                return $false
            }

            # Проверяем, что это наш сотрудник и запускаем форму выбора чатов сразу.
            $isStaff = $null; $isStaff = $queueUsersHash.$userID.is_staff

            $tempKey = Get-tempKey; $queueLogHash[$tempKey] = @{ source = 'MessageHandler';message = "Текущий статус для $userName - $isStaff" }
            Write-Host "Текущий статус для $userName - $isStaff" -ForegroundColor Green -BackgroundColor Black

            if ($isStaff) {
                
                # Заполняем форму
                $startFormSplat = @{
                    botID=$botID
                    chatID=$userID
                    debugStop=$debugStop
                    queueUsersHash=$queueUsersHash
                    queueCommandsHash=$queueCommandsHash
                    queueSendingHash=$queueSendingHash
                    queueDebugHash=$queueDebugHash
                    queueLogHash=$queueLogHash
                    queueErrorHash=$queueErrorHash
                    infoNew=$null
                }
                # Делаем небольшой таймаут перед отправкой
                Start-Sleep -Milliseconds 1100
                $createStartFormResult = New-StartForm @startFormSplat

                # Проверяем, что форма вернула истину.
                if ($createStartFormResult) {
                    $tempKey = Get-tempKey; $queueLogHash[$tempKey] = @{ source = 'MessageHandler';message = "pbStartForm вернул успешный код возврата." }
                    Write-Host "MessageHandler pbStartForm вернул успешный код возврата." -ForegroundColor Green -BackgroundColor Black
                    return $true
                } else { 

                    # Если форму создать не удалось, отправляем алерт в группу.
                    $tempKey = Get-tempKey; $queueLogHash[$tempKey] = @{ source = 'MessageHandler';message = "pbStartForm вернул отрицательный код возврата." }
                    Write-Host "MessageHandler pbStartForm вернул отрицательный код возврата." -ForegroundColor Red -BackgroundColor Black

                    # Готовим текст сообщения
                    $messageText = "Не запустилась форма <strong>pbStartForm</strong> для пользователя:$doubleFeed" + 
                    "<strong>Имя:</strong> $($param.from.first_name) $($param.from.last_name)$feed" + 
                    "<strong>Ник:</strong> $($param.from.username)$feed" +
                    "<strong>Язык:</strong> $($param.from.language_code)$feed" +
                    "<strong>Премиум:</strong> $($param.from.is_premium)$doubleFeed" + "🧐 <i><strong>-Тут так просто не поймёшь, пишите разработчику.</strong></i>"
                    
                    # Отправляем алерт в группу
                    $tempKey = Get-tempKey;
                    $queueSendingHash[$tempKey] = @{
                        action_type = 'send_message'; 
                        chat_id = $alertChatID; 
                        message_thread_id = $alertSystemError; 
                        text = $messageText; 
                        reply_markup = $null; 
                        start_message_id = $false; 
                    }

                    $tempKey = Get-tempKey; $queueLogHash[$tempKey] = @{ source = 'MessageHandler'; message = "Группа алертов. Сообщение о неудачной отправке формы добавлено в очередь." }           
                    Write-Host "MessageHandler Группа алертов. Сообщение о неудачной отправке формы добавлено в очередь." -ForegroundColor Blue -BackgroundColor White

                    return $false
                }

            }
            
        } 

        # Пользователь прислал свой номер телефона, нажав на кнопку.
        if ($param.contact) {
    
            Write-Host "MessageHandler $($param.contact)"
            # Write-Host "MessageHandler queueCommandsHash" ($queueCommandsHash | ConvertTo-Json -Depth 5)
    
            if (-not $param.contact.vcard) {

                # Если номер телефона уже есть и новый отличается от сохраненного, то обновляем его и записываем дату обновления.
                if ($queueUsersHash["$userID"].phone_number) {

                    if ($queueUsersHash["$userID"].phone_number -notlike $param.contact.phone_number) {
                        $queueUsersHash["$userID"].phone_number = $param.contact.phone_number;
                        $queueUsersHash["$userID"].user_ststus.phone_change_date = Get-Date;
                        
                        $tempKey = Get-tempKey; $queueLogHash[$tempKey] = @{ source = 'MessageHandler';message = "Номер телефона успешно обновлен. Поле phone_input_date обновлено." }
                        Write-Host "MessageHandler pbStartForm:Номер телефона успешно обновлен. Поле phone_input_date обновлено." -ForegroundColor Green -BackgroundColor Black
                    } else {
                        Write-Host "MessageHandler pbStartForm:Номер телефона не изменился." -ForegroundColor Blue -BackgroundColor Black
                        # return $true
                    }
                } else {
                    # Если нет то записываем номер и дату.
                    $queueUsersHash["$userID"].phone_number = $param.contact.phone_number;
                    $queueUsersHash["$userID"].user_ststus.phone_input_date = Get-Date;

                    $tempKey = Get-tempKey; $queueLogHash[$tempKey] = @{ source = 'MessageHandler';message = "Номер телефона успешно записан. Поле phone_change_date записано." }
                    Write-Host "MessageHandler Номер телефона успешно записан. Поле phone_change_date записано." -ForegroundColor Green -BackgroundColor Black
                }
                
                # Получаем статус сотрудника перед проверкой
                $userIsStaff = $queueUsersHash["$userID"].is_staff

                # Получаем номер телефона пользователя и убираем лишние символы.
                $userPhoneNumber = ("$($param.contact.phone_number)").Replace("+", "")
                
                # Готовим параметры для функции проверки
                $checkStaffSplat = @{
                    phone=$userPhoneNumber
                    userID=$param.contact.user_id
                    queueCommandsHash=$queueCommandsHash
                    queueUsersHash=$queueUsersHash
                    queueSendingHash=$queueSendingHash
                    queueLogHash=$queueLogHash
                    queueErrorHash=$queueErrorHash
                }

                # Запускаем функцию проверки в базе сотрудников
                $userIsStaff = New-CheckStaff @checkStaffSplat

                # После проверки создаем главную форму для пользователя.
                if ($userIsStaff -eq $true) {

                    $startFormSplat = @{
                        botID=$botID
                        chatID=$userID
                        debugStop=$debugStop
                        queueUsersHash=$queueUsersHash
                        queueCommandsHash=$queueCommandsHash
                        queueSendingHash=$queueSendingHash
                        queueDebugHash=$queueDebugHash
                        queueLogHash=$queueLogHash
                        queueErrorHash=$queueErrorHash
                        infoNew=$null
                    }
                    $createStartFormResult = New-StartForm @startFormSplat
    
                    if ($createStartFormResult) {
                        
                        $tempKey = Get-tempKey; $queueLogHash[$tempKey] = @{ source = 'MessageHandler';message = "pbStartForm вернул успешный код возврата." }
                        Write-Host "MessageHandler pbStartForm вернул успешный код возврата." -ForegroundColor Green -BackgroundColor Black
                        return $true
        
                    } else { 
                        $tempKey = Get-tempKey; $queueLogHash[$tempKey] = @{ source = 'MessageHandler';message = "pbStartForm вернул отрицательный код возврата." }
                        Write-Host "MessageHandler pbStartForm вернул отрицательный код возврата." -ForegroundColor Red -BackgroundColor Black

                        # Готовим текст сообщения
                        $messageText = "Не запустилась форма <strong>pbStartForm</strong> при проверке телефона для пользователя:$doubleFeed" + 
                        "<strong>Имя:</strong> $($param.from.first_name) $($param.from.last_name)$feed" + 
                        "<strong>Ник:</strong> $($param.from.username)$feed" +
                        "<strong>Язык:</strong> $($param.from.language_code)$feed" +
                        "<strong>Премиум:</strong> $($param.from.is_premium)$doubleFeed" + "🧐 <i><strong>-Тут так просто не поймёшь, пишите разработчику.</strong></i>"
                        
                        # Отправляем алерт в группу о том
                        $tempKey = Get-tempKey;
                        $queueSendingHash[$tempKey] = @{
                            action_type = 'send_message'; 
                            chat_id = $alertChatID; 
                            message_thread_id = $alertSystemError; 
                            text = $messageText; 
                            reply_markup = $null; 
                            start_message_id = $false; 
                        }

                        $tempKey = Get-tempKey; $queueLogHash[$tempKey] = @{ source = 'MessageHandler'; message = "Группа алертов. Сообщение о блокировке добавлено очередь." }           
                        Write-Host "MessageHandler Группа алертов. Сообщение о блокировке добавлено очередь." -ForegroundColor Blue -BackgroundColor White


                        return $false
                    }
                } else {

                    # Формируем текст оповещения, для пользователя, что он не является сотрудником.
                    $tempKey = Get-tempKey; $queueLogHash[$tempKey] = @{ source = 'MessageHandler'; message = "MessageHandler pbStartForm $userID не сотрудник." }           
                    Write-Host "MessageHandler pbStartForm $userID не сотрудник." -ForegroundColor Red -BackgroundColor Black

                    $feed = '&#10;'  # Символ переноса строки в HTML-формате
                    $doubleFeed = "$feed$feed"  # Двойной перенос строки
                    
                    # Формируем текст сообщения с HTML-разметкой
                    $mainCaption = "<strong>❗К сожалению мы не нашли</strong> сотрудника с таким номером телефона.$doubleFeed" +
                                "<strong>Свяжитесь</strong>, со службой ИТ поддержки Вашей компании.$doubleFeed" + "🧐 <i><strong>-Потом отправьте номер еще раз. </strong></i>"

                    $captionText = "💠  <strong>Бот верификации</strong>$doubleFeed" + $mainCaption

                    $eulaButton = Build-teButton -picture "💡" -text "Условия использования" -url $queueCommandsHash.eulaUrl
                    $replyMarkupEULA = Build-teKeyboard -buttons @(@($eulaButton))

                    $messageID = $queueUsersHash["$userID"].message_id
                    $dataUrl = $queueCommandsHash.mainLogoAlert
                    $tempKey = Get-tempKey;

                    Start-Sleep -Milliseconds 100
                    $queueSendingHash[$tempKey] = @{action_type = 'edit_message_media'; 
                                                    chat_id = $userID; 
                                                    message_id = $messageID;
                                                    dataUrl = $dataUrl;
                                                    caption = $captionText;
                                                    reply_markup = $replyMarkupEULA;
                                                }
                    $tempKey = Get-tempKey; $queueLogHash[$tempKey] = @{ source = 'MessageHandler'; message = "Отправили в очередь edit_message_media. Меняем картинку пользователю $($param.from.username)." }           
                    Write-Host "Отправили в очередь edit_message_media. Меняем картинку пользователю $($param.from.username)." -ForegroundColor Red -BackgroundColor Black 

                    # $queueSendingHash[$tempKey] = @{action_type = 'edit_message_caption'; 
                    #                                 chat_id = $userID; 
                    #                                 message_id = $messageID;
                    #                                 caption = $captionText;
                    #                                 reply_markup = $replyMarkupEULA;
                    #                             }

                    $tempKey = Get-tempKey; $queueLogHash[$tempKey] = @{ source = 'MessageHandler'; message = "Номер телефона для $($param.from.username) не найден в базе." }
                    Write-Host "MessageHandler Номер телефона для $($param.from.username) не найден в базе." -ForegroundColor Cyan -BackgroundColor Black

                    # Отправляем алерт в группу о том, что номер не найден
                    $messageText = "<strong>Номер телефона</strong> пользователя не найден в базе сотрудников. $doubleFeed" + 
                    "<strong>Имя:</strong> $($param.from.first_name) $($param.from.last_name)$feed" + 
                    "<strong>Ник:</strong> <code>$($param.from.username)</code>$feed" +
                    "<strong>Язык:</strong> $($param.from.language_code)$feed" +
                    "<strong>Номер:</strong> <code>$($param.contact.phone_number)</code>$feed" +
                    "<strong>Премиум:</strong> $($param.from.is_premium)$doubleFeed" + "🧐 <i><strong>-Или это не наш, или не с того номера заходит.</strong></i>"

                    Start-Sleep -Milliseconds 100
                    $tempKey = Get-tempKey;
                    $queueSendingHash[$tempKey] = @{
                        action_type = 'send_message'; 
                        chat_id = $alertChatID; 
                        message_thread_id = $alertPhoneNotFound; 
                        text = $messageText; 
                        reply_markup = $null; 
                        start_message_id = $false; 
                    }

                    $tempKey = Get-tempKey; $queueLogHash[$tempKey] = @{ source = 'MessageHandler'; message = "Номер телефона для $($param.from.username) не найден в базе." }           
                    Write-Host "MessageHandler Номер телефона для $($param.from.username) не найден в базе." -ForegroundColor Red -BackgroundColor Black                         

                }

            }
        }

        # Остальные сообщения будем воспринимать, как отправку кода подтверждения
        if ($param.text) {
            # Получаем текущий экран пользователя
            $userScrin = $null; $userScrin = $queueUsersHash["$userID"].current_scrin.last_scrin
            Write-Host "MessageHandler userScrin =" $userScrin -ForegroundColor Yellow
            
            # # Проверяем что пользователь на экране верификации
            # if ($userScrin -like 'pbVerifyForm') {
    
            #     # Получаем текущую выбранную группу
            #     $userGroup = $null; $userGroup = $queueUsersHash["$userID"].current_scrin.last_group
            #     Write-Host "MessageHandler userGroup =" $userGroup -ForegroundColor White
                
            #     # Получаем статус верификации в группе
            #     $userVerifyedStatus = $null; $userVerifyedStatus = $queueUsersHash["$userID"].user_ststus.groups_state.$userGroup.state
            #     Write-Host "MessageHandler userVerifyedStatus =" $userVerifyedStatus -ForegroundColor DarkYellow
    
            #     # Проверяем, что ожидается код подтверждения
            #     if ($userVerifyedStatus -like "Awaiting_Code") {
    
            #         $infoNew = $null
            #         # Нормализуем введенное значение
            #         $userCommand = ($param.text).Trim() -replace '\s+', ''
            #         Write-Host "MessageHandler userCommand =" $userCommand -ForegroundColor White
    
            #         # Проверяем, что нормализованное число это целое положительное
            #         if ($userCommand -match '^\d+$' -and $userCommand.length -eq 6) {

            #             Write-Host "MessageHandler Код верификации подходит под требования =" $userCommand -ForegroundColor DarkYellow
                        
            #             $requestID = $queueUsersHash["$userID"].user_ststus.groups_state.$userGroup.request_id
            #             Write-Host "MessageHandler requestID $requestID" -ForegroundColor White
                        
            #             $gateID = $queueCommandsHash.gateID
            #             Write-Host "MessageHandler gateID OK" -ForegroundColor DarkYellow
                        
            #             # Запускаем проверку кода верификации через гейт телеграм 
            #             $verifiStatusResult = Get-VerificationStatus -requestID "$requestID" -gateID "$gateID" -code "$userCommand"
            #             Write-Host "MessageHandler verifiStatusResult" ($verifiStatusResult | ConvertTo-Json) -ForegroundColor White
    
            #             if ($verifiStatusResult.IsValid) {

            #                 # Формируем ссылку приглашение, записываем ее в базу. Форма верификации отобразит ее пользователю

            #                 $resultInvite = New-ChatInviteLink -botID $botID -chatID $userGroup -memberLimit 1
            #                 Write-Host "MessageHandler resultInvite" ($resultInvite | ConvertTo-Json) -ForegroundColor DarkYellow
                            
            #                 if ($resultInvite.ok) {
                                
            #                     $tempKey = Get-tempKey; $queueErrorHash[$tempKey] = @{ source = 'MessageHandler';message = "Устанавливаем статус полозователя в Verified" }
            #                     Write-Host "MessageHandler Устанавливаем статус полозователя в Verified" -ForegroundColor DarkYellow

            #                     # Устанавливаем статус пользователя
            #                     $queueUsersHash["$userID"].user_ststus.groups_state.$userGroup.state = "Verified"

            #                     <# Записываем invite_link пользователю в базу #>
            #                     $queueUsersHash["$userID"].user_ststus.groups_state.$userGroup.invite_link = $resultInvite.result.invite_link

            #                 } else {    

            #                     <# Записываем сообщение об ошибке #>
            #                     $tempKey = Get-tempKey; $queueLogHash[$tempKey] = @{ source = 'MessageHandler';message = @{info = "Не удалось создать ссылку приглашение."; data = $resultInvite} }
            #                     Write-Host "MessageHandler Не удалось создать ссылку приглашение." -ForegroundColor Red -BackgroundColor Red

            #                     # Готовим текст сообщения
            #                     $randomID = Get-Random -Minimum 1 -Maximum 1000000
            #                     $currentGroupName = $queueGroupsHash.$userGroup.title
            #                     $messageText = "‼️ <strong>Ошибка: $randomID</strong>$doubleFeed" + "Не удалось создать приглашение в группу <code>$currentGroupName</code>.$doubleFeed" +
            #                     "<strong>Имя:</strong> $($param.from.first_name)$feed" + 
            #                     "<strong>Ник:</strong> $($param.from.username)$feed" +
            #                     "<strong>Язык:</strong> $($param.from.language_code)$feed" +
            #                     "<strong>Премиум:</strong> $($param.from.is_premium)$doubleFeed" + "🧐 <i><strong>-Бот должен быть админом группы, проверьте.</strong></i>"
                                
            #                     $tempKey = Get-tempKey;
            #                     $queueSendingHash[$tempKey] = @{
            #                         action_type = 'send_message'; 
            #                         chat_id = $alertChatID; 
            #                         message_thread_id = $alertSystemError; 
            #                         text = $messageText; 
            #                         reply_markup = $null; 
            #                         start_message_id = $false; 
            #                     }

            #                     $tempKey = Get-tempKey; $queueLogHash[$tempKey] = @{ source = 'MessageHandler'; message = "Группа алертов. Сообщение об ошибке verifiStatusResult добавлено очередь." }           
            #                     Write-Host "MessageHandler Группа алертов. Сообщение об ошибке verifiStatusResult добавлено очередь." -ForegroundColor Blue -BackgroundColor White

            #                     # Записываем статус пользователя
            #                     $queueUsersHash["$userID"].user_ststus.groups_state["$userGroup"].state = "InviteError"

            #                     # Передаем в форму новые данные
            #                     $statusCaptionNew = "Приглашение не создано."
            #                     $infoNew = "‼️🧐  <i><strong>-Ошибка № </strong></i> <code>$randomID</code>"

            #                 }

            #             } else {
            #                 # Получаем статус проверки
            #                 $curentStatus = $verifiStatusResult.VerificationStatus

            #                 # Если ошибка, отправляем алерт в группу
            #                 if ($verifiStatusResult.Error) {

            #                     $tempKey = Get-tempKey; $queueErrorHash[$tempKey] = @{ source = 'MessageHandler';message = @{info = "Ошибка проверки кода верификации."; data = $verifiStatusResult} }
            #                     Write-Host "MessageHandler Ошибка проверки кода верификации для $($param.from.first_name); $($verifiStatusResult.Error)" -ForegroundColor Red -BackgroundColor White

            #                     # Готовим текст сообщения
            #                     $randomID = Get-Random -Minimum 1 -Maximum 1000000
            #                     $messageText = "‼️ <strong>Ошибка: $randomID</strong>$doubleFeed" + " При проверке кода верификации. $doubleFeed" + 
            #                     "<strong>Имя:</strong> $($param.from.first_name)$feed" + 
            #                     "<strong>Ник:</strong> $($param.from.username)$feed" +
            #                     "<strong>Язык:</strong> $($param.from.language_code)$feed" +
            #                     "<strong>Премиум:</strong> $($param.from.is_premium)$doubleFeed" + "🧐  <i><strong>-Telegram Gateway вернул ошибку.</strong></i>"
                                
            #                     # Отправляем алерт в группу
            #                     $tempKey = Get-tempKey;
            #                     $queueSendingHash[$tempKey] = @{
            #                         action_type = 'send_message'; 
            #                         chat_id = $alertChatID; 
            #                         message_thread_id = $alertSystemError; 
            #                         text = $messageText; 
            #                         reply_markup = $null; 
            #                         start_message_id = $false; 
            #                     }

            #                     $tempKey = Get-tempKey; $queueLogHash[$tempKey] = @{ source = 'MessageHandler'; message = "Группа алертов. Сообщение об ошибке verifiStatusResult добавлено очередь." }           
            #                     Write-Host "MessageHandler Группа алертов. Сообщение об ошибке verifiStatusResult добавлено очередь." -ForegroundColor Blue -BackgroundColor White

            #                     # Передаем в форму новые данные
            #                     $statusCaptionNew = "Не удалось проверить код. Сервис недоступен."
            #                     $infoNew = "‼️🧐  <i><strong>-Ошибка № </strong></i> <code>$randomID</code>"
            #                     # return $false
            #                 }

            #                 # Код просрочен, сбрасываем статус
            #                 if ($curentStatus -like "expired" -or $curentStatus -like "*exceeded") {
            #                     $queueUsersHash["$userID"].user_ststus.groups_state["$userGroup"].state = "New"
            #                     $queueUsersHash["$userID"].user_ststus.groups_state["$userGroup"].check_count = 0
            #                     $queueUsersHash["$userID"].user_ststus.groups_state["$userGroup"].check_send_date = $null
            #                     $queueUsersHash["$userID"].user_ststus.groups_state["$userGroup"].request_id = $null

            #                     $tempKey = Get-tempKey; $queueLogHash[$tempKey] = @{ source = 'MessageHandler';message = "Код просрочен, сбрасываем статус." }
            #                     Write-Host "MessageHandler Код просрочен, сбрасываем статус." -ForegroundColor Magenta -BackgroundColor Black
            #                 }

            #                 # Проверяем количество неудачных попыток
            #                 $currentCheckCount = $queueUsersHash["$userID"].user_ststus.groups_state.$userGroup.check_count

            #                 # Если очередная попытка не удачная, инкрементируем счетчик
            #                 if ($curentStatus -like "code_invalid") {
            #                     $currentCheckCount++
            #                     $queueUsersHash["$userID"].user_ststus.groups_state["$userGroup"].check_count = $currentCheckCount
            #                     Write-Host "MessageHandler Код не верный, увеличиваем счетчик." -ForegroundColor DarkYellow
            #                 }

            #                 # Если это была третья попытка, блокируем пользователя
            #                 if ($currentCheckCount -eq 3) {
            #                     $queueUsersHash["$userID"].user_ststus.groups_state["$userGroup"].state = "Blocked"
            #                     $queueUsersHash["$userID"].user_ststus.groups_state["$userGroup"].block_date = Get-Date
            #                     $queueUsersHash["$userID"].user_ststus.groups_state["$userGroup"].block_time = $blockPeriod

            #                     $tempKey = Get-tempKey; $queueLogHash[$tempKey] = @{ source = 'MessageHandler'; message = "Пользователь $($param.from.username) заблокирован." }           
            #                     Write-Host "MessageHandler Пользователь $($param.from.username) заблокирован." -ForegroundColor DarkRed -BackgroundColor White 

            #                     # Готовим текст сообщения
            #                     $messageText = "🚫  <strong>Пользователь заблокирован</strong> на $blockPeriod секунд. $doubleFeed" + 
            #                     "<strong>Имя:</strong> $($param.from.first_name)$feed" + 
            #                     "<strong>Ник:</strong> $($param.from.username)$feed" +
            #                     "<strong>Язык:</strong> $($param.from.language_code)$feed" +
            #                     "<strong>Премиум:</strong> $($param.from.is_premium)$doubleFeed" + "🧐 <i><strong>-Три раза ввёл неверный код.</strong></i>"
                                
            #                     # Отправляем алерт в группу о том, что пользователь заблокирован
            #                     $tempKey = Get-tempKey;
            #                     $queueSendingHash[$tempKey] = @{
            #                         action_type = 'send_message'; 
            #                         chat_id = $alertChatID; 
            #                         message_thread_id = $alertBlocked; 
            #                         text = $messageText; 
            #                         reply_markup = $null; 
            #                         start_message_id = $false; 
            #                     }

            #                     $tempKey = Get-tempKey; $queueLogHash[$tempKey] = @{ source = 'MessageHandler'; message = "Группа алертов. Сообщение о блокировке добавлено очередь." }           
            #                     Write-Host "MessageHandler Группа алертов. Сообщение о блокировке добавлено очередь." -ForegroundColor Blue -BackgroundColor White

            #                 }

            #             }

            #         } else {
            #             # Пишем пользователю, что
            #             Write-Host "MessageHandler Код верификации НЕ подходит =" $userCommand -ForegroundColor Red
                        
            #             $statusCaptionNew = "Формат кода неверный."
            #             $infoNew = "‼️🧐  <i><strong>-Должно быть шесть цифр.</strong></i>"

            #         }

            #         # После всех проверок выводим форму верификации.
            #         $verifyFormSplat = @{
            #         botID=$botID
            #         chatID=$userID
            #         groupID=$userGroup
            #         infoNew=$infoNew
            #         statusCaptionNew=$statusCaptionNew
            #         debugStop=$debugStop
            #         queueUsersHash=$queueUsersHash
            #         queueGroupsHash=$queueGroupsHash
            #         queueCommandsHash=$queueCommandsHash
            #         queueSendingHash=$queueSendingHash
            #         queueDebugHash=$queueDebugHash
            #         queueLogHash=$queueLogHash
            #         queueErrorHash=$queueErrorHash
            #         }

            #         Start-Sleep -Milliseconds 1000
            #         $verifyFormResult = New-VerifyForm @verifyFormSplat

            #         if ($verifyFormResult) {
            #             $tempKey = Get-tempKey; $queueLogHash[$tempKey] = @{ source = 'MessageHandler';message = "pbVerifyForm вернул успешный код возврата." }
            #             Write-Host "MessageHandler pbVerifyForm вернул успешный код возврата." -ForegroundColor Green -BackgroundColor Black
            #         } else {
            #             $tempKey = Get-tempKey; $queueLogHash[$tempKey] = @{ source = 'MessageHandler';message = "pbVerifyForm вернул отрицательный код возврата." }
            #             Write-Host "MessageHandler pbVerifyForm вернул отрицательный код возврата." -ForegroundColor Red -BackgroundColor Black
            #         }

            #         return $true
        
            #     }
    
    
    
            # }
        }

    }

    # Возвращаем успешный результат обработки.
    # ----------------------------------------
    return $true
}

