<#
.SYNOPSIS
    Обрабатывает сообщения, отправленные от имени самого бота (inline).

.DESCRIPTION
    Функция обрабатывает сообщения, которые были отправлены через бота с использованием
    inline-режима. Логирует информацию о сообщении, включая имя пользователя, ID сообщения
    и текст команды.

.PARAMETER botID
    Идентификатор бота, для которого обрабатывается сообщение.

.PARAMETER param
    Объект сообщения от Telegram API, содержащий данные о сообщении, отправленном через бота.

.PARAMETER debugStop
    Флаг отключения отладочных сообщений. При значении $true отключает дополнительное логирование.

.PARAMETER queueDebugHash
    Хэш-таблица для записи отладочной информации о работе функции.

.PARAMETER queueLogHash
    Хэш-таблица для записи логов работы функции.

.PARAMETER queueErrorngHash
    Хэш-таблица для записи ошибок, возникающих в процессе работы функции.

.EXAMPLE
    New-ViaBotHandler -botID "bot123456:ABC-DEF1234" -param $messageObject

    Обрабатывает сообщение, отправленное через другого бота.

.EXAMPLE
    New-ViaBotHandler -botID $botID -param $messageObject -debugStop $false -queueDebugHash $debugQueue

    Обрабатывает сообщение с включенным отладочным выводом и записью в очередь отладки.

.OUTPUTS
    String. Возвращает текст полученного сообщения.

.NOTES
    Функция предназначена для обработки сообщений, отправленных через inline-ботов.
    В текущей реализации функция только логирует информацию о сообщении и возвращает его текст.
    Может быть расширена для обработки специфичных команд, отправленных через других ботов.
