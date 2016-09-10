#
# Zips the specified folder  
# returns either the path or the contents of the zip files based on the returnvalue parameterer
# When using the contents, Use set-content to create a zip file from it.
# on the specified session, if the session is not specified
# a session to the local machine will be used
# 
#
function Get-FolderAsZip
{
    [CmdletBinding()]
    param(

        [string]$sourceFolder,
        [string] $destinationPath,
        [System.Management.Automation.Runspaces.PSSession] $Session,
        [ValidateSet('Path','Content')]
        [string] $ReturnValue = 'Path',
        [string] $filename
    )

    $local = $false
    $invokeCommandParams = @{}
    if($Session)
    {
        $invokeCommandParams.Add('Session',$Session);
    }
    else
    {
        $local = $true
    }

    $attempts =0 
    $gotZip = $false
    while($attempts -lt 5 -and !$gotZip)
    {
        $attempts++
        $resultTable = invoke-command -ErrorAction:Continue @invokeCommandParams -script {
                param($logFolder, $destinationPath, $fileName, $ReturnValue)
                $ErrorActionPreference = 'stop'
                Set-StrictMode -Version latest


                $tempPath = Join-path $env:temp ([system.io.path]::GetRandomFileName())
                if(!(Test-Path $tempPath))
                {
                    mkdir $tempPath > $null
                }
                
                $sourcePath = Join-path $logFolder '*'
                Copy-Item -Recurse $sourcePath $tempPath -ErrorAction SilentlyContinue

                $content = $null
                $caughtError = $null
                try 
                {
                    # Copy files using the Shell.  
                    # 
                    # Note, because this uses shell this will not work on core OSs
                    # But we only use this on older OSs and in test, so core OS use
                    # is unlikely
                    function Copy-ToZipFileUsingShell
                    {
                        param (
                            [string]
                            [ValidateNotNullOrEmpty()]
                            [ValidateScript({ if($_ -notlike '*.zip'){ throw 'zipFileName must be *.zip'} else {return $true}})]
                            $zipfilename,

                            [string]
                            [ValidateScript({ if(-not (Test-Path $_)){ throw 'itemToAdd must exist'} else {return $true}})]
                            $itemToAdd,

                            [switch]
                            $overWrite
                        )
                        Set-StrictMode -Version latest
                        if(-not (Test-Path $zipfilename) -or $overWrite)
                        {
                            set-content $zipfilename ('PK' + [char]5 + [char]6 + ("$([char]0)" * 18))
                        }
                        $app = New-Object -com shell.application
                        $zipFile = ( Get-Item $zipfilename ).fullname
                        $zipFolder = $app.namespace( $zipFile )
                        $itemToAdd = (Resolve-Path $itemToAdd).ProviderPath
                        $zipFolder.copyhere( $itemToAdd )
                    }
                    
                    # Generate an automatic filename if filename is not supplied
                    if(!$fileName)
                    {
                        $fileName = "$([System.IO.Path]::GetFileName($logFolder))-$((Get-Date).ToString('yyyyMMddhhmmss')).zip"
                    }
                    
                    if($destinationPath)
                    {
                        $zipFile = Join-Path $destinationPath $fileName

                        if(!(Test-Path $destinationPath))
                        {
                            mkdir $destinationPath > $null
                        }
                    }
                    else
                    {
                        $zipFile = Join-Path ([IO.Path]::GetTempPath()) ('{0}.zip' -f $fileName)
                    }
                    
                    # Choose appropriate implementation based on CLR version
                    if ($PSVersionTable.CLRVersion.Major -lt 4)
                    {
                        Copy-ToZipFileUsingShell -zipfilename $zipFile -itemToAdd $tempPath 
                        $content = Get-Content $zipFile | Out-String
                    }
                    else
                    {
                        Add-Type -AssemblyName System.IO.Compression.FileSystem > $null
                        [IO.Compression.ZipFile]::CreateFromDirectory($tempPath, $zipFile) > $null
                        $content = Get-Content -Raw $zipFile
                    }
                }
                catch [Exception]
                {
                    $caughtError = $_
                }
                
                if($ReturnValue -eq 'Path')
                {
                    # Don't return content if we don't need it
                    return @{
                            Content = $null
                            Error = $caughtError
                            zipFilePath = $zipFile
                        }
                }
                else
                {
                    return @{
                            Content = $content
                            Error = $caughtError
                            zipFilePath = $zipFile
                        }                
                }             
            } -argumentlist @($sourceFolder,$destinationPath, $fileName, $ReturnValue) -ErrorVariable zipInvokeError 
            

            if($zipInvokeError -or $resultTable.Error)
            {
                if($attempts -lt 5)
                {
                    Write-Debug "An error occured trying to zip $sourceFolder .  Will retry..."
                    Start-Sleep -Seconds $attempts
                }
                else {
                    if($resultTable.Error)
                    {
                        $lastError = $resultTable.Error
                    }
                    else 
                    {
                        $lastError = $zipInvokeError[0]    
                    }
                    
                    Write-Warning "An error occured trying to zip $sourceFolder .  Aborting."
                    Write-ErrorInfo -ErrorObject $lastError -WriteWarning

                }
            }
            else
            {
                $gotZip = $true
            }
    }
    
    if($ReturnValue -eq 'Path')
    {
        $result = $resultTable.zipFilePath
    }
    else 
    {
        $result = $resultTable.content
    }

    return $result
}

