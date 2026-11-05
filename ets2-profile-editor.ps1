# ETS2 - Editor de Perfil
# Cria uma COPIA do perfil dono do save escolhido (ou do perfil modelo em templates\base)
# e altera apenas a copia. O perfil original nunca e modificado.
#
# Uso interativo:   powershell -NoProfile -ExecutionPolicy Bypass -File .\ets2-profile-editor.ps1
# Uso automatizado: .\ets2-profile-editor.ps1 -SavePath "...\save\1" -NewName "Teste" -Options 1,2,3,4 -XpPercent 50 -CashOption 2 -Yes
#                   .\ets2-profile-editor.ps1 -Template -NewName "Teste" -CompanyName "Minha Empresa" -Options 1,2 -XpPercent 50 -CashOption 2 -Yes

param(
    [string]$SavePath,
    [switch]$Template,
    [string]$NewName,
    [string]$CompanyName,
    [int[]]$Options,
    [int]$XpPercent = -1,
    [int]$CashOption = 0,
    [switch]$DriverSkills,
    [string]$DestRoot,
    [switch]$Yes
)

$ErrorActionPreference = 'Stop'
$lat = [Text.Encoding]::GetEncoding(28591)   # Latin1: le/grava os bytes do .sii sem alterar nada
$interactive = -not $PSBoundParameters.Count
# perfil modelo: jogo base, sem mods, salvo em texto
$templateSave = Join-Path $PSScriptRoot 'templates\base\save\1'

$scsKey = [byte[]](0x2a,0x5f,0xcb,0x17,0x91,0xd2,0x2f,0xb6,0x02,0x45,0xb3,0xd8,0x36,0x9e,0xd0,0xb2,0xc2,0x73,0x71,0x56,0x3f,0xbf,0x1f,0x3c,0x9e,0xdf,0x6b,0x11,0x82,0x5a,0x5d,0x0a)

# XP necessario para subir de nivel (niveis 1 a 30). Acima disso usamos o ultimo incremento (estimativa).
$lvSteps = 200,500,700,900,1000,1100,1300,1600,1700,2100,2300,2600,2700,2900,3000,3100,3400,3700,4000,4300,4600,4700,4900,5200,5700,5900,6000,6200,6600,6800

$cashValues = @{ 1 = 500000; 2 = 1000000; 3 = 5000000; 4 = 10000000; 5 = 30000000 }
$cashLabels = @{ 1 = '500 mil'; 2 = '1 milhao'; 3 = '5 milhoes'; 4 = '10 milhoes'; 5 = '30 milhoes' }

# Habilidades no maximo: adr e bitmask das 6 classes (63), as demais vao de 0 a 6
$skillMax = [ordered]@{ adr = 63; long_dist = 6; heavy = 6; fragile = 6; urgent = 6; mechanical = 6 }

# Garagem grande: status 3 com 5 vagas
$garageMaxStatus = 3
$garageMaxSlots = 5

function Read-Sii([string]$path) {
    # devolve o texto do .sii (Latin1) mesmo se estiver criptografado (ScsC)
    $text = $lat.GetString((Get-SiiBytes $path))
    if (-not $text.StartsWith('SiiNunit')) {
        throw ("O save '$(Split-Path (Split-Path $path -Parent) -Leaf)' esta em formato binario e nao pode ser editado.`n" +
            "  1. Feche o jogo e rode este script: ele ajusta o g_save_format no config.cfg`n" +
            "  2. Abra o jogo, carregue o perfil e salve (ou espere um autosave)`n" +
            "  3. Rode o script de novo e escolha o save novo")
    }
    return $text
}

function Get-SiiBytes([string]$path, [int]$limit = 0) {
    # descriptografa (ScsC) e descompacta; com $limit le so o comeco do arquivo
    $d = [IO.File]::ReadAllBytes($path)
    if ($d.Length -le 56 -or $lat.GetString($d, 0, 4) -ne 'ScsC') { return , $d }
    $iv = New-Object byte[] 16
    [Array]::Copy($d, 36, $iv, 0, 16)
    $n = [int][Math]::Floor(($d.Length - 56) / 16) * 16
    if ($limit -gt 0) { $n = [Math]::Min($n, 65536) }   # o deflate precisa do primeiro bloco inteiro
    $aes = [Security.Cryptography.Aes]::Create()
    $aes.Mode = 'CBC'; $aes.Padding = 'None'; $aes.Key = $scsKey; $aes.IV = $iv
    $plain = $aes.CreateDecryptor().TransformFinalBlock($d, 56, $n)
    $ms = New-Object IO.MemoryStream(, $plain)
    $null = $ms.Seek(2, 'Begin')   # cabecalho zlib
    $ds = New-Object IO.Compression.DeflateStream($ms, [IO.Compression.CompressionMode]::Decompress)
    if ($limit -gt 0) {
        $buf = New-Object byte[] $limit
        $read = 0
        while ($read -lt $limit) {
            $r = $ds.Read($buf, $read, $limit - $read)
            if ($r -le 0) { break }
            $read += $r
        }
        if (-not $read) { return , [byte[]]@() }
        return , $buf[0..($read - 1)]
    }
    $out = New-Object IO.MemoryStream
    $ds.CopyTo($out)
    return , $out.ToArray()
}

