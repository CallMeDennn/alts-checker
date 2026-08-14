Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

$script:accounts = New-Object System.Collections.Generic.List[string]
$script:seen = New-Object System.Collections.Generic.HashSet[string]
$script:sources = New-Object System.Collections.Generic.List[string]
$script:nickPaths = New-Object 'System.Collections.Generic.Dictionary[string, System.Collections.Generic.List[string]]'
$script:journalLines = New-Object System.Collections.Generic.List[string]
$script:journalError = $null
$script:nickControls = @{}
$script:currentTab = 'acc'
$script:scanJob = $null
$script:scanTimer = $null
$script:journalJob = $null
$script:journalTimer = $null

function Brush($hex) { return (New-Object System.Windows.Media.BrushConverter).ConvertFromString($hex) }

$script:scanCode = @'
try {
  $progressFile = Join-Path $env:TEMP 'coralmc_progress.txt'
  $progressTmp = Join-Path $env:TEMP 'coralmc_progress.tmp'
  function Update-Progress($percent, $action, $processed, $total, $elapsed) {
    try {
      $elapsedInt = [math]::Round($elapsed)
      $str = "$percent|$action|$processed|$total|$elapsedInt"
      [System.IO.File]::WriteAllText($progressTmp, $str)
      Move-Item -LiteralPath $progressTmp -Destination $progressFile -Force -ErrorAction SilentlyContinue
    } catch {}
  }
  
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  Update-Progress 0 "Inizializzazione..." 0 1 $sw.Elapsed.TotalSeconds

  function Read-TextFile($path) { try { return [System.IO.File]::ReadAllText($path) } catch { return $null } }
  function Read-GzFile($path) {
    try {
      $fs = [System.IO.File]::OpenRead($path)
      $gz = New-Object System.IO.Compression.GZipStream($fs, [System.IO.Compression.CompressionMode]::Decompress)
      $sr = New-Object System.IO.StreamReader($gz, [System.Text.Encoding]::UTF8)
      $t = $sr.ReadToEnd()
      $sr.Close(); $gz.Close(); $fs.Close()
      return $t
    } catch { return $null }
  }
  function Valid-Nick($s) {
    if (-not $s) { return $false }
    return ($s -match '^[A-Za-z0-9_]{3,16}$')
  }
  $accounts = New-Object System.Collections.Generic.List[string]
  $seen = New-Object System.Collections.Generic.HashSet[string]
  $sources = New-Object System.Collections.Generic.List[string]
  $nickPaths = New-Object 'System.Collections.Generic.Dictionary[string, System.Collections.Generic.List[string]]'
  function Add-Nick($nick, $path) {
    if (-not (Valid-Nick $nick)) { return }
    $key = $nick.ToLower()
    if ($seen.Add($key)) { $accounts.Add($nick) | Out-Null }
    if ($path) {
      if (-not $nickPaths.ContainsKey($key)) { $nickPaths[$key] = New-Object 'System.Collections.Generic.List[string]' }
      if (-not $nickPaths[$key].Contains($path)) { $nickPaths[$key].Add($path) | Out-Null }
    }
  }
  $mc = Join-Path $env:APPDATA '.minecraft'

  $filesToProcess = @()
  $logsDir = Join-Path $mc 'logs'
  if (Test-Path -LiteralPath $logsDir) {
    $filesToProcess += @(Get-ChildItem -LiteralPath $logsDir -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '\.log$' -or $_.Name -match '\.log\.gz$' })
  }
  
  $jsonFiles = @(
    @{ path = (Join-Path $mc 'usernamecache.json');      patterns = @('"[^"]+"\s*:\s*"([^"]+)"') },
    @{ path = (Join-Path $mc 'usercache.json');          patterns = @('"name"\s*:\s*"([^"]+)"') },
    @{ path = (Join-Path $mc 'launcher_profiles.json');  patterns = @('"playerName"\s*:\s*"([^"]+)"', '"username"\s*:\s*"([^"]+)"', '"displayName"\s*:\s*"([^"]+)"') },
    @{ path = (Join-Path $mc 'launcher_accounts.json');  patterns = @('"name"\s*:\s*"([^"]+)"', '"username"\s*:\s*"([^"]+)"') }
  )
  foreach ($jf in $jsonFiles) {
    if (Test-Path -LiteralPath $jf.path) { $filesToProcess += $jf }
  }
  
  $shig = Join-Path $mc 'shig.inima'
  if (Test-Path -LiteralPath $shig) { $filesToProcess += @{ path = $shig; isShig = $true } }

  $totalFiles = $filesToProcess.Count
  if ($totalFiles -eq 0) { $totalFiles = 1 }
  $processed = 0

  # 1) LOGS (Setting user:, anche .gz)
  if (Test-Path -LiteralPath $logsDir) {
    $files = @(Get-ChildItem -LiteralPath $logsDir -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '\.log$' -or $_.Name -match '\.log\.gz$' })
    foreach ($f in $files) {
      $processed++
      $pct = [math]::Round(($processed / $totalFiles) * 100)
      Update-Progress $pct "Scansione logs: $($f.Name)" $processed $totalFiles $sw.Elapsed.TotalSeconds
      $sources.Add($f.FullName) | Out-Null
      $text = if ($f.Name.EndsWith('.gz')) { Read-GzFile $f.FullName } else { Read-TextFile $f.FullName }
      if ($text) {
        $ms = [regex]::Matches($text, '(?m)Setting user:\s*(\S+)')
        foreach ($m in $ms) { Add-Nick $m.Groups[1].Value.Trim() $f.FullName }
      }
    }
  }

  # 2) CACHE / LAUNCHER
  foreach ($jf in $jsonFiles) {
    if (Test-Path -LiteralPath $jf.path) {
      $processed++
      $pct = [math]::Round(($processed / $totalFiles) * 100)
      Update-Progress $pct "Scansione cache: $(Split-Path $jf.path -Leaf)" $processed $totalFiles $sw.Elapsed.TotalSeconds
      $sources.Add($jf.path) | Out-Null
      $text = Read-TextFile $jf.path
      if ($text) {
        foreach ($pat in $jf.patterns) {
          $ms = [regex]::Matches($text, $pat)
          foreach ($m in $ms) { Add-Nick $m.Groups[1].Value $jf.path }
        }
      }
    }
  }

  # 3) shig.inima (una riga = un nick)
  if (Test-Path -LiteralPath $shig) {
    $processed++
    $pct = [math]::Round(($processed / $totalFiles) * 100)
    Update-Progress $pct "Scansione shig.inima" $processed $totalFiles $sw.Elapsed.TotalSeconds
    $sources.Add($shig) | Out-Null
    $text = Read-TextFile $shig
    if ($text) {
      foreach ($line in ($text -split "`n")) {
        $t = $line.Trim()
        if ($t) { Add-Nick $t $shig }
      }
    }
  }

  Update-Progress 100 "Completato" $totalFiles $totalFiles $sw.Elapsed.TotalSeconds

  $np = @{}
  foreach ($k in $nickPaths.Keys) { $np[$k] = @($nickPaths[$k]) }
  @{ accounts = @($accounts); sources = @($sources); nickPaths = $np; error = $null }
} catch {
  @{ accounts = @(); sources = @(); nickPaths = @{}; error = "$($_.Exception.Message)" }
}
'@

