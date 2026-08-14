Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

$script:accounts = New-Object System.Collections.Generic.List[string]
$script:seen = New-Object System.Collections.Generic.HashSet[string]
$script:sources = New-Object System.Collections.Generic.List[string]
$script:nickPaths = New-Object 'System.Collections.Generic.Dictionary[string, System.Collections.Generic.List[string]]'

function Brush($hex) { return (New-Object System.Windows.Media.BrushConverter).ConvertFromString($hex) }

function Read-TextFile($path) {
  try { return [System.IO.File]::ReadAllText($path) } catch { return $null }
}

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

function Invoke-Scan {
  $script:accounts = New-Object System.Collections.Generic.List[string]
  $script:seen = New-Object System.Collections.Generic.HashSet[string]
  $script:sources = New-Object System.Collections.Generic.List[string]
  $script:nickPaths = New-Object 'System.Collections.Generic.Dictionary[string, System.Collections.Generic.List[string]]'
  $mc = Join-Path $env:APPDATA '.minecraft'
  $logsDir = Join-Path $mc 'logs'

  if (Test-Path -LiteralPath $logsDir) {
    $files = @(Get-ChildItem -LiteralPath $logsDir -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '\.log$' -or $_.Name -match '\.log\.gz$' })
    foreach ($f in $files) {
      $script:sources.Add($f.FullName) | Out-Null
      $text = if ($f.Name.EndsWith('.gz')) { Read-GzFile $f.FullName } else { Read-TextFile $f.FullName }
      if ($text) {
        $ms = [regex]::Matches($text, '(?m)Setting user:\s*(\S+)')
        foreach ($m in $ms) {
          $nick = $m.Groups[1].Value.Trim()
          $key = $nick.ToLower()
          if ($nick -and $script:seen.Add($key)) {
            $script:accounts.Add($nick) | Out-Null
          }
          if ($nick) {
            if (-not $script:nickPaths.ContainsKey($key)) {
              $script:nickPaths[$key] = New-Object 'System.Collections.Generic.List[string]'
            }
            if (-not $script:nickPaths[$key].Contains($f.FullName)) {
              $script:nickPaths[$key].Add($f.FullName) | Out-Null
            }
          }
        }
      }
    }
  }
}

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
            <TextBlock Text="Scansione esclusiva dei 'Setting user:' nei log di Minecraft." Foreground="#8b98ab" FontSize="12" Margin="0,2,0,14"/>
            <Border x:Name="rowLogs" Background="#131f33" CornerRadius="10" BorderBrush="#1e293b" BorderThickness="1" Margin="0,0,0,10" Cursor="Hand">
              <DockPanel Margin="12">
                <Border DockPanel.Dock="Left" Width="38" Height="38" CornerRadius="19" Background="#173049">
                  <TextBlock Text="L" Foreground="#38bdf8" FontSize="15" FontWeight="Bold" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                </Border>
                <TextBlock x:Name="arrL" DockPanel.Dock="Right" Text=">" Foreground="#8b98ab" FontSize="14" VerticalAlignment="Center" Margin="14,0,4,0"/>
                <StackPanel Margin="12,0,0,0" VerticalAlignment="Center">
                  <TextBlock Text="LOGS DI MINECRAFT" Foreground="#e5e7eb" FontSize="13" FontWeight="Bold"/>
                  <TextBlock Text="Cerca tutti i 'Setting user:' (anche nei .gz)" Foreground="#8b98ab" FontSize="11"/>
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
                  <TextBlock Text="Apre CMD (Admin) con lettura USN journal + export logs.txt" Foreground="#8b98ab" FontSize="11"/>
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
              <TextBlock Text="[Setting user only]" Foreground="#4ade80" FontSize="13" FontWeight="Bold" Margin="6,0,0,0"/>
            </StackPanel>
          </DockPanel>
          <StackPanel Orientation="Horizontal" Margin="12,0,12,12">
            <Button x:Name="btnTabAcc" Content="Accounts Found" Width="140" Height="30" Style="{StaticResource DarkBtn}" FontWeight="Bold" FontSize="12"/>
            <Button x:Name="btnTabFor" Content="Forensics" Width="100" Height="30" Margin="6,0,0,0" Style="{StaticResource DarkBtn}" FontWeight="Bold" FontSize="12"/>
          </StackPanel>
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
  (C 'pnlHome').Visibility = [System.Windows.Visibility]::Visible
}

