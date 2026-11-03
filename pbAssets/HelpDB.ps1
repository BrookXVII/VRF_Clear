
$helpDB = [ordered]@{
    'a' = @{
        head = "Всё просто";
        description = 'Выбрать чат, получить приглашение и перейти в группу. В режиме одного окна не запутаешься.';
        image = "https://habrastorage.org/webt/yo/0i/au/yo0iausjatuyfwy-fgrsmc5wxqu.jpeg";
    };
    'b' = @{
        head = "Выбрать чат";
        description = 'Здесь расположен список групп для прохождения верификации. Выбирайте нужную и следуйте подсказкам.';
        image = "https://habrastorage.org/webt/yv/gx/_i/yvgx_izx0zg74kzmhsrvdfkaxv0.jpeg";
    };
    'c' = @{
        head = "Верификация в группе";
        description = 'Экран отображает название и описание группы, а так же статус верификации и подсказку по действиям.';
        image = "https://habrastorage.org/webt/2u/nr/yt/2unrytrx-rib7t9ab_0ce7rhj_y.jpeg";
    };
    'd' = @{
        head = "Получить приглашение";
        description = 'Если верификация еще не пройдена для выбранного чата, то на экране будет доступна одноименная кнопка.';
        image = "https://habrastorage.org/webt/dg/6s/9a/dg6s9ahjickmibfmqfotdudlct8.jpeg";
    };
    'e' = @{
        head = "Ограничения";
        description = 'Приглашение одноразовое и доступно только Вам.';
        image = "https://habrastorage.org/webt/xr/pd/x3/xrpdx3d2nm4dfvggaarqhfuho9q.jpeg";
    };
    'f' = @{
        head = "Помощь";
        description = 'Если что-то не работает, обратитесь в службу поддержки support@example.invalid.';
        image = "https://habrastorage.org/webt/vi/ow/sk/viowskfakl_sjobuzkr_a17hkh8.jpeg";
    };
}

$helpDBFile = $helpDB | ConvertTo-Json -Depth 10 
$helpDBFile | Out-File -FilePath D:\Scripts\VRF\verifybot\pbAssets\helpDB.json