$script:journalCode = @'
try {
  $temp = Join-Path $env:TEMP 'coralmc_usn.txt'
  try { if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue } } catch { }
  $pipeline = 'fsutil usn readjournal C: csv | findstr /i /C:"0x80000200" | findstr /i /C:"latest.log" /C:".log.gz" /C:"launcher_profiles.json" /C:"usernamecache.json" /C:"usercache.json" /C:"shig.inima" /C:"launcher_accounts.json" > "' + $temp + '"'
  $isAdmin = $false
  try {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $wp = New-Object Security.Principal.WindowsPrincipal($id)
    $isAdmin = $wp.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
  } catch { }
  if ($isAdmin) {
    cmd.exe /c $pipeline | Out-Null
  } else {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'cmd.exe'
    $psi.Arguments = '/c ' + $pipeline
    $psi.UseShellExecute = $true
    $psi.Verb = 'runas'
    $p = [System.Diagnostics.Process]::Start($psi)
    if (-not $p.WaitForExit(300000)) { try { $p.Kill() } catch { } }
  }
  $lines = @()
  if (Test-Path -LiteralPath $temp) {
    $lines = @(Get-Content -LiteralPath $temp -ErrorAction SilentlyContinue | Where-Object { $_ -and $_.Trim() })
  }
  @{ lines = $lines; error = $null }
} catch {
  @{ lines = @(); error = "$($_.Exception.Message)" }
}
'@

[xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="CoralMC Alts Checker" Width="640" Height="720"
        WindowStartupLocation="CenterScreen" ResizeMode="NoResize"
        Background="#0a0f1a" FontFamily="Segoe UI">
  <Window.Resources>
    <Style x:Key="DarkBtn" TargetType="Button">
      <Setter Property="Background" Value="#16233a"/>
      <Setter Property="Foreground" Value="#8b98ab"/>
      <Setter Property="BorderBrush" Value="#1e293b"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="8">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter Property="Background" Value="#1d2f4d"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>
  <Grid>
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>
    <StackPanel Grid.Row="0" Margin="26,20,26,8">
      <DockPanel LastChildFill="False">
        <StackPanel DockPanel.Dock="Left" Orientation="Horizontal" VerticalAlignment="Center">
          <TextBlock Text="CoralMC" Foreground="#38bdf8" FontSize="20" FontWeight="Bold"/>
          <TextBlock Text="Alts Checker" Foreground="#e5e7eb" FontSize="20" FontWeight="Bold" Margin="8,0,0,0"/>
        </StackPanel>
        <Button x:Name="btnInfo" DockPanel.Dock="Right" Content="Info" Width="58" Height="30" Style="{StaticResource DarkBtn}"/>
      </DockPanel>
      <Rectangle Height="1" Fill="#1e293b" Margin="0,12,0,0"/>
    </StackPanel>

    <Grid x:Name="pnlHome" Grid.Row="1" Margin="26,6,26,6">
      <Border Background="#0f172a" CornerRadius="12" BorderBrush="#1e293b" BorderThickness="1">
        <ScrollViewer VerticalScrollBarVisibility="Auto">
          <StackPanel Margin="22,18,22,20">
            <TextBlock Text="Select Data Source" Foreground="#e5e7eb" FontSize="15" FontWeight="Bold"/>
            <TextBlock Text="Log, cache, launcher e file eliminati: tutte le fonti." Foreground="#8b98ab" FontSize="12" Margin="0,2,0,14"/>
            <Border x:Name="rowLogs" Background="#131f33" CornerRadius="10" BorderBrush="#1e293b" BorderThickness="1" Margin="0,0,0,10" Cursor="Hand">
              <DockPanel Margin="12">
                <Border DockPanel.Dock="Left" Width="38" Height="38" CornerRadius="19" Background="#173049">
                  <TextBlock Text="L" Foreground="#38bdf8" FontSize="15" FontWeight="Bold" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                </Border>
                <TextBlock x:Name="arrL" DockPanel.Dock="Right" Text=">" Foreground="#8b98ab" FontSize="14" VerticalAlignment="Center" Margin="14,0,4,0"/>
                <StackPanel Margin="12,0,0,0" VerticalAlignment="Center">
                  <TextBlock Text="Logs di Minecraft" Foreground="#e5e7eb" FontSize="13" FontWeight="Bold"/>
                  <TextBlock Text="Log 'Setting user:' (anche .gz) + usernamecache, usercache, launcher_profiles/accounts, shig.inima" Foreground="#8b98ab" FontSize="11"/>
                </StackPanel>
              </DockPanel>
            </Border>
            <Border x:Name="rowJournal" Background="#131f33" CornerRadius="10" BorderBrush="#1e293b" BorderThickness="1" Margin="0,0,0,10" Cursor="Hand">
              <DockPanel Margin="12">
                <Border DockPanel.Dock="Left" Width="38" Height="38" CornerRadius="19" Background="#3b2a14">
                  <TextBlock Text="J" Foreground="#fbbf24" FontSize="15" FontWeight="Bold" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                </Border>
                <TextBlock x:Name="arrJ" DockPanel.Dock="Right" Text=">" Foreground="#8b98ab" FontSize="14" VerticalAlignment="Center" Margin="14,0,4,0"/>
                <StackPanel Margin="12,0,0,0" VerticalAlignment="Center">
                  <TextBlock Text="Journal" Foreground="#e5e7eb" FontSize="13" FontWeight="Bold"/>
                  <TextBlock Text="Cerca i file di Minecraft ELIMINATI (USN Journal, serve Admin)" Foreground="#8b98ab" FontSize="11"/>
                </StackPanel>
              </DockPanel>
            </Border>
            <Border x:Name="rowCestino" Background="#131f33" CornerRadius="10" BorderBrush="#1e293b" BorderThickness="1" Margin="0,0,0,14" Cursor="Hand">
              <DockPanel Margin="12">
                <Border DockPanel.Dock="Left" Width="38" Height="38" CornerRadius="19" Background="#3a1515">
                  <TextBlock Text="C" Foreground="#f87171" FontSize="15" FontWeight="Bold" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                </Border>
                <TextBlock x:Name="arrC" DockPanel.Dock="Right" Text=">" Foreground="#8b98ab" FontSize="14" VerticalAlignment="Center" Margin="14,0,4,0"/>
                <StackPanel Margin="12,0,0,0" VerticalAlignment="Center">
                  <TextBlock Text="Cestino" Foreground="#e5e7eb" FontSize="13" FontWeight="Bold"/>
                  <TextBlock Text="Apri la cartella C:\$Recycle.Bin" Foreground="#8b98ab" FontSize="11"/>
                </StackPanel>
              </DockPanel>
            </Border>
            <Button x:Name="btnAnalyze" Content="Analizza dati caricati" Height="42" Style="{StaticResource DarkBtn}" FontSize="13" FontWeight="Bold"/>
          </StackPanel>
        </ScrollViewer>
      </Border>
    </Grid>

    <Grid x:Name="pnlScan" Grid.Row="1" Margin="26,6,26,6" Visibility="Collapsed">
      <Border Background="#0f172a" CornerRadius="12" BorderBrush="#1e293b" BorderThickness="1">
        <Grid>
          <TextBlock Text="Scanning..." Foreground="#8b98ab" FontSize="12" HorizontalAlignment="Left" VerticalAlignment="Top" Margin="18,14,0,0"/>
          <StackPanel HorizontalAlignment="Center" VerticalAlignment="Center" Width="400">
            <Grid x:Name="spinGrid" Width="70" Height="70" HorizontalAlignment="Center">
              <Ellipse Width="70" Height="70" Stroke="#38bdf8" StrokeThickness="6" StrokeDashArray="27.5 9.17" StrokeStartLineCap="Round" StrokeEndLineCap="Round" Fill="Transparent"/>
            </Grid>
            <TextBlock x:Name="txtScanStatus" Text="Minecraft Scan..." Foreground="#8b98ab" FontSize="12" HorizontalAlignment="Center" Margin="0,18,0,12"/>
            <Grid Width="360" Height="16" Margin="0,0,0,8">
              <Border Background="#1e293b" CornerRadius="8"/>
              <Border x:Name="progressFill" Background="#38bdf8" CornerRadius="8" HorizontalAlignment="Left" Width="0"/>
            </Grid>
            <DockPanel Width="360" Margin="0,4,0,0">
              <TextBlock x:Name="txtProgressPct" Text="0%" Foreground="#e5e7eb" FontSize="12" FontWeight="Bold" DockPanel.Dock="Left"/>
              <TextBlock x:Name="txtProgressEta" Text="" Foreground="#8b98ab" FontSize="11" DockPanel.Dock="Right" HorizontalAlignment="Right"/>
            </DockPanel>
          </StackPanel>
          <Button x:Name="btnCancel" Content="Cancel" Width="120" Height="34" HorizontalAlignment="Center" VerticalAlignment="Bottom" Margin="0,0,0,20" Style="{StaticResource DarkBtn}" FontSize="12"/>
        </Grid>
      </Border>
    </Grid>

    <Grid x:Name="pnlResults" Grid.Row="1" Margin="26,6,26,6" Visibility="Collapsed">
      <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="*"/>
      </Grid.RowDefinitions>
      <Border Grid.Row="0" Background="#0f172a" CornerRadius="10" BorderBrush="#1e293b" BorderThickness="1">
        <StackPanel>
          <DockPanel Margin="12,12,12,6">
            <Button x:Name="btnBack" DockPanel.Dock="Left" Content="&lt; Back" Width="70" Height="32" Style="{StaticResource DarkBtn}"/>
            <StackPanel Orientation="Horizontal" Margin="10,0,0,0" VerticalAlignment="Center">
              <TextBlock Text="Scan Results   |" Foreground="#e5e7eb" FontSize="13" FontWeight="Bold"/>
              <TextBlock Text="[Log + Cache + Launcher]" Foreground="#4ade80" FontSize="13" FontWeight="Bold" Margin="6,0,0,0"/>
            </StackPanel>
          </DockPanel>
          <StackPanel Orientation="Horizontal" Margin="12,0,12,6">
            <Button x:Name="btnTabAcc" Content="Accounts Found" Width="140" Height="30" Style="{StaticResource DarkBtn}" FontWeight="Bold" FontSize="12"/>
            <Button x:Name="btnTabFor" Content="Forensics" Width="100" Height="30" Margin="6,0,0,0" Style="{StaticResource DarkBtn}" FontWeight="Bold" FontSize="12"/>
            <Button x:Name="btnTabJou" Content="Journal" Width="90" Height="30" Margin="6,0,0,0" Style="{StaticResource DarkBtn}" FontWeight="Bold" FontSize="12"/>
            <Border x:Name="boxSearch" Width="150" Height="30" Margin="10,0,0,0" Background="#16233a" BorderBrush="#1e293b" BorderThickness="1" CornerRadius="8">
              <Grid>
                <TextBlock x:Name="txtSearchPh" Text="Cerca nome" Foreground="#64748b" FontSize="12" VerticalAlignment="Center" Margin="8,0,0,0" IsHitTestVisible="False"/>
                <TextBox x:Name="txtSearch" Background="Transparent" BorderThickness="0" Foreground="#e5e7eb" FontSize="12" VerticalAlignment="Center" Margin="6,0,4,0" CaretBrush="#e5e7eb"/>
              </Grid>
            </Border>
          </StackPanel>
          <TextBlock x:Name="txtSearchWarn" Text="Nessun account trovato!" Foreground="#f87171" FontSize="10" Margin="12,0,12,10" Visibility="Collapsed"/>
        </StackPanel>
      </Border>
      <Border Grid.Row="1" Background="#0f172a" CornerRadius="10" BorderBrush="#1e293b" BorderThickness="1" Margin="0,8,0,0">
        <ScrollViewer VerticalScrollBarVisibility="Auto">
          <StackPanel x:Name="pnlContent" Margin="12"/>
        </ScrollViewer>
      </Border>
    </Grid>
    <TextBlock Grid.Row="2" Text="Made by CallMeDen_" Foreground="#8b98ab" FontSize="11" HorizontalAlignment="Right" Margin="0,6,28,12"/>
  </Grid>
</Window>
"@

$window = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml))
function C($name) { return $window.FindName($name) }