function Get-SiiFormat([string]$path) {
    # 'texto' (editavel) ou 'binario' (BSII), lendo so o comeco do arquivo
    try { $h = $lat.GetString([byte[]](Get-SiiBytes $path 8)) } catch { return 'desconhecido' }
    if ($h.StartsWith('SiiNunit')) { return 'texto' }
    if ($h.StartsWith('BSII')) { return 'binario' }
    return 'desconhecido'
}

function Get-SaveFormatSetting {
    # valor de g_save_format no config.cfg global do jogo
    $cfg = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'Euro Truck Simulator 2\config.cfg'
    $r = [pscustomobject]@{ Path = $cfg; Value = $null }
    if (Test-Path $cfg) {
        $m = Select-String -Path $cfg -Pattern '^\s*uset g_save_format "(\d+)"' | Select-Object -Last 1
        if ($m) { $r.Value = $m.Matches[0].Groups[1].Value }
    }
    return $r
}

function Set-SaveFormatSetting([string]$cfg) {
    $bak = "$cfg.bak_" + (Get-Date -Format 'yyyyMMdd_HHmmss')
    Copy-Item $cfg $bak
    $lines = @(Get-Content $cfg)
    if ($lines -match '^\s*uset g_save_format ') {
        $lines = $lines -replace '^\s*uset g_save_format "\d+"', 'uset g_save_format "2"'
    } else { $lines += 'uset g_save_format "2"' }
    [IO.File]::WriteAllLines($cfg, [string[]]$lines)
    return $bak
}

function Write-Sii([string]$path, [string]$text) {
    # grava em texto puro; o jogo aceita e volta a criptografar no proximo save
    [IO.File]::WriteAllBytes($path, $lat.GetBytes($text))
}

function Get-Block([string]$text, [string]$header) {
    $m = [regex]::Match($text, '(?ms)^' + $header + ' \{.*?^\}')
    if (-not $m.Success) { throw "Bloco '$header' nao encontrado no save." }
    return $m
}

function Get-SiiValue([string]$block, [string]$name) {
    $m = [regex]::Match($block, '(?m)^ ' + [regex]::Escape($name) + ': ([^\r\n]*)')
    if (-not $m.Success) { throw "Campo '$name' nao encontrado." }
    return $m.Groups[1].Value
}

function Set-SiiValue([string]$block, [string]$name, [string]$value) {
    $re = [regex]('(?m)^ ' + [regex]::Escape($name) + ': [^\r\n]*')
    if (-not $re.IsMatch($block)) { throw "Campo '$name' nao encontrado." }
    return $re.Replace($block, " ${name}: $value", 1)
}

function Get-SiiArray([string]$block, [string]$name) {
    $e = [regex]::Escape($name)
    return @([regex]::Matches($block, '(?m)^ ' + $e + '\[\d+\]: ([^\r\n]*)') | ForEach-Object { $_.Groups[1].Value })
}

function Set-SiiArray([string]$block, [string]$name, [string[]]$values, [string]$nl) {
    $e = [regex]::Escape($name)
    $re = [regex]('(?m)^ ' + $e + ': \d+\r?\n(?: ' + $e + '\[\d+\]: [^\r\n]*\r?\n)*')
    if (-not $re.IsMatch($block)) { throw "Lista '$name' nao encontrada." }
    $lines = @(" ${name}: $($values.Count)")
    for ($i = 0; $i -lt $values.Count; $i++) { $lines += " ${name}[$i]: $($values[$i])" }
    $new = ($lines -join $nl) + $nl
    return $re.Replace($block, { param($m) $new }, 1)
}

function Get-Unit([string]$text, [string]$id) {
    return [regex]::Match($text, '(?ms)^\w+ : ' + [regex]::Escape($id) + ' \{.*?^\}')
}

