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

Node $AllNodes.NodeName
{
    Write-Verbose -Message "NodeName: $Nodename" -Verbose

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

	xPendingReboot RebootForDNSUpdate
    {
        Name      = 'RebootForDNS'
        DependsOn = '[xDisk]FDrive'
    }

    $parts = $DomainName -split '\.'
    $Netbios = $parts[0]
    $parentNetbios = $parts[-2]
    $parent = $parts[-2] + '.' + $parts[-1]
    [PSCredential]$DomainCreds = [PSCredential]::new( "$Netbios\$(($AdminCreds.UserName -split '\\')[-1])", $AdminCreds.Password )
    [PSCredential]$ForestCreds = [PSCredential]::new( "$parentNetbios\$(($AdminCreds.UserName -split '\\')[-1])", $AdminCreds.Password )

    Write-Verbose -Message "DomainName is: $DomainName"
    Write-Verbose -Message "Netbios is: $Netbios"
    Write-Verbose -Message "ParentNetbios is: $parentNetbios"
    Write-Verbose -Message "Parent is: $parent"
    Write-Verbose -Message "ForestCreds is: $($ForestCreds.UserName)"
    Write-Verbose -Message "DomainCreds is: $($DomainCreds.UserName)"
    Write-Verbose -Message "AdminCreds is: $($AdminCreds.Username)"

    xWaitForADDomain $parent
    {
        DependsOn  = '[WindowsFeatureSet]RSAT'
        DomainName = $parent
        RetryCount = $RetryCount
		RetryIntervalSec = $RetryIntervalSec
        DomainUserCredential = $ForestCreds
    }

    xADDomain USDC1
	{
		DependsOn    = "[xWaitForADDomain]$parent"
		DomainName   = $DomainName
		DatabasePath = 'F:\NTDS'
        LogPath      = 'F:\NTDS'
        SysvolPath   = 'F:\SYSVOL'
        DomainAdministratorCredential = $DomainCreds
        SafemodeAdministratorPassword = $AdminCreds
		PsDscRunAsCredential = $ForestCreds
        ParentDomainName = $parentNetbios
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