(C 'arrL').Text = [string][char]0x25B8
(C 'arrJ').Text = [string][char]0x25B8
(C 'arrC').Text = [string][char]0x25B8

function Show-Home {
  (C 'pnlResults').Visibility = [System.Windows.Visibility]::Collapsed
  (C 'pnlScan').Visibility = [System.Windows.Visibility]::Collapsed
  (C 'pnlHome').Visibility = [System.Windows.Visibility]::Visible
}

function Start-Spinner {
  $grid = C 'spinGrid'
  $rt = New-Object System.Windows.Media.RotateTransform
  $rt.Angle = 0
  $rt.CenterX = 35
  $rt.CenterY = 35
  $grid.RenderTransform = $rt
  $anim = New-Object System.Windows.Media.Animation.DoubleAnimation
  $anim.From = 0
  $anim.To = 360
  $anim.Duration = New-Object System.Windows.Duration([TimeSpan]::FromMilliseconds(900))
  $anim.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever
  $rt.BeginAnimation([System.Windows.Media.RotateTransform]::AngleProperty, $anim)
}

function Stop-Spinner {
  $grid = C 'spinGrid'
  if ($grid.RenderTransform -is [System.Windows.Media.RotateTransform]) {
    $grid.RenderTransform.BeginAnimation([System.Windows.Media.RotateTransform]::AngleProperty, $null)
  }
}

function Apply-ScanResults($data) {
  $script:accounts = New-Object System.Collections.Generic.List[string]
  $script:seen = New-Object System.Collections.Generic.HashSet[string]
  $script:sources = New-Object System.Collections.Generic.List[string]
  $script:nickPaths = New-Object 'System.Collections.Generic.Dictionary[string, System.Collections.Generic.List[string]]'
  foreach ($n in @($data['accounts'])) {
    if ($n) {
      $script:accounts.Add($n) | Out-Null
      $script:seen.Add($n.ToLower()) | Out-Null
    }
  }
  foreach ($s in @($data['sources'])) { $script:sources.Add($s) | Out-Null }
  $np = $data['nickPaths']
  if ($np) {
    foreach ($k in $np.Keys) {
      $lst = New-Object 'System.Collections.Generic.List[string]'
      foreach ($p in @($np[$k])) { if ($p) { $lst.Add($p) | Out-Null } }
      $script:nickPaths[$k] = $lst
    }
  }
}

function Reset-NickHighlight {
  foreach ($k in @($script:nickControls.Keys)) {
    $c = $script:nickControls[$k]
    if ($c -and $c.header) { $c.header.Background = [System.Windows.Media.Brushes]::Transparent }
  }
}

function Search-Account($term) {
  $t = $term.Trim()
  if (-not $t) { return $null }
  if ($script:currentTab -ne 'acc') { Show-Tab 'acc' }
  $key = $t.ToLower()
  $found = $null
  if ($script:nickControls.ContainsKey($key)) { $found = $key }
  if (-not $found) {
    foreach ($k in @($script:nickControls.Keys)) { if ($k.StartsWith($key)) { $found = $k; break } }
  }
  if (-not $found) {
    foreach ($k in @($script:nickControls.Keys)) { if ($k.Contains($key)) { $found = $k; break } }
  }
  if (-not $found) { return $null }
  Reset-NickHighlight
  $c = $script:nickControls[$found]
  if ($c) {
    $c.header.Background = Brush '#14532d'
    $c.detail.Visibility = [System.Windows.Visibility]::Visible
    $c.header.Text = ([string][char]0x25BC) + '  ' + $c.nick
    try { $c.header.BringIntoView() } catch { }
  }
  return $found
}

function Update-ProgressUI {
  $progressFile = Join-Path $env:TEMP 'coralmc_progress.txt'
  if (Test-Path -LiteralPath $progressFile) {
    try {
      $content = [System.IO.File]::ReadAllText($progressFile)
      $parts = $content -split '\|'
      if ($parts.Count -ge 5) {
        $pct = [int]$parts[0]
        $action = $parts[1]
        $processed = [int]$parts[2]
        $total = [int]$parts[3]
        $elapsed = [int]$parts[4]
        
        (C 'txtScanStatus').Text = $action
        (C 'txtProgressPct').Text = "$pct%"
        
        $maxWidth = 360.0
        $newWidth = ($pct / 100.0) * $maxWidth
        (C 'progressFill').Width = $newWidth
        
        if ($pct -gt 0 -and $pct -lt 100) {
          $remaining = ($elapsed / $pct) * (100 - $pct)
          $eta = [TimeSpan]::FromSeconds($remaining)
          $etaStr = ""
          if ($eta.TotalHours -ge 1) { $etaStr += "$([math]::Floor($eta.TotalHours))h " }
          if ($eta.Minutes -gt 0 -or $eta.TotalHours -ge 1) { $etaStr += "$($eta.Minutes)m " }
          $etaStr += "$($eta.Seconds)s"
          (C 'txtProgressEta').Text = "Tempo rimanente: $etaStr"
        } else {
          (C 'txtProgressEta').Text = ""
        }
      }
    } catch {}
  }
}