function New-PathRow($path) {
  $tb = New-Object System.Windows.Controls.TextBlock
  $tb.Text = ([string][char]0x2022) + '  ' + $path
  $tb.Foreground = Brush '#8b98ab'
  $tb.FontSize = 11
  $tb.Margin = '34,3,8,3'
  $tb.TextWrapping = [System.Windows.TextWrapping]::Wrap
  $tb.Cursor = [System.Windows.Input.Cursors]::Hand

  $cm = New-Object System.Windows.Controls.ContextMenu
  $cm.Background = Brush '#0f172a'
  $cm.BorderBrush = Brush '#1e293b'

  $miCopy = New-Object System.Windows.Controls.MenuItem
  $miCopy.Header = 'Copia percorso'
  $miCopy.Foreground = Brush '#e5e7eb'
  [void]$miCopy.Add_Click({
    try { [System.Windows.Clipboard]::SetText($path) } catch { }
  })

  $miOpen = New-Object System.Windows.Controls.MenuItem
  $miOpen.Header = 'Apri file'
  $miOpen.Foreground = Brush '#e5e7eb'
  [void]$miOpen.Add_Click({
    try { Start-Process -LiteralPath $path }
    catch {
      try { Start-Process notepad.exe -ArgumentList "`"$path`"" } catch { }
    }
  })

  $miFolder = New-Object System.Windows.Controls.MenuItem
  $miFolder.Header = 'Apri cartella'
  $miFolder.Foreground = Brush '#e5e7eb'
  [void]$miFolder.Add_Click({
    try { Start-Process explorer.exe -ArgumentList "/select,`"$path`"" } catch { }
  })

  [void]$cm.Items.Add($miCopy)
  [void]$cm.Items.Add($miOpen)
  [void]$cm.Items.Add($miFolder)
  $tb.ContextMenu = $cm

  return $tb
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
  $detail.Margin = '12,0,8,4'
  $detail.Visibility = [System.Windows.Visibility]::Collapsed
  foreach ($p in $paths) {
    [void]$detail.Children.Add((New-PathRow $p))
  }

  [void]$header.Add_MouseLeftButtonUp({
    if ($detail.Visibility -eq [System.Windows.Visibility]::Visible) {
      $detail.Visibility = [System.Windows.Visibility]::Collapsed
      $header.Text = ([string][char]0x25B8) + '  ' + $nick
    } else {
      $detail.Visibility = [System.Windows.Visibility]::Visible
      $header.Text = ([string][char]0x25BC) + '  ' + $nick
    }
  })

  [void]$panel.Children.Add($header)
  [void]$panel.Children.Add($detail)
}

function Show-Tab($which) {
  $accent = Brush '#38bdf8'; $darktxt = Brush '#04121f'; $btnbg = Brush '#16233a'
  $sub = Brush '#8b98ab'; $green = Brush '#4ade80'; $txt = Brush '#e5e7eb'
  $acc = C 'btnTabAcc'; $for = C 'btnTabFor'
  if ($which -eq 'acc') {
    $acc.Background = $accent; $acc.Foreground = $darktxt
    $for.Background = $btnbg; $for.Foreground = $sub
  } else {
    $for.Background = $accent; $for.Foreground = $darktxt
    $acc.Background = $btnbg; $acc.Foreground = $sub
  }
  $panel = C 'pnlContent'
  $panel.Children.Clear()
  if ($which -eq 'acc') {
    $h = New-Object System.Windows.Controls.TextBlock
    $h.Text = ([string][char]0x25BC) + '   Setting user:   (' + $script:accounts.Count + ')'
    $h.Foreground = $txt; $h.FontSize = 13; $h.FontWeight = [System.Windows.FontWeights]::Bold
    $h.Margin = '4,6,4,2'
    $panel.Children.Add($h) | Out-Null
    $hint = New-Object System.Windows.Controls.TextBlock
    $hint.Text = 'Click sinistro sul nick: espandi/comprimi  |  Click destro sul log: copia/apri'
    $hint.Foreground = Brush '#64748b'; $hint.FontSize = 10; $hint.Margin = '6,0,4,6'
    $panel.Children.Add($hint) | Out-Null
    if ($script:accounts.Count -eq 0) {
      $e = New-Object System.Windows.Controls.TextBlock
      $e.Text = 'Nessun Setting user trovato nei log.'
      $e.Foreground = $sub; $e.FontSize = 12; $e.Margin = '8,4,8,4'
      $panel.Children.Add($e) | Out-Null
    }
    foreach ($nick in $script:accounts) {
      Add-NickRow $nick $panel
    }
  } else {
    if ($script:sources.Count -eq 0) {
      $e = New-Object System.Windows.Controls.TextBlock
      $e.Text = 'Nessun file di log trovato.'
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
}

function Run-Analysis {
  Invoke-Scan
  (C 'pnlHome').Visibility = [System.Windows.Visibility]::Collapsed
  (C 'pnlResults').Visibility = [System.Windows.Visibility]::Visible
  Show-Tab 'acc'
}

function Run-Journal {
  $cmd = 'fsutil usn readjournal C: csv | findstr /i /C:"0x80000200" | findstr /i /C:"latest.log" /i /C:".log.gz" /i /C:"launcher_profiles.json" /i /C:"usernamecache.json" /i /C:"usercache.json" /i /C:"shig.inima" /i /C:"launcher_accounts.json" > logs.txt'
  try {
    Start-Process cmd -Verb RunAs -ArgumentList "/k", $cmd
  } catch {
    [System.Windows.MessageBox]::Show("Impossibile avviare CMD come amministratore: $($_.Exception.Message)", "Errore", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error) | Out-Null
  }
}

function Open-Cestino {
  try {
    Start-Process "C:\`$Recycle.Bin"
  } catch {
    Start-Process explorer "C:\`$Recycle.Bin"
  }
}

function Show-Info {
  [xml]$ix = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        Title="Info" Width="380" Height="260" Background="#0f172a"
        WindowStartupLocation="CenterOwner" ResizeMode="NoResize" FontFamily="Segoe UI">
  <StackPanel Margin="20">
    <TextBlock Text="CoralMC Alts Checker" Foreground="#38bdf8" FontSize="16" FontWeight="Bold" HorizontalAlignment="Center" Margin="0,10,0,8"/>
    <TextBlock Foreground="#8b98ab" FontSize="12" TextWrapping="Wrap" Text="Scansiona SOLO le righe 'Setting user:' nei log di Minecraft (anche .gz). Ignora cache, launcher e chat."/>
    <TextBlock Text="Made by CallMeDen_" Foreground="#8b98ab" FontSize="11" HorizontalAlignment="Center" Margin="0,18,0,0"/>
  </StackPanel>
</Window>
"@
  $w = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $ix))
  $w.Owner = $window
  $w.ShowDialog() | Out-Null
}

(C 'btnInfo').Add_Click({ Show-Info })
(C 'rowLogs').Add_MouseLeftButtonUp({ Run-Analysis })
(C 'btnAnalyze').Add_Click({ Run-Analysis })
(C 'rowJournal').Add_MouseLeftButtonUp({ Run-Journal })
(C 'rowCestino').Add_MouseLeftButtonUp({ Open-Cestino })
(C 'btnBack').Add_Click({ Show-Home })
(C 'btnTabAcc').Add_Click({ Show-Tab 'acc' })
(C 'btnTabFor').Add_Click({ Show-Tab 'for' })

$window.ShowDialog() | Out-Null