#>
function New-ViaBotHandler {
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
    $groupID = $false

    switch -Wildcard ($param.text) {

        # Обработка действий, начинающихся с "select" 
        "select_*" {
            $actionType = $param.text -replace "select_", ""

            switch -Wildcard ($actionType) {
                "chat.*" {

                    $groupID = $actionType -replace "chat.", ""
                    # Write-Host $groupID -ForegroundColor Magenta -BackgroundColor Black
                    
                    # Получаем номер телефона пользователя и убираем лишние символы.
                    $userPhoneNumber = $false; $userPhoneNumber = ("$($queueUsersHash.$userID.phone_number)").Replace("+", "")
                    
                    if ($userPhoneNumber) {
                        
                        # # Получаем количество проверок
                        # $currentCheckCount = $queueUsersHash.$userID.user_ststus.groups_state.$groupID.check_count

                        # Получаем статус сотрудника из базы перед проверкой
                        $userIsStaff = $false; $userIsStaff = $queueUsersHash["$userID"].is_staff

                        # Готовим параметры для функции проверки
                        $checkStaffSplat = @{
                            phone=$userPhoneNumber
                            userID=$userID
                            queueCommandsHash=$queueCommandsHash
                            queueUsersHash=$queueUsersHash
                            queueSendingHash=$queueSendingHash
                            queueLogHash=$queueLogHash
                            queueErrorHash=$queueErrorHash
                        }

                        # Запускаем функцию проверки в базе сотрудников
                        $userIsStaff = New-CheckStaff @checkStaffSplat
                        Write-Host $groupID -ForegroundColor Magenta -BackgroundColor Black

                        if ($userIsStaff -ne $true) {

                            Write-Host "bpViaBotHandler pbStartForm $userID не сотрудник." -ForegroundColor Red -BackgroundColor Black
                            
                            # Формируем текст оповещения, для пользователя, что он не является сотрудником.
                            
                            $feed = '&#10;'  # Символ переноса строки в HTML-формате
                            $doubleFeed = "$feed$feed"  # Двойной перенос строки
                            
                            # Формируем текст сообщения с HTML-разметкой
                            $mainCaption = "<strong>❗ К сожалению мы не нашли</strong> сотрудника с таким номером телефона.$doubleFeed" +
                                        "<strong>Свяжитесь</strong>, со службой ИТ поддержки Вашей компании.$doubleFeed" + "🧐 <i><strong>-Потом отправьте номер еще раз. </strong></i>"
    
                            $captionText = "💠  <strong>Бот верификации</strong>$doubleFeed" + $mainCaption
    
                            $eulaButton = Build-teButton -picture "💡" -text "Условия использования" -url $queueCommandsHash.eulaUrl
                            $replyMarkupEULA = Build-teKeyboard -buttons @(@($eulaButton))
    
                            $messageID = $queueUsersHash.$userID.message_id
                            $tempKey = Get-tempKey;
                            $queueSendingHash[$tempKey] = @{action_type = 'edit_message_caption'; 
                                                            chat_id = $userID; 
                                                            message_id = $messageID;
                                                            caption = $captionText;
                                                            reply_markup = $replyMarkupEULA;
                                                        }
    
                            $tempKey = Get-tempKey; $queueLogHash[$tempKey] = @{ source = 'MessageHandler'; message = "Номер телефона для $($param.from.username) не найден в базе." }
                            Write-Host "MessageHandler Номер телефона для $($param.from.username) не найден в базе." -ForegroundColor Cyan -BackgroundColor Black
    
                            # Отправляем алерт в группу о том, что номер не найден
                            $messageText = "<strong>Номер телефона</strong> пользователя не найден в базе сотрудников. $doubleFeed" + 
                            "<strong>Имя:</strong> $($param.from.first_name)$feed" + 
                            "<strong>Ник:</strong> <code>$($param.from.username)</code>$feed" +
                            "<strong>Язык:</strong> $($param.from.language_code)$feed" +
                            "<strong>Номер:</strong> <code>$userPhoneNumber</code>$feed" +
                            "<strong>Премиум:</strong> $($param.from.is_premium)$doubleFeed" + "🧐 <i><strong>-Или это не наш, или не с того номера заходит.</strong></i>"
    
                            $alertChatID = $queueCommandsHash.alertGroup
                            $alertPhoneNotFound = $queueCommandsHash.alertThreadPhoneNotFound

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
                            
                            
                            # Делаем Revoke-ChatInviteLink пользователя для групп где есть приглашения.
                            $allGroups = $false; $allGroups = ($queueUsersHash.$userID.user_ststus.groups_state).Clone();

                            if ($allGroups) {
                                $counter = 0
                                foreach ($item in $allGroups.GetEnumerator()) {
                                    
                                    $currentChatID = "$($item.Key)"
                                    Write-Host "currentChatID: $currentChatID"

                                    # Получаем пригласительную ссылку для группы
                                    $inviteLink = $allGroups["$($item.Key)"].invite_link
                                    
                                    if ($inviteLink) {
                                        # Write-Host "Key: $inviteLink"

                                        # Баним польователя в группе
                                        # if ($counter -gt 2) { Start-Sleep -Milliseconds 350 }
                                        $userKick = $false; $userKick = New-KickChatMember -botID $botID -chatID $currentChatID -userID $userID
                                        if ($userKick.ok) {
                                            Write-Host "userKick: ok"

                                        }

                                        # Удаляем пригласительную ссылку
                                        if ($counter -gt 2) { Start-Sleep -Milliseconds 300 }
                                        $tempKey = Get-tempKey;
                                        $queueSendingHash[$tempKey] = @{
                                            action_type = 'rework_chat_invite_link'; 
                                            chat_id = $currentChatID;
                                            user_id = $userID;
                                            invite_link = $inviteLink; 
                                        }
                                    }
                                    $counter ++
                                }
                            }
    
                            return $true

                        } else {
                            $tempKey = Get-tempKey; $queueLogHash[$tempKey] = @{ source = 'MessageHandler';message = "bpViaBotHandler сотрудник $($param.from.username) прошел проверку через API." }
                            Write-Host "bpViaBotHandler сотрудник $($param.from.username) прошел проверку через API." -ForegroundColor Green -BackgroundColor Black
                        }

                        # # Увеличиваем счетчик проверок
                        # $currentCheckCount ++
                        # $queueUsersHash["$userID"].user_ststus.groups_state["$groupID"].check_count = $currentCheckCount

                    }

                    # Запускаем форму верификации для выбранной группы
                    $verifyFormSplat = @{
                        botID=$botID
                        chatID=$userID
                        groupID=$groupID
                        list=$true
                        debugStop=$debugStop
                        queueUsersHash=$queueUsersHash
                        queueGroupsHash=$queueGroupsHash
                        queueCommandsHash=$queueCommandsHash
                        queueSendingHash=$queueSendingHash
                        queueDebugHash=$queueDebugHash
                        queueLogHash=$queueLogHash
                        queueErrorHash=$queueErrorHash
                    }
                    $verifyFormResult = New-VerifyForm @verifyFormSplat

                    if ($verifyFormResult) {

                        $tempKey = Get-tempKey; $queueLogHash[$tempKey] = @{ source = 'MessageHandler';message = "bpViaBotHandler вернул успешный код возврата." }
                        Write-Host "bpViaBotHandler вернул успешный код возврата." -ForegroundColor Green -BackgroundColor Black
                    } else {
                        $tempKey = Get-tempKey; $queueLogHash[$tempKey] = @{ source = 'MessageHandler';message = "bpViaBotHandler вернул отрицательный код возврата." }
                        Write-Host "bpViaBotHandler вернул отрицательный код возврата." -ForegroundColor Red -BackgroundColor Black
                    }
                    
                    break
                }

            }

            # break
        }

        "send_*" {
            $infoText = $param.text -replace "send_info:", ""

            $tempKey = Get-tempKey; $queueLogHash[$tempKey] = @{ source = 'MessageHandler'; message = "отображаем справку для $userID." }
            Write-Host "bpViaBotHandler отображаем справку для $userID." -ForegroundColor Blue -BackgroundColor Black
                
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
                infoNew=$infoText
            }                       
            
            $createStartFormResult = New-StartForm @startFormSplat

            # Проверяем, что форма вернула истину.
            if ($createStartFormResult) {
                $tempKey = Get-tempKey; $queueLogHash[$tempKey] = @{ source = 'bpViaBotHandler';message = "pbStartForm вернул успешный код возврата." }
                Write-Host "bpViaBotHandler pbStartForm вернул успешный код возврата." -ForegroundColor Green -BackgroundColor Black
                # return $true
            }


        }


    }

    # Логируем информацию о сообщении, отправленном через бота
    # --------------------------------------------------------
    Write-Host "via_bot_user:" $param.from.username -ForegroundColor Black -BackgroundColor Yellow
    Write-Host "via_bot_message_id:" $param.message_id -ForegroundColor Black -BackgroundColor Yellow

    # Возвращаем текст полученного сообщения
    # ----------------------------------------
    return $param.text
}