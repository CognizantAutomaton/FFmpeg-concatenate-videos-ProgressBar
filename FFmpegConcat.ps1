$ErrorActionPreference = "Stop"

# create a synchronized hash table for cross-thread storage safety
$Sync = [Hashtable]::Synchronized(@{
    ffmpeg = "C:\Program Files\ImageMagick-7.1.0-Q16-HDRI\ffmpeg.exe"
    UserStop = $false
})

#region GUI
[Xml]$XAML = @"
<Window x:Class="YourNamespace.YourWindow"
        xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="ffmpeg video concat" Height="300" Width="450" ResizeMode="NoResize"
        Background="#101524" Foreground="#00B360">
    <Grid>
        <Grid.RowDefinitions>
            <RowDefinition Height="*" />
            <RowDefinition Height="30" />
        </Grid.RowDefinitions>
        <Grid Grid.Row="0">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*" />
                <ColumnDefinition Width="Auto" />
            </Grid.ColumnDefinitions>
            <Grid.RowDefinitions>
                <RowDefinition Height="*" />
                <RowDefinition Height="Auto" />
            </Grid.RowDefinitions>

            <!-- ListBox -->
            <ListBox x:Name="lstbox" Grid.Column="0" Grid.Row="0" Margin="5" Background="#0C101C" Foreground="#00B360">
                <!-- Add your ListBox items here -->
            </ListBox>

            <!-- Buttons -->
            <StackPanel Grid.Column="1" Grid.Row="0" Orientation="Vertical" Margin="5">
                <Button x:Name="btnAdd" Content="Add" Width="50" Background="#0C101C" Foreground="#00B360" Margin="0,0,0,5"/>
                <Button x:Name="btnRemove" Content="Remove" Width="50" Background="#0C101C" Foreground="#00B360" Margin="0,0,0,5"/>
                <Separator Margin="0,5"/>
                <Button x:Name="btnUp" Content="Up" Width="50" Background="#0C101C" Foreground="#00B360" Margin="0,0,0,5"/>
                <Button x:Name="btnDown" Content="Down" Width="50" Background="#0C101C" Foreground="#00B360" Margin="0,0,0,5"/>
            </StackPanel>

            <!-- Submit Button -->
            <Button x:Name="btnConcat" Content="Start" Grid.Row="1" HorizontalAlignment="Center" Background="#0C101C" Foreground="#00B360" Margin="5"/>
            <Button x:Name="btnStop" Content="Stop" IsEnabled="False" Grid.ColumnSpan="2" Grid.Row="1" HorizontalAlignment="Center" Background="#0C101C" Foreground="#00B360" Margin="5"/>
        </Grid>
        <!-- Progress Bar -->
        <Grid Grid.Row="1">
            <ProgressBar x:Name="Progress" Minimum="0" Maximum="100" Margin="5,0,5,5" HorizontalAlignment="Stretch" Foreground="Purple" VerticalAlignment="Stretch" Background="#0C101C" />
            <TextBlock x:Name="txtProgress" Text="" HorizontalAlignment="Center" VerticalAlignment="Center" Foreground="Silver"/>
        </Grid>
    </Grid>
</Window>
"@

$XAML.Window.RemoveAttribute('x:Class')
$XAML.Window.RemoveAttribute('mc:Ignorable')

$WpfNs = New-Object -TypeName Xml.XmlNamespaceManager -ArgumentList $XAML.NameTable
$WpfNs.AddNamespace('x', $XAML.DocumentElement.x)
$WpfNs.AddNamespace('d', $XAML.DocumentElement.d)
$WpfNs.AddNamespace('mc', $XAML.DocumentElement.mc)

# Read XAML markup
try {
    $Sync.Window = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $XAML))
} catch {
    Write-Host $_ -ForegroundColor Red
    Exit
}

# provide a reference to each GUI form control
$Sync.Gui = @{}
$XAML.SelectNodes('//*[@x:Name]', $WpfNs) | ForEach-Object {
    $Sync.Gui.Add($_.Name, $Sync.Window.FindName($_.Name))
}
#endregion

#region list source
# observable collection allows us to easily update listbox at runtime
$Sync.InputFiles = New-Object System.Collections.ObjectModel.ObservableCollection[string]
$Sync.Gui.lstbox.ItemsSource = $Sync.InputFiles

$Sync.UpdateProgress = [scriptblock]{
    param(
        [int]$Value,
        [string]$Text
    )

    $Sync.Window.Dispatcher.Invoke([Action]{
        $Sync.Gui.Progress.Value = $Value
        $Sync.Gui.txtProgress.Text = $Text
    }, "Normal")
}
#endregion

#region form events
$Sync.Gui.btnDown.add_Click({
    $idx = $Sync.Gui.lstbox.SelectedIndex

    if (($idx -ge 0) -and ($idx -lt ($Sync.InputFiles.Count - 1))) {
        # swap down
        $temp = $Sync.InputFiles[$idx]
        $Sync.InputFiles[$idx] = $Sync.InputFiles[$idx+1]
        $Sync.InputFiles[$idx+1] = $temp

        # set new selected index
        $Sync.Gui.lstbox.SelectedIndex = $idx + 1
    }
})

$Sync.Gui.btnUp.add_Click({
    $idx = $Sync.Gui.lstbox.SelectedIndex

    if ($idx -gt 0) {
        # swap up
        $temp = $Sync.InputFiles[$idx]
        $Sync.InputFiles[$idx] = $Sync.InputFiles[$idx-1]
        $Sync.InputFiles[$idx-1] = $temp

        # set new selected index
        $Sync.Gui.lstbox.SelectedIndex = $idx - 1
    }
})

