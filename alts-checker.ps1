Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

$script:accounts = New-Object System.Collections.Generic.List[string]
$script:seen = New-Object System.Collections.Generic.HashSet[string]
$script:sources = New-Object System.Collections.Generic.List[string]
$script:nickPaths = New-Object 'System.Collections.Generic.Dictionary[string, System.Collections.Generic.List[string]]'
$script:scanJob = $null
$script:scanTimer = $null

function Brush($hex) { return (New-Object System.Windows.Media.BrushConverter).ConvertFromString($hex) }

$script:scanCode = @'
try {
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
  $accounts = New-Object System.Collections.Generic.List[string]
  $seen = New-Object System.Collections.Generic.HashSet[string]
  $sources = New-Object System.Collections.Generic.List[string]
  $nickPaths = New-Object 'System.Collections.Generic.Dictionary[string, System.Collections.Generic.List[string]]'
  $mc = Join-Path $env:APPDATA '.minecraft'
  $logsDir = Join-Path $mc 'logs'
  if (Test-Path -LiteralPath $logsDir) {
    $files = @(Get-ChildItem -LiteralPath $logsDir -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '\.log$' -or $_.Name -match '\.log\.gz$' })
    foreach ($f in $files) {
      $sources.Add($f.FullName) | Out-Null
      $text = if ($f.Name.EndsWith('.gz')) { Read-GzFile $f.FullName } else { Read-TextFile $f.FullName }
      if ($text) {
        $ms = [regex]::Matches($text, '(?m)Setting user:\s*(\S+)')
        foreach ($m in $ms) {
          $nick = $m.Groups[1].Value.Trim()
          $key = $nick.ToLower()
          if ($nick -and $seen.Add($key)) { $accounts.Add($nick) | Out-Null }
          if ($nick) {
            if (-not $nickPaths.ContainsKey($key)) { $nickPaths[$key] = New-Object 'System.Collections.Generic.List[string]' }
            if (-not $nickPaths[$key].Contains($f.FullName)) { $nickPaths[$key].Add($f.FullName) | Out-Null }
          }
        }
      }
    }
  }
  $np = @{}
  foreach ($k in $nickPaths.Keys) { $np[$k] = @($nickPaths[$k]) }
  @{ accounts = @($accounts); sources = @($sources); nickPaths = $np; error = $null }
} catch {
  @{ accounts = @(); sources = @(); nickPaths = @{}; error = "$($_.Exception.Message)" }
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
                  <TextBlock Text="Esegue il comando USN journal nella console di avvio" Foreground="#8b98ab" FontSize="11"/>
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
          <StackPanel HorizontalAlignment="Center" VerticalAlignment="Center">
            <Grid x:Name="spinGrid" Width="70" Height="70" HorizontalAlignment="Center">
              <Ellipse Width="70" Height="70" Stroke="#38bdf8" StrokeThickness="6" StrokeDashArray="165 55" StrokeStartLineCap="Round" StrokeEndLineCap="Round" Fill="Transparent"/>
            </Grid>
            <TextBlock x:Name="txtScanStatus" Text="Minecraft Scan: cartella logs..." Foreground="#8b98ab" FontSize="12" HorizontalAlignment="Center" Margin="0,18,0,0"/>
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
  (C 'pnlScan').Visibility = [System.Windows.Visibility]::Collapsed
  (C 'pnlHome').Visibility = [System.Windows.Visibility]::Visible
}

function Start-Spinner {
  $grid = C 'spinGrid'
  $grid.RenderTransform = New-Object System.Windows.Media.RotateTransform(0, 35, 35)
  $anim = New-Object System.Windows.Media.Animation.DoubleAnimation(0, 360, [TimeSpan]::FromMilliseconds(900))
  $anim.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever
  $grid.RenderTransform.BeginAnimation([System.Windows.Media.RotateTransform]::AngleProperty, $anim)
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

function Start-MinecraftScan {
  if ($script:scanJob) { return }
  (C 'pnlHome').Visibility = [System.Windows.Visibility]::Collapsed
  (C 'pnlResults').Visibility = [System.Windows.Visibility]::Collapsed
  (C 'pnlScan').Visibility = [System.Windows.Visibility]::Visible
  (C 'txtScanStatus').Text = 'Minecraft Scan: cartella logs (%APPDATA%\.minecraft\logs)...'
  Start-Spinner

  try {
    $script:scanJob = Start-Job -ScriptBlock ([scriptblock]::Create($script:scanCode))
  } catch {
    $script:scanJob = $null
  }

  if (-not $script:scanJob) {
    # Fallback sincrono immediato
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
      $msg = 'Errore durante la scansione dei log.'
      if ($data -and $data['error']) { $msg += "`n" + [string]$data['error'] }
      [System.Windows.MessageBox]::Show($msg, 'Errore', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error) | Out-Null
      Show-Home
    }
  })
  $script:scanTimer.Start()
}

function Cancel-Scan {
  if ($script:scanTimer) { $script:scanTimer.Stop() }
  try { if ($script:scanJob) { Stop-Job -Job $script:scanJob | Out-Null; Remove-Job -Job $script:scanJob -Force } } catch { }
  $script:scanJob = $null
  Stop-Spinner
  Show-Home
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
  $lbl.Text = 'Log File'; $lbl.Foreground = Brush '#64748b'; $lbl.FontSize = 11
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

  [void]$panel.Children.Add($header)
  [void]$panel.Children.Add($detail)
}

function Show-Tab($which) {
  $accent = Brush '#38bdf8'; $darktxt = Brush '#04121f'; $btnbg = Brush '#16233a'
  $sub = Brush '#8b98ab'; $txt = Brush '#e5e7eb'
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

function Run-Journal {
  $cmd = 'fsutil usn readjournal C: csv | findstr /i /C:"0x80000200" | findstr /i /C:"latest.log" /i /C:".log.gz" /i /C:"launcher_profiles.json" /i /C:"usernamecache.json" /i /C:"usercache.json" /i /C:"shig.inima" /i /C:"launcher_accounts.json" > logs.txt'
  try {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'cmd.exe'
    $psi.Arguments = '/k ' + $cmd
    $psi.UseShellExecute = $false
    $psi.WorkingDirectory = [Environment]::GetFolderPath('Desktop')
    [void][System.Diagnostics.Process]::Start($psi)
  } catch {
    [System.Windows.MessageBox]::Show("Impossibile eseguire il comando Journal: $($_.Exception.Message)", "Errore", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error) | Out-Null
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
(C 'rowLogs').Add_MouseLeftButtonUp({ Start-MinecraftScan })
(C 'btnAnalyze').Add_Click({ Start-MinecraftScan })
(C 'btnCancel').Add_Click({ Cancel-Scan })
(C 'rowJournal').Add_MouseLeftButtonUp({ Run-Journal })
(C 'rowCestino').Add_MouseLeftButtonUp({ Open-Cestino })
(C 'btnBack').Add_Click({ Show-Home })
(C 'btnTabAcc').Add_Click({ Show-Tab 'acc' })
(C 'btnTabFor').Add_Click({ Show-Tab 'for' })
$window.Add_Closed({ try { if ($script:scanJob) { Remove-Job -Job $script:scanJob -Force } } catch { } })

$window.ShowDialog() | Out-Null
