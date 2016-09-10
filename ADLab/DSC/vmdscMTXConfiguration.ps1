Configuration Main
{
Param ( 
		[String]$DomainName = 'Contoso.com',
		[PSCredential]$AdminCreds,
		[Int]$RetryCount = 20,
		[Int]$RetryIntervalSec = 120,
        $ThumbPrint = '80FC80D83777B9B7E1E550797FC79E208CA4AE85'
		)

Import-DscResource -ModuleName PSDesiredStateConfiguration
Import-DscResource -ModuleName xComputerManagement
Import-DscResource -ModuleName xActiveDirectory
Import-DscResource -ModuleName xStorage
Import-DscResource -ModuleName xPendingReboot
Import-DscResource -ModuleName xWebAdministration

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

	WindowsFeatureSet Commonroles
    {            
        Ensure = 'Present'
        Name   = 'Web-Server','RSAT'
		IncludeAllSubFeature = $true
    }

	xDisk FDrive
    {
        DiskNumber  = 2
        DriveLetter = 'F'
    }

    xWaitForADDomain $DomainName
    {
        DependsOn  = '[WindowsFeatureSet]Commonroles'
        DomainName = $DomainName
        RetryCount = $RetryCount
		RetryIntervalSec = $RetryIntervalSec
        DomainUserCredential = $AdminCreds
    }

	xComputer DomainJoin
	{
		Name       = $env:COMPUTERNAME
		DependsOn  = "[xWaitForADDomain]$DomainName"
		DomainName = $DomainName
		Credential = $DomainCreds
	}
    
	# reboots after DJoin
	xPendingReboot RebootForDJoin
    {
        Name      = 'RebootForDJoin'
        DependsOn = '[xComputer]DomainJoin'
    }

    # base install above - custom role install
    # TODO: Look at putting this in a composite resource
    WindowsFeature BasewebRolesMgmt
    {
        Ensure = 'Present'
        Name   = 'Web-Mgmt-Console'
    }
        
    # Begin Prereqs for IIS mgmt
    Registry EnableRemoteManagement
    {
        Key       = 'HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\WebManagement\Server'
        ValueName = 'EnableRemoteManagement'
        Ensure    = 'Present'
        ValueData = 1
        ValueType = 'Dword'
        Force     = $true
    }

    Registry WebManagementCert
    {
        Key       = 'HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\WebManagement\Server'
        ValueName = 'SslCertificateHash'
        Ensure    = 'Present'
        ValueData = $ThumbPrint
        ValueType = 'Binary'
        Force     = $true
    }

    # Note: IIS Web Mgmt runs on 8172/tcp by default
    WindowsFeature 'WebMgmtService'
    {
        Name   = 'Web-Mgmt-Service'
        Ensure = 'Present' 
        DependsOn   = '[Registry]EnableRemoteManagement' 
    }
	
    Service WMSVC
    {
        Name        = 'WMSVC'
        StartupType = 'Automatic'
        State       = 'Running'
        DependsOn   = '[WindowsFeature]WebMgmtService','[Registry]EnableRemoteManagement' 
    } 
    # END Prereqs for IIS mgmt 

    File WebSite1Dir
    {
        DestinationPath = 'F:\inetpub\wwwroot\WebSite1'
        Type = 'Directory'
    }
    
    File HtmlFile
    {
        DestinationPath = 'F:\inetpub\wwwroot\WebSite1\index.html'
        Contents = 'Hello World'
        Type = 'File'
        DependsOn = '[File]WebSite1Dir'
    }
    
    xWebAppPool ApplicationPool1
    {
        Name = 'ApplicationPool1'
        State = 'Started'
        autoStart = $true
        DependsOn = '[Service]WMSVC'
    }

    xWebsite DefaultWeb
    {
        Name = 'Default Web Site'
        State = 'Stopped'
        PhysicalPath = "C:\inetpub\wwwroot"
        Ensure = 'Absent'
        DependsOn = '[Service]WMSVC'
    }

    xWebsite WebSite1
    {
        Name            = 'WebSite1'
        ApplicationPool = 'ApplicationPool1'
        PhysicalPath    = 'F:\inetpub\wwwroot\WebSite1'
        State           = 'Started'
        DependsOn       = '[File]WebSite1Dir','[xWebAppPool]ApplicationPool1', '[xWebsite]DefaultWeb'
        BindingInfo = @(
                MSFT_xWebBindingInformation
                {
                    Protocol              = "HTTP"
                    Port                  = 80
                }
                MSFT_xWebBindingInformation
                {
                    Protocol              = "HTTPS"
                    Port                  = 443
                    CertificateThumbprint = $ThumbPrint
                    CertificateStoreName  = "MY"
                }
            )
    }



}
}#Main


break

# used for troubleshooting
# F5 loads the script

#$Cred = get-credential lcladmin
main -ConfigurationData .\ConfigurationData.psd1 -AdminCreds $cred -Verbose
Start-DscConfiguration -Path .\Main -Wait -Verbose -Force

Get-DscLocalConfigurationManager

Start-DscConfiguration -UseExisting -Wait -Verbose -Force

Get-DscConfigurationStatus -All