$Sync.Gui.btnAdd.add_Click({
    $ofd = New-Object Microsoft.Win32.OpenFileDialog -Property @{
        Multiselect = $true
        Filter = "All files (*.*)|*.*"
    }

    if ($ofd.ShowDialog()) {
        foreach ($filename in $ofd.FileNames) {
            $Sync.InputFiles.Add($filename)
        }

        $Sync.Gui.lstbox.SelectedIndex = $Sync.InputFiles.Count - 1
    }
})

$Sync.Gui.btnRemove.add_Click({
    if (($Sync.InputFiles.Count -gt 0) -and ($Sync.Gui.lstbox.SelectedIndex -ge 0)) {
        $Sync.InputFiles.RemoveAt($Sync.Gui.lstbox.SelectedIndex)
    }
})

$Sync.Gui.btnStop.add_Click({
    $Sync.UserStop = $true
})

$Sync.Gui.btnConcat.add_Click({
    if ($Sync.InputFiles.Count -gt 0) {
        # instantiate SaveFileDialog
        $sfd = New-Object System.Windows.Forms.SaveFileDialog -Property @{
            Filter = "All files (*.*)|*.*"
            FileName = "output.mov"
        }

        if ($sfd.ShowDialog()) {
            # this is where the magic happens
            Start-ThreadJob -ArgumentList @($Sync, $sfd.FileName) -ScriptBlock {
                param(
                    [Hashtable]$Sync,
                    [string]$OutputFile
                )

                $ErrorActionPreference = "Stop"

                try {
                    [string]$Inputs = ($Sync.InputFiles | ForEach-Object { "-i `"$_`"" }) -join " "
                    [string]$FilterComplex = "-filter_complex `"$((@(0..($Sync.InputFiles.Count-1)) | ForEach-Object { "[$_`:v] [$_`:a]" }) -join " ") concat=n=$($Sync.InputFiles.Count):v=1:a=1 [v] [a]`""

                    # build pirate arguments for ffmpeg
                    [Array]$arrgs = @(
                        $Inputs,
                        $FilterComplex,
                        "-map `"[v]`"",
                        "-map `"[a]`"",
                        "-c:v libx264 -c:a aac",
                        "`"$OutputFile`""
                    )

                    # create the ProcessInfo for ffmpeg so that we do not show the output window
                    $pInfo = New-Object System.Diagnostics.ProcessStartInfo -Property @{
                        FileName = $Sync.ffmpeg
                        RedirectStandardError = $true
                        RedirectStandardOutput = $true
                        UseShellExecute = $false
                        Arguments = ($arrgs -join " ")
                    }

                    # create the process
                    $p = New-Object System.Diagnostics.Process -Property @{
                        StartInfo = $pInfo
                    }

                    # subscribe to the ErrorDataReceived event for updating progress
                    Register-ObjectEvent -InputObject $p -Event "ErrorDataReceived" -Action {
                        param(
                            [object]$sender,
                            [System.Diagnostics.DataReceivedEventArgs]$e
                        )
                        [string]$stderr = $e.Data
                        [string]$ts = [string]::Empty
                        [int]$pcnt = 0
                        [int]$idx = 0

                        if ($stderr.StartsWith("frame")) {
                            # extract timestamp
                            $idx = $stderr.IndexOf("time=")
                            $ts = $stderr.Substring($idx+5, $stderr.IndexOf(" ", $idx) - $idx - 5)

                            # calculate percent
                            $pcnt = [int][math]::round(($ts -as [TimeSpan]).TotalSeconds * 1.0 / $Sync.duration * 100)

                            # update progress
                            $Sync.UpdateProgress.Invoke($pcnt, "ffmpeg $pcnt% ($ts of $([TimeSpan]::FromSeconds($Sync.duration)))")
                        } elseif ($stderr.Trim().StartsWith("Duration")) {
                            # handle duration output from ffmpeg
                            $idx = $stderr.IndexOf(":")
                            $ts = $stderr.Substring($idx+1, $stderr.IndexOf(",") - $idx - 1)

                            # calculate total duration as the sum of all inputs
                            $Sync.duration += ($ts -as [TimeSpan]).TotalSeconds
                        }
                    }

                    # initialize progress state
                    $Sync.UpdateProgress.Invoke(0, ([string]::Empty))
                    $Sync.duration = 0
                    $Sync.Window.Dispatcher.Invoke([Action]{
                        $Sync.Gui.btnStop.IsEnabled = $true
                    }, "Normal")

                    # start ffmpeg
                    [void]$p.Start()

                    # invoke ErrorDataReceived event for reading asychronously
                    $p.BeginErrorReadLine()

                    # keep the thread waiting while process is running
                    while (-not $p.HasExited) {
                        if ($Sync.UserStop) {
                            $Sync.UserStop = $false

                            $p.Kill($true)

                            Remove-Item -LiteralPath $OutputFile
                        }

                        Start-Sleep -Milliseconds 250
                    }

                    $p.WaitForExit()
                } catch {
                    Write-Host $_
                }

                $Sync.Window.Dispatcher.Invoke([Action]{
                    $Sync.Gui.btnStop.IsEnabled = $false
                }, "Normal")
            }
        }
    } else {
        Write-Host "No inputs specified" -ForegroundColor Red
    }
})
#endregion

[void]$Sync.Window.ShowDialog()
