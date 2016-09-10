Configuration Main
{
Param ( 
		[String]$DomainName = 'US.Contoso.com',
		[PSCredential]$AdminCreds,
		[Int]$RetryCount = 20,
		[Int]$RetryIntervalSec = 120
		)

Import-DscResource -ModuleName PSDesiredStateConfiguration
Import-DscResource -ModuleName xComputerManagement
Import-DscResource -ModuleName xActiveDirectory
Import-DscResource -ModuleName xStorage
Import-DscResource -ModuleName xPendingReboot


[PSCredential]$DomainCreds = New-Object System.Management.Automation.PSCredential ("$DomainName\$(($AdminCreds.UserName -split '\\')[-1])", $AdminCreds.Password)

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

	WindowsFeatureSet RSAT
    {            
        Ensure = 'Present'
        Name   = 'AD-Domain-Services'
		IncludeAllSubFeature = $true
    }

	xDisk FDrive
    {
        DiskNumber  = 2
        DriveLetter = 'F'
    }

    $parts = $DomainName -split '\.'
    $Netbios = $parts[0]
    $parent = $parts[-2] + '.' + $parts[-1]


    xWaitForADDomain $parent
    {
        DependsOn  = '[WindowsFeatureSet]RSAT'
        DomainName = $parent
        RetryCount = $RetryCount
		RetryIntervalSec = $RetryIntervalSec
        DomainUserCredential = $AdminCreds
    }

    xADDomain USDC1
	{
		DependsOn    = "[xWaitForADDomain]$parent"
		DomainName   = $Netbios
		DatabasePath = 'F:\NTDS'
        LogPath      = 'F:\NTDS'
        SysvolPath   = 'F:\SYSVOL'
        DomainAdministratorCredential = $DomainCreds
        SafemodeAdministratorPassword = $DomainCreds
		PsDscRunAsCredential = $DomainCreds
        ParentDomainName = $parent
        DomainNetbiosName = $Netbios
	}

	# when the 2nd DC is promoted the DNS (static server IP's) are automatically set to localhost (127.0.0.1 and ::1) by DNS
	# I have to remove those static entries and just use the Azure Settings for DNS from DHCP
	Script ResetDNS
    {
        DependsOn = '[xADDomain]USDC1'
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
}
}#Main


break

# used for troubleshooting

#$Cred = get-credential brw
main -ConfigurationData .\ConfigurationData.psd1 -AdminCreds $cred -Verbose
Start-DscConfiguration -Path .\Main -Wait -Verbose -Force

Get-DscLocalConfigurationManager

Start-DscConfiguration -UseExisting -Wait -Verbose -Force

Get-DscConfigurationStatus -All