function Start-MinecraftScan {
  if ($script:scanJob) { return }
  (C 'pnlHome').Visibility = [System.Windows.Visibility]::Collapsed
  (C 'pnlResults').Visibility = [System.Windows.Visibility]::Collapsed
  (C 'pnlScan').Visibility = [System.Windows.Visibility]::Visible
  
  (C 'txtScanStatus').Text = 'Inizializzazione scansione...'
  (C 'txtProgressPct').Text = '0%'
  (C 'txtProgressEta').Text = ''
  (C 'progressFill').Width = 0
  
  $progressFile = Join-Path $env:TEMP 'coralmc_progress.txt'
  try { if (Test-Path -LiteralPath $progressFile) { Remove-Item -LiteralPath $progressFile -Force -ErrorAction SilentlyContinue } } catch {}

  Start-Spinner

  try {
    $script:scanJob = Start-Job -ScriptBlock ([scriptblock]::Create($script:scanCode))
  } catch {
    $script:scanJob = $null
  }

  if (-not $script:scanJob) {
    $data = $null
    try { $data = & ([scriptblock]::Create($script:scanCode)) } catch { $data = $null }
    Stop-Spinner
    (C 'pnlScan').Visibility = [System.Windows.Visibility]::Collapsed
    if ($data -and -not $data['error']) {
      Apply-ScanResults $data
      (C 'pnlResults').Visibility = [System.Windows.Visibility]::Visible
      Show-Tab 'acc'
    } else { Show-Home }
    return
  }

  $script:scanTimer = New-Object System.Windows.Threading.DispatcherTimer
  $script:scanTimer.Interval = [TimeSpan]::FromMilliseconds(200)
  $script:scanTimer.Add_Tick({
    $j = $script:scanJob
    if (-not $j) { $script:scanTimer.Stop(); return }
    
    Update-ProgressUI

    if ($j.State -eq 'Running') { return }
    $script:scanTimer.Stop()

    $data = $null
    try {
      if ($j.State -eq 'Completed') {
        $data = Receive-Job -Job $j
        if ($data -is [System.Management.Automation.PSObject]) { $data = $data.BaseObject }
        if ($data -and $data['error']) { $data = $null }
      }
    } catch { $data = $null }
    try { Remove-Job -Job $j -Force } catch { }
    $script:scanJob = $null

    if (-not $data) {
      try { $data = & ([scriptblock]::Create($script:scanCode)) } catch { $data = $null }
    }

    Stop-Spinner
    (C 'pnlScan').Visibility = [System.Windows.Visibility]::Collapsed
    if ($data -and -not $data['error']) {
      Apply-ScanResults $data
      (C 'pnlResults').Visibility = [System.Windows.Visibility]::Visible
      Show-Tab 'acc'
    } else {
      $msg = 'Errore durante la scansione.'
      if ($data -and $data['error']) { $msg += "`n" + [string]$data['error'] }
      [System.Windows.MessageBox]::Show($msg, 'Errore', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error) | Out-Null
      Show-Home
    }
  })
  $script:scanTimer.Start()
}

function Finish-Journal($data) {
  Stop-Spinner
  (C 'pnlScan').Visibility = [System.Windows.Visibility]::Collapsed
  $script:journalLines = New-Object System.Collections.Generic.List[string]
  $script:journalError = $null
  if ($data) {
    if ($data['error']) { $script:journalError = [string]$data['error'] }
    foreach ($l in @($data['lines'])) { if ($l) { $script:journalLines.Add($l) | Out-Null } }
  }
  (C 'pnlResults').Visibility = [System.Windows.Visibility]::Visible
  Show-Tab 'jou'
}

function Run-Journal {
  if ($script:journalJob) { return }
  (C 'pnlHome').Visibility = [System.Windows.Visibility]::Collapsed
  (C 'pnlResults').Visibility = [System.Windows.Visibility]::Collapsed
  (C 'pnlScan').Visibility = [System.Windows.Visibility]::Visible
  (C 'txtScanStatus').Text = 'Journal: lettura USN Journal di C: (consenti UAC, puo richiedere qualche minuto)...'
  (C 'txtProgressPct').Text = '0%'
  (C 'txtProgressEta').Text = ''
  (C 'progressFill').Width = 0
  Start-Spinner

  try {
    $script:journalJob = Start-Job -ScriptBlock ([scriptblock]::Create($script:journalCode))
  } catch {
    $script:journalJob = $null
  }

  if (-not $script:journalJob) {
    $data = $null
    try { $data = & ([scriptblock]::Create($script:journalCode)) } catch { $data = $null }
    Finish-Journal $data
    return
  }

  $script:journalTimer = New-Object System.Windows.Threading.DispatcherTimer
  $script:journalTimer.Interval = [TimeSpan]::FromMilliseconds(300)
  $script:journalTimer.Add_Tick({
    $j = $script:journalJob
    if (-not $j) { $script:journalTimer.Stop(); return }
    if ($j.State -eq 'Running') { return }
    $script:journalTimer.Stop()

    $data = $null
    try {
      if ($j.State -eq 'Completed') {
        $data = Receive-Job -Job $j
        if ($data -is [System.Management.Automation.PSObject]) { $data = $data.BaseObject }
      }
    } catch { $data = $null }
    try { Remove-Job -Job $j -Force } catch { }
    $script:journalJob = $null

    if (-not $data) {
      try { $data = & ([scriptblock]::Create($script:journalCode)) } catch { $data = $null }
    }
    Finish-Journal $data
  })
  $script:journalTimer.Start()
}

function Cancel-Scan {
  if ($script:scanTimer) { $script:scanTimer.Stop() }
  if ($script:journalTimer) { $script:journalTimer.Stop() }
  try { if ($script:scanJob) { Stop-Job -Job $script:scanJob | Out-Null; Remove-Job -Job $script:scanJob -Force } } catch { }
  try { if ($script:journalJob) { Stop-Job -Job $script:journalJob | Out-Null; Remove-Job -Job $script:journalJob -Force } } catch { }
  $script:scanJob = $null
  $script:journalJob = $null
  Stop-Spinner
  Show-Home
}