#
# Tests if a parameter is a container, to be used in a ValidateScript attribute
#
function Test-ContainerParameter
{
  [CmdletBinding()]
  param(
    [string] $Path,
    [string] $Name = 'Path'
  )

  if(!(Test-Path $Path -PathType Container))
  {
    throw "$Name parameter must be a valid container."
  }

  return $true
}

#
# Exports an event log to a file in the path specified
# on the specified session, if the session is not specified
# a session to the local machine will be used
#
function Export-EventLog
{
  [CmdletBinding()]
  param(
        [string] $Name,
        [string] $path,
        [System.Management.Automation.Runspaces.PSSession] $Session
    )
    Write-Verbose "Exporting eventlog $name"
    $local = $false
    $invokeCommandParams = @{}
    if($Session)
    {
        $invokeCommandParams.Add('Session',$Session);
    }
    else
    {
        $local = $true
    }
    
    invoke-command -ErrorAction:Continue @invokeCommandParams -script {  
        param($name, $path)
        $ErrorActionPreference = 'stop'
        Set-StrictMode -Version latest        
        Write-Debug "Name: $name"

        Write-Debug "Path: $path"
        Write-Debug "windir: $Env:windir"
        $exePath = Join-Path $Env:windir 'system32\wevtutil.exe'
        $exportFileName = "$($Name -replace '/','-').evtx"

        $ExportCommand = "$exePath epl '$Name' '$Path\$exportFileName' /ow:True 2>&1"
        Invoke-expression -command $ExportCommand
    } -argumentlist @($Name, $path)        
}

