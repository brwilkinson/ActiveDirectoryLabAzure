Configuration Main
{
Param ( 
		[String]$DomainName = 'Contoso.com',
		[PSCredential]$AdminCreds,
		[Int]$RetryCount = 15,
		[Int]$RetryIntervalSec = 60
		)

Import-DscResource -ModuleName PSDesiredStateConfiguration -ModuleVersion 1.1
Import-DscResource -ModuleName xActiveDirectory  -ModuleVersion 2.12.0.0
Import-DscResource -ModuleName xStorage -ModuleVersion 2.4.0.0
Import-DscResource -ModuleName xPendingReboot -ModuleVersion 0.3.0.0 

[PSCredential]$DomainCreds = New-Object System.Management.Automation.PSCredential ("$DomainName\$($AdminCreds.UserName)", $AdminCreds.Password)

Node $AllNodes.NodeName
{
    Write-Verbose -Message $Nodename -Verbose

	LocalConfigurationManager
    {
        ActionAfterReboot   = 'ContinueConfiguration'
        ConfigurationMode   = 'ApplyAndMonitor'
        RebootNodeIfNeeded  = $true
        AllowModuleOverWrite = $true
    }

    WindowsFeature InstallADDS
    {            
        Ensure = "Present"
        Name = "AD-Domain-Services"
    }

	xDisk FDrive
    {
        DiskNumber  = 2
        DriveLetter = 'F'
    }

    xADDomain DC1
    {
        DomainName = $DomainName
        DomainAdministratorCredential = $DomainCreds
        SafemodeAdministratorPassword = $DomainCreds
        DatabasePath = 'F:\NTDS'
        LogPath      = 'F:\NTDS'
        SysvolPath   = 'F:\SYSVOL'
        DependsOn = "[WindowsFeature]InstallADDS","[xDisk]FDrive"
    }

	Script ResetDNS
    {
        DependsOn = '[xADDomain]DC1'
        GetScript = {@{Name='DNSServers';Address={Get-DnsClientServerAddress -InterfaceAlias Ethernet | foreach ServerAddresses}}}
        SetScript = {Set-DnsClientServerAddress -InterfaceAlias Ethernet -ResetServerAddresses -Verbose}
        TestScript = {Get-DnsClientServerAddress -InterfaceAlias Ethernet -AddressFamily IPV4 | 
						Foreach {! ($_.ServerAddresses -contains '127.0.0.1')}}
    }

    # Need to make sure the DC reboots after it is promoted.
	xPendingReboot RebootForPromo
    {
        Name      = 'RebootForDJoin'
        DependsOn = '[Script]ResetDNS'
    }

    xWaitForADDomain DC1Forest
    {
        DomainName           = $DomainName
        DomainUserCredential = $DomainCreds
        RetryCount           = $RetryCount
        RetryIntervalSec     = $RetryIntervalSec
        DependsOn = "[xPendingReboot]RebootForPromo"
    } 

    xADRecycleBin RecycleBin
    {
        EnterpriseAdministratorCredential = $DomainCreds
        ForestFQDN                        = $DomainName
        DependsOn = '[xWaitForADDomain]DC1Forest'
    }



}
}#Main

break


#$Cred = get-credential brw
Invoke-RestMethod -uri https://raw.githubusercontent.com/brwilkinson/Azure/master/ConfigurationData.psd1 -OutFile .\ConfigurationData.psd1
main -ConfigurationData .\ConfigurationData.psd1 -AdminCreds $cred -Verbose
Start-DscConfiguration -Path .\Main -Wait -Verbose -Force

Get-DscLocalConfigurationManager

Start-DscConfiguration -UseExisting -Wait -Verbose -Force

Get-DscConfigurationStatus -All