function Update-Unit([string]$text, [string]$id, [scriptblock]$fn) {
    $m = Get-Unit $text $id
    if (-not $m.Success) { return $text }
    return $text.Remove($m.Index, $m.Length).Insert($m.Index, (& $fn $m.Value))
}

function Get-PlayerFleet([string]$text) {
    # caminhoes e reboques do jogador (nao inclui os usados a venda)
    $p = (Get-Block $text 'player : \S+').Value
    $ids = @(Get-SiiArray $p 'trucks') + @(Get-SiiArray $p 'trailers')
    foreach ($f in 'my_truck', 'my_trailer', 'assigned_truck', 'assigned_trailer', 'assigned_vehicles') {
        $ids += [regex]::Match($p, '(?m)^ ' + $f + ': (\S+)').Groups[1].Value
    }
    foreach ($pv in @(Get-SiiArray $p 'my_vehicles') + @($ids)) {
        $u = Get-Unit $text $pv
        if ($u.Success) { $ids += [regex]::Match($u.Value, '(?m)^ vehicle: (\S+)').Groups[1].Value }
    }
    return @($ids | Where-Object { $_ -and $_ -ne 'null' } | Sort-Object -Unique | Where-Object { (Get-Unit $text $_).Success })
}

function Repair-Vehicle([string]$block) {
    # zera o desgaste reparavel (o *_unfixable o jogo nao conserta) e enche o tanque
    $arrays = @([regex]::Matches($block, '(?m)^ (\w+)\[\d+\]:') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
    $block = [regex]::Replace($block, '(?m)^ (\w+_wear)(\[\d+\])?: [^\r\n]*', {
        param($m)
        if ($m.Groups[2].Success -or $m.Groups[1].Value -notin $arrays) { return " $($m.Groups[1].Value)$($m.Groups[2].Value): 0" }
        return $m.Value
    })
    $block = [regex]::Replace($block, '(?m)^ cargo_damage: [^\r\n]*', ' cargo_damage: 0')
    return [regex]::Replace($block, '(?m)^ fuel_relative: [^\r\n]*', ' fuel_relative: 1')
}

function Get-LevelXp([int]$level) {
    $xp = 0
    for ($k = 0; $k -lt $level; $k++) {
        if ($k -lt $lvSteps.Count) { $xp += $lvSteps[$k] } else { $xp += $lvSteps[-1] }
    }
    return $xp
}

function Get-XpLevel([long]$xp) {
    $level = 0
    while ((Get-LevelXp ($level + 1)) -le $xp) { $level++ }
    return $level
}

function ConvertTo-HexName([string]$name) {
    return (([Text.Encoding]::UTF8.GetBytes($name) | ForEach-Object { $_.ToString('X2') }) -join '')
}

function ConvertFrom-HexName([string]$h) {
    if ($h -match '^([0-9A-Fa-f]{2})+$') {
        $b = for ($i = 0; $i -lt $h.Length; $i += 2) { [Convert]::ToByte($h.Substring($i, 2), 16) }
        return [Text.Encoding]::UTF8.GetString([byte[]]$b)
    }
    return $h
}

function ConvertFrom-SiiString([string]$v) {
    # o .sii guarda caracteres nao-ASCII como \xNN (bytes UTF-8)
    $v = [regex]::Replace($v.Trim('"'), '\\x([0-9A-Fa-f]{2})', { param($m) [string][char][Convert]::ToByte($m.Groups[1].Value, 16) })
    return [Text.Encoding]::UTF8.GetString($lat.GetBytes($v))
}

function ConvertTo-SiiString([string]$v) {
    $s = ([Text.Encoding]::UTF8.GetBytes($v) | ForEach-Object { if ($_ -lt 0x80) { [string][char]$_ } else { '\x' + $_.ToString('x2') } }) -join ''
    return '"' + $s + '"'
}

function Ask([string]$prompt) { return (Read-Host $prompt).Trim().Trim('"') }

function Get-ProfileRoots {
    $docs = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'Euro Truck Simulator 2'
    $roots = @(
        [pscustomobject]@{ Path = (Join-Path $docs 'profiles'); Tipo = 'Local' },
        [pscustomobject]@{ Path = (Join-Path $docs 'steam_profiles'); Tipo = 'Steam (local)' }
    )
    try {
        $steam = (Get-ItemProperty 'HKCU:\Software\Valve\Steam' -ErrorAction Stop).SteamPath
        if ($steam) {
            Get-ChildItem (Join-Path $steam 'userdata') -Directory -ErrorAction SilentlyContinue | ForEach-Object {
                $roots += [pscustomobject]@{ Path = (Join-Path $_.FullName '227300\remote\profiles'); Tipo = 'Steam Cloud' }
            }
        }
    } catch {}
    return $roots
}

function Get-ProfileName([string]$dir) {
    # nome real fica no profile.sii; se nao der para ler, usa o nome da pasta (hex)
    try {
        return ConvertFrom-SiiString (Get-SiiValue (Read-Sii (Join-Path $dir 'profile.sii')) 'profile_name')
    } catch { return ConvertFrom-HexName (Split-Path $dir -Leaf) }
}

function Get-ProfileMap([string]$dir) {
    # mapa escolhido na criacao do perfil: /map/europe.mbd = jogo base, outros = mapa mod
    try { $m = (Get-SiiValue (Read-Sii (Join-Path $dir 'profile.sii')) 'map_path').Trim('"') } catch { return '?' }
    $name = [IO.Path]::GetFileNameWithoutExtension($m)
    if ($name -eq 'europe') { return 'Europa' }
    return $name
}

function Get-Saves([string]$profileDir) {
    $saveDir = Join-Path $profileDir 'save'
    if (-not (Test-Path $saveDir)) { return @() }
    $saves = Get-ChildItem $saveDir -Directory | Where-Object { Test-Path (Join-Path $_.FullName 'game.sii') } | ForEach-Object {
        $g = Join-Path $_.FullName 'game.sii'
        $s = [pscustomobject]@{ Pasta = $_.FullName; Nome = $_.Name; Data = (Get-Item $g).LastWriteTime; Xp = $null; Cash = $null; Formato = (Get-SiiFormat $g) }
        try {
            $info = Read-Sii (Join-Path $_.FullName 'info.sii')
            $n = ConvertFrom-SiiString (Get-SiiValue $info 'name')
            if ($n) { $s.Nome = "$n ($($_.Name))" }
            $s.Xp = [long](Get-SiiValue $info 'info_players_experience')
            $s.Cash = [long](Get-SiiValue $info 'info_money_account')
        } catch {}
        $s
    }
    return @($saves | Sort-Object Data -Descending)
}

function Find-Profiles {
    $list = @()
    foreach ($r in Get-ProfileRoots) {
        if (-not (Test-Path $r.Path)) { continue }
        Get-ChildItem $r.Path -Directory | Where-Object { Test-Path (Join-Path $_.FullName 'profile.sii') } | ForEach-Object {
            $saves = Get-Saves $_.FullName
            if ($saves.Count) {
                $list += [pscustomobject]@{
                    Nome = (Get-ProfileName $_.FullName); Tipo = $r.Tipo; Mapa = (Get-ProfileMap $_.FullName); Pasta = $_.FullName
                    Saves = $saves; Ultimo = $saves[0].Data; Editaveis = @($saves | Where-Object Formato -eq 'texto').Count
                }
            }
        }
    }
    return @($list | Sort-Object Ultimo -Descending)
}

function Select-Item([string]$prompt, [int]$count) {
    $i = [int](Ask $prompt) - 1
    if ($i -lt 0 -or $i -ge $count) { throw "Opcao invalida." }
    return $i
}

try {
    Write-Host ""
    Write-Host "=== ETS2 - Editor de Perfil (cria uma copia, o original nao e alterado) ===" -ForegroundColor Cyan
    Write-Host ""
    if (Get-Process eurotrucks2 -ErrorAction SilentlyContinue) {
        throw "O Euro Truck Simulator 2 esta aberto. Feche o jogo e rode de novo."
    }

    # --- 0. formato dos saves: so saves em texto podem ser editados ---
    $fmt = Get-SaveFormatSetting
    if ((Test-Path $fmt.Path) -and $fmt.Value -ne '2') {
        Write-Host "Seu jogo esta configurado para salvar em formato binario (g_save_format = $(if ($fmt.Value) { $fmt.Value } else { 'padrao' }))." -ForegroundColor Yellow
        Write-Host "O script so consegue editar saves em texto (g_save_format = 2)."
        if (-not $Yes -and (Ask "Ajustar o config.cfg agora? Um backup sera criado (s/n)") -match '^[sSyY]') {
            $bak = Set-SaveFormatSetting $fmt.Path
            Write-Host "config.cfg ajustado. Backup: $bak" -ForegroundColor Green
            Write-Host "Saves antigos continuam em binario: abra o jogo, carregue o perfil e salve para gerar um save editavel."
        }
        Write-Host ""
    }

    # --- 1. save de origem ---
    if (-not $SavePath -and -not $Template) {
        Write-Host "Como deseja criar o novo perfil?"
        Write-Host "  [1] Clonar um perfil existente (qualquer mapa, inclusive mapas mod)"
        Write-Host "  [2] Criar perfil novo a partir do modelo (mapa Europa do jogo base, sem mods)"
        $Template = (Select-Item "Opcao" 2) -eq 1
        Write-Host ""
    }
    if ($Template) {
        if (-not (Test-Path (Join-Path $templateSave 'game.sii'))) { throw "Perfil modelo nao encontrado em $templateSave" }
        $SavePath = $templateSave
        Write-Host "O modelo usa o mapa Europa. Para jogar em um mapa mod, ative o mod, crie um perfil novo" -ForegroundColor DarkGray
        Write-Host "no jogo escolhendo esse mapa, salve uma vez e use a opcao 1 (clonar)." -ForegroundColor DarkGray
    }
    if (-not $SavePath) {
        Write-Host "Procurando perfis..."
        $profiles = Find-Profiles
        if (-not $profiles.Count) { throw "Nenhum perfil do ETS2 com save encontrado." }
        Write-Host "`nPerfis encontrados:"
        for ($i = 0; $i -lt $profiles.Count; $i++) {
            $p = $profiles[$i]
            $line = "  [{0}] {1,-24} {2,-14} mapa: {3,-12} ultimo save: {4:dd/MM/yyyy HH:mm}" -f ($i + 1), $p.Nome, "($($p.Tipo))", $p.Mapa, $p.Ultimo
            if ($p.Editaveis) { Write-Host $line } else { Write-Host "$line  [nenhum save editavel]" -ForegroundColor DarkGray }
        }
        $p = $profiles[(Select-Item "`nNumero do perfil" $profiles.Count)]

        Write-Host "`nSaves do perfil $($p.Nome):"
        for ($i = 0; $i -lt $p.Saves.Count; $i++) {
            $s = $p.Saves[$i]
            $extra = if ($null -ne $s.Xp) { "nivel {0,-4} saldo {1:N0}" -f (Get-XpLevel $s.Xp), $s.Cash } else { '' }
            $line = "  [{0}] {1,-32} {2:dd/MM/yyyy HH:mm}   " -f ($i + 1), $s.Nome, $s.Data
            if ($s.Formato -eq 'texto') { Write-Host "$line$extra" }
            else { Write-Host "$line[binario - salve de novo no jogo]" -ForegroundColor DarkGray }
        }
        $s = $p.Saves[(Select-Item "`nNumero do save" $p.Saves.Count)]
        if ($s.Formato -ne 'texto') { $null = Read-Sii (Join-Path $s.Pasta 'game.sii') }   # gera o erro com as instrucoes
        $SavePath = $s.Pasta
    }
    $SavePath = $SavePath.Trim('"')
    if ((Test-Path $SavePath -PathType Leaf) -and (Split-Path $SavePath -Leaf) -eq 'game.sii') { $SavePath = Split-Path $SavePath -Parent }
    if (-not (Test-Path (Join-Path $SavePath 'game.sii'))) { throw "Nao achei game.sii em: $SavePath" }
    $saveDir = (Resolve-Path $SavePath).Path
    $slot = Split-Path $saveDir -Leaf
    $saveRoot = Split-Path $saveDir -Parent
    $srcProfile = Split-Path $saveRoot -Parent
    if ((Split-Path $saveRoot -Leaf) -ne 'save' -or -not (Test-Path (Join-Path $srcProfile 'profile.sii'))) {
        throw "O caminho precisa estar dentro de <perfil>\save\<save>."
    }

    $game = Read-Sii (Join-Path $saveDir 'game.sii')
    $nl = if ($game.Contains("`r`n")) { "`r`n" } else { "`n" }
    $economy = Get-Block $game 'economy : \S+'
    $bank = Get-Block $game 'bank : \S+'
    $curXp = [long](Get-SiiValue $economy.Value 'experience_points')
    $curCash = [long](Get-SiiValue $bank.Value 'money_account')
    # cidades existentes no mapa do jogador (base + DLCs que ele tem)
    $cities = @([regex]::Matches($game, '(?m)^company : company\.volatile\.[^.\s]+\.([^\s{]+) \{') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)

    $srcLabel = if ($Template) { 'Modelo (jogo base, sem mods)' } else { Get-ProfileName $srcProfile }
    Write-Host ("`nPerfil de origem: {0}" -f $srcLabel)
    Write-Host ("Save: {0}   (XP atual: {1} / nivel {2}, saldo: {3:N0})" -f $slot, $curXp, (Get-XpLevel $curXp), $curCash)

    # --- 2. nome da copia ---
    if (-not $DestRoot) { $DestRoot = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'Euro Truck Simulator 2\profiles' }
    if (-not $NewName) { $NewName = Ask "`nNome do novo perfil (copia)" }
    if (-not $NewName -or $NewName -match '["\\]') { throw "Nome invalido." }
    if ($Template -and -not $PSBoundParameters.ContainsKey('CompanyName')) {
        $CompanyName = Ask "Nome da empresa (Enter = manter 'Mundo')"
    }
    if ($CompanyName -match '["\\]') { throw "Nome da empresa invalido." }
    $destProfile = Join-Path $DestRoot (ConvertTo-HexName $NewName)
    if (Test-Path $destProfile) { throw "Ja existe um perfil com o nome '$NewName' em $DestRoot." }

    # --- 3. o que alterar ---
    if (-not $Options) {
        Write-Host "`nO que deseja alterar? (pode escolher mais de um, ex: 1,3)"
        Write-Host "  [1] XP"
        Write-Host "  [2] Cash"
        Write-Host "  [3] Garagens, concessionarias e agencias de recrutamento"
        Write-Host "  [4] Habilidades (todas no maximo)"
        Write-Host "  [5] Mapa: visitar todas as cidades e descobrir empresas"
        Write-Host "  [6] Quitar emprestimos e sair do cheque especial"
        Write-Host "  [7] Reparar e abastecer toda a frota"
        Write-Host "  [8] Todas as opcoes acima"
        $Options = (Ask "Opcoes") -split '[,; ]+' | Where-Object { $_ } | ForEach-Object { [int]$_ }
    }
    if ($Options -contains 8) { $Options = 1..7 }
    $Options = @($Options | Sort-Object -Unique)
    if (-not $Options -or ($Options | Where-Object { $_ -notin 1..7 })) { throw "Opcoes invalidas." }

    $playerBlock = (Get-Block $game 'player : \S+').Value
    $hiredDrivers = @(Get-SiiArray $playerBlock 'drivers' | Where-Object { $_ -ne 'null' -and (Get-Unit $game $_).Value -match '^driver_ai ' })
    $loanIds = @(Get-SiiArray $bank.Value 'loans')
    $loanTotal = 0
    foreach ($l in $loanIds) { $loanTotal += [long]((Get-Unit $game $l).Value | Select-String '(?m)^ amount: (\d+)').Matches[0].Groups[1].Value }
    $fleet = @(Get-PlayerFleet $game)

    if ($Options -contains 1) {
        if ($XpPercent -lt 0) { $XpPercent = [int](Ask "Nivel desejado em % (0 a 100, onde 100% = nivel 100)") }
        if ($XpPercent -lt 0 -or $XpPercent -gt 100) { throw "Porcentagem invalida." }
        $newXp = Get-LevelXp $XpPercent
    }
    if ($Options -contains 2) {
        if (-not $CashOption) {
            Write-Host "Quanto somar ao saldo?"
            foreach ($k in ($cashValues.Keys | Sort-Object)) { Write-Host "  [$k] $($cashLabels[$k])" }
            $CashOption = [int](Ask "Opcao")
        }
        if (-not $cashValues.ContainsKey($CashOption)) { throw "Opcao de cash invalida." }
        $newCash = $curCash + $cashValues[$CashOption]
    }
    if ($Options -contains 4 -and $hiredDrivers.Count -and -not $PSBoundParameters.ContainsKey('DriverSkills')) {
        $DriverSkills = (Ask "Aplicar tambem aos $($hiredDrivers.Count) motoristas contratados? (s/n)") -match '^[sSyY]'
    }

    # --- 4. resumo e confirmacao ---
    Write-Host "`n--- Resumo ---" -ForegroundColor Yellow
    Write-Host "Copiar perfil : $(if ($Template) { $srcLabel } else { $srcProfile })"
    Write-Host "Novo perfil   : $NewName  ->  $destProfile"
    if ($CompanyName) { Write-Host "Empresa       : $CompanyName" }
    Write-Host "Save editado  : $slot  (unico save copiado para o novo perfil)"
    if ($Options -contains 1) {
        Write-Host ("XP            : {0} -> {1}  (nivel {2})" -f $curXp, $newXp, $XpPercent)
        if ($XpPercent -gt $lvSteps.Count) { Write-Host "                (acima do nivel $($lvSteps.Count) o XP e estimado)" -ForegroundColor DarkGray }
        if ($newXp -lt $curXp) { Write-Host "                ATENCAO: o XP vai diminuir" -ForegroundColor Red }
    }
    if ($Options -contains 2) { Write-Host ("Cash          : {0:N0} + {1:N0} = {2:N0}" -f $curCash, $cashValues[$CashOption], $newCash) }
    if ($Options -contains 3) { Write-Host "Garagens      : todas as das cidades do seu mapa no tamanho maximo ($garageMaxSlots vagas); concessionarias e agencias liberadas" }
    if ($Options -contains 4) {
        $cur = ($skillMax.Keys | ForEach-Object { "$_=$(Get-SiiValue $economy.Value $_)" }) -join ' '
        $new = ($skillMax.Keys | ForEach-Object { "$_=$($skillMax[$_])" }) -join ' '
        Write-Host "Habilidades   : $cur"
        Write-Host "             -> $new"
        if ($DriverSkills -and $hiredDrivers.Count) { Write-Host "                (tambem para os $($hiredDrivers.Count) motoristas contratados)" }
    }
    if ($Options -contains 5) { Write-Host "Mapa          : $($cities.Count) cidades visitadas e todas as empresas descobertas" }
    if ($Options -contains 6) {
        if ($loanIds.Count) { Write-Host ("Emprestimos   : {0} quitado(s), total {1:N0} (sem descontar do saldo)" -f $loanIds.Count, $loanTotal) }
        else { Write-Host "Emprestimos   : nenhum em aberto (so limpa o cheque especial)" }
    }
    if ($Options -contains 7) { Write-Host "Frota         : $($fleet.Count) caminhao(oes)/reboque(s) reparados e abastecidos" }
    if (-not $Yes) {
        if ((Ask "`nConfirmar? (s/n)") -notmatch '^[sSyY]') { Write-Host "Cancelado. Nada foi alterado."; return }
    }

    # --- 5. copia do perfil ---
    # so o save escolhido vai para a copia; senao o jogo abre o autosave (nao editado) e grava por cima
    Write-Host "`nCopiando perfil..."
    $null = New-Item -ItemType Directory (Join-Path $destProfile 'save') -Force
    Get-ChildItem $srcProfile -Force | Where-Object { $_.Name -ne 'save' } | Copy-Item -Destination $destProfile -Recurse
    Copy-Item $saveDir (Join-Path $destProfile "save\$slot") -Recurse

    $prof = Read-Sii (Join-Path $destProfile 'profile.sii')
    $prof = Set-SiiValue $prof 'profile_name' (ConvertTo-SiiString $NewName)
    if ($CompanyName) { $prof = Set-SiiValue $prof 'company_name' (ConvertTo-SiiString $CompanyName) }
    if ($Options -contains 1) { $prof = Set-SiiValue $prof 'cached_experience' $newXp }
    Write-Sii (Join-Path $destProfile 'profile.sii') $prof
    if (Test-Path (Join-Path $destProfile 'profile.bak.sii')) { Write-Sii (Join-Path $destProfile 'profile.bak.sii') $prof }

    # --- 6. alteracoes no save da copia ---
    $destSave = Join-Path $destProfile "save\$slot"
    $econ = $economy.Value
    $bk = $bank.Value

    if ($Options -contains 1) { $econ = Set-SiiValue $econ 'experience_points' $newXp }
    if ($Options -contains 2) { $bk = Set-SiiValue $bk 'money_account' $newCash }
    if ($Options -contains 4) { foreach ($k in $skillMax.Keys) { $econ = Set-SiiValue $econ $k $skillMax[$k] } }

    $garageCount = 0
    if ($Options -contains 3) {
        # concessionarias e agencias: todas as cidades com empresas no mapa + as ja liberadas
        $dealers = @(@(Get-SiiArray $econ 'unlocked_dealers') + $cities | Sort-Object -Unique)
        $econ = Set-SiiArray $econ 'unlocked_dealers' $dealers $nl
        $recruitments = @(@(Get-SiiArray $econ 'unlocked_recruitments') + $cities | Sort-Object -Unique)
        $econ = Set-SiiArray $econ 'unlocked_recruitments' $recruitments $nl
    }
    if ($Options -contains 5) {
        # visited_cities e visited_cities_count sao listas paralelas: mantem as contagens existentes
        $visited = @(Get-SiiArray $econ 'visited_cities')
        $counts = @(Get-SiiArray $econ 'visited_cities_count')
        foreach ($c in $cities) { if ($c -notin $visited) { $visited += $c; $counts += '1' } }
        $econ = Set-SiiArray $econ 'visited_cities' $visited $nl
        $econ = Set-SiiArray $econ 'visited_cities_count' $counts $nl
    }
    if ($Options -contains 6) {
        $bk = Set-SiiArray $bk 'loans' @() $nl
        $bk = Set-SiiValue $bk 'overdraft' 'false'
        $bk = Set-SiiValue $bk 'overdraft_timer' 0
        $bk = Set-SiiValue $bk 'overdraft_warn_count' 0
    }

    $game = $game.Remove($bank.Index, $bank.Length).Insert($bank.Index, $bk)
    $economy = Get-Block $game 'economy : \S+'   # indice pode ter mudado
    $game = $game.Remove($economy.Index, $economy.Length).Insert($economy.Index, $econ)

    if ($Options -contains 3) {
        $game = [regex]::Replace($game, '(?ms)^garage : garage\.(\S+) \{.*?^\}', {
            param($m)
            # cidades fora do mapa (DLC que o jogador nao tem) nao tem garagem: compra-las quebra o save
            if ($m.Groups[1].Value -notin $cities) { return $m.Value }
            $g = $m.Value
            $vehicles = @(Get-SiiArray $g 'vehicles')
            $drivers = @(Get-SiiArray $g 'drivers')
            while ($vehicles.Count -lt $garageMaxSlots) { $vehicles += 'null' }
            while ($drivers.Count -lt $garageMaxSlots) { $drivers += 'null' }
            $g = Set-SiiArray $g 'vehicles' $vehicles $nl
            $g = Set-SiiArray $g 'drivers' $drivers $nl
            $script:garageCount++
            return (Set-SiiValue $g 'status' $garageMaxStatus)
        })
    }
    if ($Options -contains 4 -and $DriverSkills) {
        foreach ($d in $hiredDrivers) {
            $game = Update-Unit $game $d { param($b) foreach ($k in $skillMax.Keys) { $b = Set-SiiValue $b $k $skillMax[$k] }; $b }
        }
    }
    if ($Options -contains 5) {
        $game = [regex]::Replace($game, '(?ms)^company : \S+ \{.*?^\}', { param($m) $m.Value -replace '(?m)^ discovered: false', ' discovered: true' })
    }
    if ($Options -contains 6) {
        foreach ($l in $loanIds) { $game = [regex]::Replace($game, '(?ms)^bank_loan : ' + [regex]::Escape($l) + ' \{.*?^\}\r?\n(\r?\n)?', '') }
    }
    if ($Options -contains 7) {
        foreach ($v in $fleet) { $game = Update-Unit $game $v { param($b) Repair-Vehicle $b } }
    }
    Write-Sii (Join-Path $destSave 'game.sii') $game

    # info.sii guarda copias dos valores mostradas na tela de carregar
    $infoPath = Join-Path $destSave 'info.sii'
    if (Test-Path $infoPath) {
        $info = Read-Sii $infoPath
        if ($Options -contains 1) { $info = Set-SiiValue $info 'info_players_experience' $newXp }
        if ($Options -contains 2) { $info = Set-SiiValue $info 'info_money_account' $newCash }
        if ($Options -contains 3) {
            $info = Set-SiiValue $info 'info_unlocked_dealers' $dealers.Count
            $info = Set-SiiValue $info 'info_unlocked_recruitments' $recruitments.Count
        }
        if ($Options -contains 5) { $info = Set-SiiValue $info 'info_visited_cities' $visited.Count }
        Write-Sii $infoPath $info
    }

    Write-Host "`nPronto!" -ForegroundColor Green
    if ($Options -contains 3) { Write-Host "Garagens alteradas: $garageCount   Concessionarias: $($dealers.Count)   Agencias: $($recruitments.Count)" }
    Write-Host "Abra o jogo, escolha o perfil '$NewName' e carregue o save '$slot'."
}
catch {
    Write-Host "`nERRO: $($_.Exception.Message)" -ForegroundColor Red
}
finally {
    if ($interactive) { Write-Host ""; Read-Host "Pressione Enter para sair" | Out-Null }
}