function Open-Cestino {
  try {
    Start-Process "C:\`$Recycle.Bin"
  } catch {
    Start-Process explorer "C:\`$Recycle.Bin"
  }
}

function Parse-JournalName($l) {
  $m = [regex]::Match($l, '"([^"]*(?:latest\.log|\.log\.gz|launcher_profiles\.json|usernamecache\.json|usercache\.json|shig\.inima|launcher_accounts\.json)[^"]*)"')
  if ($m.Success) { return $m.Groups[1].Value }
  $m2 = [regex]::Match($l, '([A-Za-z0-9_.\-]*(?:latest\.log|\.log\.gz|launcher_profiles\.json|usernamecache\.json|usercache\.json|shig\.inima|launcher_accounts\.json))')
  if ($m2.Success) { return $m2.Groups[1].Value }
  return $l.Trim()
}

function Parse-JournalCode($l) {
  $ms = [regex]::Matches($l, '[0-9a-fA-F]{16,}')
  if ($ms.Count -ge 2) { return $ms[1].Value }
  if ($ms.Count -eq 1) { return $ms[0].Value }
  return $null
}

function New-LogRow($path) {
  $dock = New-Object System.Windows.Controls.DockPanel
  $dock.Margin = '30,3,8,3'

  $btnCopy = New-Object System.Windows.Controls.Button
  $btnCopy.Content = 'Copy'
  $btnCopy.Width = 52; $btnCopy.Height = 24; $btnCopy.FontSize = 10
  $btnCopy.Style = $window.FindResource('DarkBtn')
  $btnCopy.Margin = '6,0,0,0'
  [System.Windows.Controls.DockPanel]::SetDock($btnCopy, [System.Windows.Controls.Dock]::Right)
  [void]$btnCopy.Add_Click(({
    try { [System.Windows.Clipboard]::SetText($path) } catch { }
  }).GetNewClosure())
  [void]$dock.Children.Add($btnCopy)

  $btnOpen = New-Object System.Windows.Controls.Button
  $btnOpen.Content = 'Open'
  $btnOpen.Width = 52; $btnOpen.Height = 24; $btnOpen.FontSize = 10
  $btnOpen.Style = $window.FindResource('DarkBtn')
  [System.Windows.Controls.DockPanel]::SetDock($btnOpen, [System.Windows.Controls.Dock]::Right)
  [void]$btnOpen.Add_Click(({
    try { Start-Process -LiteralPath $path }
    catch { try { Start-Process notepad.exe -ArgumentList "`"$path`"" } catch { } }
  }).GetNewClosure())
  [void]$dock.Children.Add($btnOpen)

  $left = New-Object System.Windows.Controls.StackPanel
  $left.Orientation = [System.Windows.Controls.Orientation]::Horizontal
  $left.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
  $lbl = New-Object System.Windows.Controls.TextBlock
  $lbl.Text = 'Source'; $lbl.Foreground = Brush '#64748b'; $lbl.FontSize = 11
  $sep = New-Object System.Windows.Controls.TextBlock
  $sep.Text = '  |  '; $sep.Foreground = Brush '#334155'; $sep.FontSize = 11
  $pth = New-Object System.Windows.Controls.TextBlock
  $pth.Text = $path; $pth.Foreground = Brush '#8b98ab'; $pth.FontSize = 11
  $pth.TextWrapping = [System.Windows.TextWrapping]::Wrap
  [void]$left.Children.Add($lbl); [void]$left.Children.Add($sep); [void]$left.Children.Add($pth)
  [void]$dock.Children.Add($left)

  $cm = New-Object System.Windows.Controls.ContextMenu
  $cm.Background = Brush '#0f172a'
  $cm.BorderBrush = Brush '#1e293b'
  $miCopy = New-Object System.Windows.Controls.MenuItem
  $miCopy.Header = 'Copia percorso'; $miCopy.Foreground = Brush '#e5e7eb'
  [void]$miCopy.Add_Click(({
    try { [System.Windows.Clipboard]::SetText($path) } catch { }
  }).GetNewClosure())
  $miOpen = New-Object System.Windows.Controls.MenuItem
  $miOpen.Header = 'Apri file'; $miOpen.Foreground = Brush '#e5e7eb'
  [void]$miOpen.Add_Click(({
    try { Start-Process -LiteralPath $path }
    catch { try { Start-Process notepad.exe -ArgumentList "`"$path`"" } catch { } }
  }).GetNewClosure())
  $miFolder = New-Object System.Windows.Controls.MenuItem
  $miFolder.Header = 'Apri cartella'; $miFolder.Foreground = Brush '#e5e7eb'
  [void]$miFolder.Add_Click(({
    try { Start-Process explorer.exe -ArgumentList "/select,`"$path`"" } catch { }
  }).GetNewClosure())
  [void]$cm.Items.Add($miCopy); [void]$cm.Items.Add($miOpen); [void]$cm.Items.Add($miFolder)

  [void]$dock.Add_MouseRightButtonUp(({
    $cm.PlacementTarget = $dock
    $cm.Placement = [System.Windows.Controls.Primitives.PlacementMode]::MousePoint
    $cm.IsOpen = $true
  }).GetNewClosure())

  return $dock
}

function Add-NickRow($nick, $panel) {
  $green = Brush '#4ade80'
  $key = $nick.ToLower()
  $paths = @()
  if ($script:nickPaths -and $script:nickPaths.ContainsKey($key)) { $paths = $script:nickPaths[$key] }

  $header = New-Object System.Windows.Controls.TextBlock
  $header.Text = ([string][char]0x25B8) + '  ' + $nick
  $header.Foreground = $green; $header.FontSize = 12; $header.Margin = '18,2,8,2'
  $header.Cursor = [System.Windows.Input.Cursors]::Hand

  $detail = New-Object System.Windows.Controls.StackPanel
  $detail.Margin = '26,0,8,6'
  $detail.Visibility = [System.Windows.Visibility]::Collapsed

  if (@($paths).Count -gt 0) {
    $pc = New-Object System.Windows.Controls.StackPanel
    $pc.Orientation = [System.Windows.Controls.Orientation]::Horizontal
    $pc.Margin = '30,6,8,2'
    $t1 = New-Object System.Windows.Controls.TextBlock
    $t1.Text = 'Persistence Check'; $t1.Foreground = Brush '#fbbf24'; $t1.FontSize = 11; $t1.FontWeight = [System.Windows.FontWeights]::Bold
    $t2 = New-Object System.Windows.Controls.TextBlock
    $t2.Text = '  (This username was found in the past on this PC)'; $t2.Foreground = Brush '#64748b'; $t2.FontSize = 10
    [void]$pc.Children.Add($t1); [void]$pc.Children.Add($t2)
    [void]$detail.Children.Add($pc)
    foreach ($p in @($paths)) {
      [void]$detail.Children.Add((New-LogRow $p))
    }
  }

  [void]$header.Add_MouseLeftButtonUp(({
    if ($detail.Visibility -eq [System.Windows.Visibility]::Visible) {
      $detail.Visibility = [System.Windows.Visibility]::Collapsed
      $header.Text = ([string][char]0x25B8) + '  ' + $nick
    } else {
      $detail.Visibility = [System.Windows.Visibility]::Visible
      $header.Text = ([string][char]0x25BC) + '  ' + $nick
    }
  }).GetNewClosure())

  $script:nickControls[$key] = @{ header = $header; detail = $detail; nick = $nick }

  [void]$panel.Children.Add($header)
  [void]$panel.Children.Add($detail)
}

function Show-Tab($which) {
  $script:currentTab = $which
  $accent = Brush '#38bdf8'; $darktxt = Brush '#04121f'; $btnbg = Brush '#16233a'
  $sub = Brush '#8b98ab'; $txt = Brush '#e5e7eb'
  $acc = C 'btnTabAcc'; $for = C 'btnTabFor'; $jou = C 'btnTabJou'
  foreach ($b in @($acc, $for, $jou)) { $b.Background = $btnbg; $b.Foreground = $sub }
  if ($which -eq 'acc') { $acc.Background = $accent; $acc.Foreground = $darktxt }
  elseif ($which -eq 'for') { $for.Background = $accent; $for.Foreground = $darktxt }
  else { $jou.Background = $accent; $jou.Foreground = $darktxt }

  $panel = C 'pnlContent'
  $panel.Children.Clear()

  if ($which -eq 'acc') {
    $script:nickControls = @{}
    $h = New-Object System.Windows.Controls.TextBlock
    $h.Text = ([string][char]0x25BC) + '   Accounts trovati:   (' + $script:accounts.Count + ')'
    $h.Foreground = $txt; $h.FontSize = 13; $h.FontWeight = [System.Windows.FontWeights]::Bold
    $h.Margin = '4,6,4,2'
    $panel.Children.Add($h) | Out-Null
    $hint = New-Object System.Windows.Controls.TextBlock
    $hint.Text = 'Click sinistro sul nick: espandi/comprimi  |  Click destro sul file: copia/apri'
    $hint.Foreground = Brush '#64748b'; $hint.FontSize = 10; $hint.Margin = '6,0,4,6'
    $panel.Children.Add($hint) | Out-Null
    if ($script:accounts.Count -eq 0) {
      $e = New-Object System.Windows.Controls.TextBlock
      $e.Text = 'Nessun account trovato nelle fonti scansionate.'
      $e.Foreground = $sub; $e.FontSize = 12; $e.Margin = '8,4,8,4'
      $panel.Children.Add($e) | Out-Null
    }
    foreach ($nick in $script:accounts) {
      Add-NickRow $nick $panel
    }
  }
  elseif ($which -eq 'for') {
    if ($script:sources.Count -eq 0) {
      $e = New-Object System.Windows.Controls.TextBlock
      $e.Text = 'Nessuna fonte trovata.'
      $e.Foreground = $sub; $e.FontSize = 12; $e.Margin = '8,4,8,4'
      $panel.Children.Add($e) | Out-Null
    }
    foreach ($s in $script:sources) {
      $row = New-Object System.Windows.Controls.TextBlock
      $row.Text = ([string][char]0x2714) + '  ' + $s
      $row.Foreground = $sub; $row.FontSize = 11; $row.Margin = '10,2,8,2'
      $panel.Children.Add($row) | Out-Null
    }
  }
  else {
    $h = New-Object System.Windows.Controls.TextBlock
    $h.Text = ([string][char]0x25BC) + '   Journal (file eliminati):   (' + $script:journalLines.Count + ')'
    $h.Foreground = $txt; $h.FontSize = 13; $h.FontWeight = [System.Windows.FontWeights]::Bold
    $h.Margin = '4,6,4,2'
    $panel.Children.Add($h) | Out-Null
    $hint = New-Object System.Windows.Controls.TextBlock
    $hint.Text = 'Click destro su un elemento per copiare il codice o la stringa completa.'
    $hint.Foreground = Brush '#64748b'; $hint.FontSize = 10; $hint.Margin = '6,0,4,6'
    $panel.Children.Add($hint) | Out-Null
    if ($script:journalLines.Count -eq 0) {
      $e = New-Object System.Windows.Controls.TextBlock
      if ($script:journalError) {
        $e.Text = 'Errore: ' + $script:journalError
      } else {
        $e.Text = 'Nessun file eliminato trovato. (Serve il consenso UAC/Amministratore.)'
      }
      $e.Foreground = $sub; $e.FontSize = 12; $e.Margin = '8,4,8,4'
      $e.TextWrapping = [System.Windows.TextWrapping]::Wrap
      $panel.Children.Add($e) | Out-Null
    }
    foreach ($l in $script:journalLines) {
      $name = Parse-JournalName $l
      $code = Parse-JournalCode $l
      $localCode = $code
      $localLine = $l

      $rowBorder = New-Object System.Windows.Controls.Border
      $rowBorder.Background = Brush '#131f33'
      $rowBorder.BorderBrush = Brush '#1e293b'
      $rowBorder.BorderThickness = '1'
      $rowBorder.CornerRadius = '8'
      $rowBorder.Margin = '10,4,8,4'
      $rowBorder.Padding = '10,8,10,8'
      
      $contentStack = New-Object System.Windows.Controls.StackPanel
      
      $nameText = New-Object System.Windows.Controls.TextBlock
      $nameText.Text = $name
      $nameText.Foreground = Brush '#f87171'
      $nameText.FontSize = 12
      $nameText.FontWeight = [System.Windows.FontWeights]::Bold
      $nameText.TextWrapping = [System.Windows.TextWrapping]::Wrap
      [void]$contentStack.Children.Add($nameText)
      
      if ($localCode) {
        $codeText = New-Object System.Windows.Controls.TextBlock
        $codeText.Text = "2° Codice Memoria: $localCode"
        $codeText.Foreground = Brush '#38bdf8'
        $codeText.FontSize = 11
        $codeText.FontWeight = [System.Windows.FontWeights]::SemiBold
        $codeText.Margin = '0,6,0,0'
        [void]$contentStack.Children.Add($codeText)
      }
      
      $rawText = New-Object System.Windows.Controls.TextBlock
      $rawText.Text = $localLine
      $rawText.Foreground = Brush '#8b98ab'
      $rawText.FontSize = 10
      $rawText.TextWrapping = [System.Windows.TextWrapping]::Wrap
      $rawText.Margin = '0,6,0,0'
      [void]$contentStack.Children.Add($rawText)
      
      $rowBorder.Child = $contentStack
      
      $cm = New-Object System.Windows.Controls.ContextMenu
      $cm.Background = Brush '#0f172a'
      $cm.BorderBrush = Brush '#1e293b'
      
      if ($localCode) {
        $miCopyCode = New-Object System.Windows.Controls.MenuItem
        $miCopyCode.Header = 'Copia 2° codice memoria'
        $miCopyCode.Foreground = Brush '#e5e7eb'
        [void]$miCopyCode.Add_Click(({
          try { [System.Windows.Clipboard]::SetText($localCode) } catch {}
        }).GetNewClosure())
        [void]$cm.Items.Add($miCopyCode)
      }
      
      $miCopyLine = New-Object System.Windows.Controls.MenuItem
      $miCopyLine.Header = 'Copia stringa completa'
      $miCopyLine.Foreground = Brush '#e5e7eb'
      [void]$miCopyLine.Add_Click(({
        try { [System.Windows.Clipboard]::SetText($localLine) } catch {}
      }).GetNewClosure())
      [void]$cm.Items.Add($miCopyLine)
      
      $rowBorder.ContextMenu = $cm
      
      $panel.Children.Add($rowBorder) | Out-Null
    }
  }
}

function Show-Info {
  [xml]$ix = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        Title="Info" Width="400" Height="280" Background="#0f172a"
        WindowStartupLocation="CenterOwner" ResizeMode="NoResize" FontFamily="Segoe UI">
  <StackPanel Margin="20">
    <TextBlock Text="CoralMC Alts Checker" Foreground="#38bdf8" FontSize="16" FontWeight="Bold" HorizontalAlignment="Center" Margin="0,10,0,8"/>
    <TextBlock Foreground="#8b98ab" FontSize="12" TextWrapping="Wrap" Text="Log 'Setting user:' (anche .gz), usernamecache, usercache, launcher_profiles/accounts, shig.inima e file eliminati via USN Journal. Con la grafica CoralMC."/>
    <TextBlock Text="Made by CallMeDen_" Foreground="#8b98ab" FontSize="11" HorizontalAlignment="Center" Margin="0,18,0,0"/>
  </StackPanel>
</Window>
"@
  $w = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $ix))
  $w.Owner = $window
  $w.ShowDialog() | Out-Null
}

# --- Ricerca "Cerca nome" ---
(C 'txtSearch').Add_TextChanged({
  param($s, $e)
  $ph = C 'txtSearchPh'; $box = C 'boxSearch'; $warn = C 'txtSearchWarn'
  $term = $s.Text
  if (-not $term -or -not $term.Trim()) {
    $ph.Visibility = [System.Windows.Visibility]::Visible
    $box.BorderBrush = Brush '#1e293b'
    $warn.Visibility = [System.Windows.Visibility]::Collapsed
    Reset-NickHighlight
    return
  }
  $ph.Visibility = [System.Windows.Visibility]::Collapsed
  $f = Search-Account $term
  if ($f) {
    $box.BorderBrush = Brush '#4ade80'
    $warn.Visibility = [System.Windows.Visibility]::Collapsed
  } else {
    $box.BorderBrush = Brush '#f87171'
    $warn.Visibility = [System.Windows.Visibility]::Visible
  }
})
(C 'txtSearch').Add_KeyDown({
  param($s, $e)
  if ($e.Key -eq [System.Windows.Input.Key]::Enter) {
    $term = $s.Text
    if ($term -and $term.Trim() -and -not (Search-Account $term)) {
      [System.Windows.MessageBox]::Show('Nessun account trovato!', 'Cerca nome', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning) | Out-Null
    }
    $e.Handled = $true
  }
})

(C 'btnInfo').Add_Click({ Show-Info })
(C 'rowLogs').Add_MouseLeftButtonUp({ Start-MinecraftScan })
(C 'btnAnalyze').Add_Click({ Start-MinecraftScan })
(C 'rowJournal').Add_MouseLeftButtonUp({ Run-Journal })
(C 'rowCestino').Add_MouseLeftButtonUp({ Open-Cestino })
(C 'btnCancel').Add_Click({ Cancel-Scan })
(C 'btnBack').Add_Click({ Show-Home })
(C 'btnTabAcc').Add_Click({ Show-Tab 'acc' })
(C 'btnTabFor').Add_Click({ Show-Tab 'for' })
(C 'btnTabJou').Add_Click({ Show-Tab 'jou' })
$window.Add_Closed({
  try { if ($script:scanJob) { Remove-Job -Job $script:scanJob -Force } } catch { }
  try { if ($script:journalJob) { Remove-Job -Job $script:journalJob -Force } } catch { }
  try { if ($script:scanTimer) { $script:scanTimer.Stop() } } catch { }
  try { if ($script:journalTimer) { $script:journalTimer.Stop() } } catch { }
})

$window.ShowDialog() | Out-Null
