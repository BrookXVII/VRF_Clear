$botSettings = @{
    appPath = "D:\PSProject\verifybot";
    apiUrl = "https://example.invalid/hs/query/query_data/";
    botID = "bot1234234235:AAEovPsJjdfvsdfvsdfvIUCBCrGe1nw";
    checkToken = "f802b92df4904cef99936707fc4c6f35";
    gateID = "AAFfvsdfvsdfvBW5mOGf357sUg8gDvY2qNA";
    botNum = "1234234235";
    botCreator = "1231231233";
    banIfNotVerified = $true;
    alertGroup = "-1002342342345";
    eulaUrl = "https://example.invalid/privacy";
    logging = @{
        logFile = 'pbLogs\queueLogHash.json'
        errorFile = 'pbLogs\queueErrorHash.json'
        debugFile = 'pbLogs\queueDebugHash.json'
        maxSizeMB = 10
        keepFiles = 10
    }
    logSendGroup = "-100234234235";
    alertThreadBlocked = 18628;
    alertThreadUninvited = 18563;
    alertThreadPhoneNotFound = 18568;
    alertThreadSystemError = 18629;
    alertThreadAdded = 18669;
    alertThreadBalance = 18698;
    alertThreadUsersOut = 18697;
    mainLogo = "https://habrastorage.org/webt/ki/2h/fg/ki2hfg4jcygigtulu3mdxbfwgia.jpeg";
    groupItemLogo = "https://habrastorage.org/webt/vd/4t/nv/vd4tnvymbckxha5vvsjuf08dtca.png";
    groupItemVerified = "https://habrastorage.org/webt/zf/nk/z4/zfnkz4bon0husnteh8a6cmc0t7u.png";
    groupItemBlocked = "https://habrastorage.org/webt/vk/d9/w9/vkd9w91xcimfhytxjq2da6agtu8.png";
    groupItemWaiting = "https://habrastorage.org/webt/ky/cv/ii/kycvii7ycg2i61uuxkwnyurmc5e.png";
    inlineRunspacesMax = 10;
    inlineRunspacesSleepTime = 10;
    messageRunspacesMax = 10;
    messageRunspacesSleepTime = 100;
    callbackRunspacesMax = 10;
    callbackRunspacesSleepTime = 100;
    sendingRunspacesMax = 20;
    sendingMaxRetries = 3;
    preserveOrderPerChat = $true;
    sendingRunspacesSleepTime = 100;
    checkStaffSleepTimeSec = 3600;
    getUpdateTimeoutSec = 10;
    getUpdateSleepTime = 100;
    verifiTtl = 1800;
    blockPeriod = 600;
    botRun = $true
}

$botSettings | ConvertTo-Json | Out-File -FilePath c:\Projects\VerifyBot\pbSettings\BotSettings.json