#
# Gathers diagnostics for DSC and the DSC Extension into a zipfile 
# if specified, in the specified path
# if specified, in the specified filename
# on the specified session, if the session is not specified
# a session to the local machine will be used
#
function Get-xDscDiagnosticsZip
{
    [CmdletBinding(    SupportsShouldProcess=$true,        ConfirmImpact="High"    )]
    param(        
        [System.Management.Automation.Runspaces.PSSession] $Session,
        [string] $destinationPath,
        [string] $filename
    )

    $local = $false
    $invokeCommandParams = @{}
    if($Session)
    {
        $invokeCommandParams.Add('Session',$Session);
    }
    else
    {
        $local = $true
    }
    
    Function Write-ProgressMessage
    {
        [CmdletBinding()]
        param([string]$Status, [int]$PercentComplete, [switch]$Completed)

        Write-Progress -Activity 'Get-AzureVmDscDiagnostics' @PSBoundParameters
        Write-Verbose -message $status 
    }


$privacyConfirmation = @"
Collecting the following information, which may contain private/sensative details including:  
    1.   Logs from the Azure VM Agent, including all extensions
    2.   The state of the Azure DSC Extension, 
       including their configuration, configuration data (but not any decryption keys)
       and included or generated files.
    3.   The DSC and application event logs.
    4. The WindowsUpdate, CBS and DISM logs
    5. The output of Get-Hotfix
    6. The output of Get-DscLocalConfigurationManager

This tool is provided for your convience, to ensure all data is collected as quickly as possible.  

Are you sure you want to continue
"@
    if ($pscmdlet.ShouldProcess($privacyConfirmation)) 
    {
        
        $tempPath = invoke-command -ErrorAction:Continue @invokeCommandParams -script {
                $ErrorActionPreference = 'stop'
                Set-StrictMode -Version latest
                $tempPath = Join-path $env:temp ([system.io.path]::GetRandomFileName())
                if(!(Test-Path $tempPath))
                {
                    mkdir $tempPath > $null
                    mkdir $tempPath\CBS > $null
                    mkdir $tempPath\DISM > $null
                }
                return $tempPath
            }
        Write-Debug -message "tempPath: $tempPath" -verbose

        Write-ProgressMessage  -Status 'Finding DSC and copying Extension ...' -PercentComplete 0
        invoke-command -ErrorAction:Continue @invokeCommandParams -script {
            param($tempPath)
            $ErrorActionPreference = 'stop'
            Set-StrictMode -Version latest
            $dirs = @(Get-ChildItem C:\Packages\Plugins\Microsoft.Powershell.*DSC -ErrorAction SilentlyContinue) 
            $dir = $null
            if($dirs.Count -ge 1)
            {
                $dir = @(Get-ChildItem C:\Packages\Plugins\Microsoft.Powershell.*DSC -ErrorAction SilentlyContinue)[0].FullName
            }
            



            if($dir)
            {
            Write-Verbose -message "Found DSC extension at: $dir" -verbose
            Copy-Item -Recurse $dir $tempPath\DscPackageFolder -ErrorAction SilentlyContinue 
            Get-ChildItem "$tempPath\DscPackageFolder" -Recurse | %{
                    if($_.Extension -ieq '.msu')
                    {
                    $newFileName = "$($_.FullName).wasHere"
                    Get-ChildItem $_.FullName | Out-String | Out-File $newFileName -Force
                    $_.Delete()
                    }
                }
            }
            else 
            { 
                Write-Verbose -message "Did not find DSC extension." -verbose
            }
        } -argumentlist @($tempPath)

        Write-ProgressMessage  -Status 'Copying log files..' -PercentComplete 1
        invoke-command -ErrorAction:Continue @invokeCommandParams -script {
            param($tempPath)    
            $ErrorActionPreference = 'stop'
            Set-StrictMode -Version latest
            Copy-Item -Recurse C:\WindowsAzure\Logs $tempPath\WindowsAzureLogs -ErrorAction SilentlyContinue
            Copy-Item $env:windir\WindowsUpdate.log $tempPath\WindowsUpdate.log -ErrorAction SilentlyContinue
            Copy-Item $env:windir\logs\CBS\*.* $tempPath\CBS -ErrorAction SilentlyContinue
            Copy-Item $env:windir\logs\DISM\*.* $tempPath\DISM -ErrorAction SilentlyContinue
            Get-HotFix | Out-String | Out-File  $tempPath\HotFixIds.txt
            Get-DscLocalConfigurationManager | Out-String | Out-File   $tempPath\Get-dsclcm.txt
        } -argumentlist @($tempPath)

        Write-ProgressMessage -Status 'Getting DSC Event log ...' -PercentComplete 25
        Export-EventLog -Name Microsoft-Windows-DSC/Operational -Path $tempPath @invokeCommandParams
        Write-ProgressMessage  -Status 'Getting Application Event log ...' -PercentComplete 50
        Export-EventLog -Name Application -Path $tempPath @invokeCommandParams

        
        
        
        if(!$destinationPath)
        {
            Write-ProgressMessage  -Status 'Getting destinationPath ...' -PercentComplete 74
            $destinationPath = invoke-command -ErrorAction:Continue @invokeCommandParams -script { 
                $ErrorActionPreference = 'stop'
                Set-StrictMode -Version latest
                Join-path $env:temp ([system.io.path]::GetRandomFileName()) 
            }
        }

        Write-Debug -message "destinationPath: $destinationPath" -verbose
        $zipParams = @{ 
                sourceFolder = $tempPath
                destinationPath = $destinationPath
                Session = $session
                fileName = $fileName
            }

        Write-ProgressMessage  -Status 'Zipping files ...' -PercentComplete 75
        if($local)
        {
            $zip = Get-FolderAsZip @zipParams
            $zipPath = $zip
        }
        else 
        {
            $zip = Get-FolderAsZip @zipParams -ReturnValue 'Content'   
            if(!(Test-Path $destinationPath))
            {
                mkdir $destinationPath > $null
            }
            $zipPath = (Join-path $destinationPath "$($session.ComputerName)-dsc-diags-$((Get-Date).ToString('yyyyMMddhhmmss')).zip")
            set-content -path $zipPath -value $zip
        }

        Start-Process $destinationPath
        Write-Verbose -message "Please send this zip file the engineer you have been working with.  The engineer should have emailed you instructions on how to do this: $zipPath" -verbose
        Write-ProgressMessage  -Completed
        return $zipPath
    }
}

Export-ModuleMember -Function Get-xDscDiagnosticsZip