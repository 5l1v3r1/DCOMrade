<#
.SYNOPSIS
Powershell script for checking possibly vulnerable DCOM applications.

.DESCRIPTION
This script is able to check if the external RPC allow Firewall rule is present in the target machine. Make sure you are able to use PSRemoting

The RPC connection can be recognized in the Windows Firewall with the following query:
v2.10|Action=Allow|Active=TRUE|Dir=In|Protocol=6|LPort=RPC

The Windows registry holds this value at the following location:
HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\services\SharedAccess\Parameters\FirewallPolicy\FirewallRules

If the rule is not present it is added with the following Powershell oneliner:
New-ItemProperty -Path HKLM:\System\CurrentControlSet\Services\SharedAccess\Parameters\FirewallPolicy\FirewallRules -Name RPCtest -PropertyType String -Value 'v2.10|Action=Allow|Active=TRUE|Dir=In|Protocol=6|LPort=RPC|App=any|Svc=*|Name=Allow RPC IN|Desc=custom RPC allow|'

.PARAMETER computername
The computername of the victim machine

.PARAMETER user
The username of the victim

.PARAMETER interactive
Set this to $True if you want an interactive session with the machine

.EXAMPLE
PS > Check-RemoteRPC.ps1 -computername victim -user alice
Use this above command and parameters to start a non-interactive session

.EXAMPLE
PS > Check-RemoteRPC.ps1 -computername victim -user alice -interactive $True
Use this command and parameters to start a interactive session

.LINK
https://github.com/sud0woodo

.NOTES 
Access to the local/domain administrator account on the target machine is needed to enable PSRemoting and check/change the Firewall rules.
To enable the features needed, execute the following commands:

PS > Enable-PSRemoting -SkipNetworkProfileCheck -Force
PS > Set-NetFirewallRule -Name "WINRM-HTTP-In-TCP-PUBLIC" -RemoteAddress Any

Author: sud0woodo
#>

# Assign arguments to parameters
param(
    [Parameter(Mandatory=$True,Position=1)]
    [String]$computername,

    [Parameter(Mandatory=$True,Position=2)]
    [String]$user,

    [Parameter(Mandatory=$False,Position=3)]
    [Boolean]$interactive,

    [Parameter(Mandatory=$False,Position=4)]
    [Boolean]$blacklist
    )

# Define filenames to write to
$DCOMApplicationsFile = "DCOM_Applications_$computername.txt"
$LaunchPermissionFile = "DCOM_DefaultLaunchPermissions_$computername.txt"
$CLSIDFile = "DCOM_CLSID_$computername.txt"
$CustomBlackListFile = "Custom_Blaclisted_CLSIDs_$computername.txt"

# Create a new non-interactive Remote Powershell Session
function Get-NonInteractiveSession {
    Try {
        Write-Host "[i] Connecting to $computername" -ForegroundColor Yellow
        $session = New-PSSession -ComputerName $computername -Credential $computername\$user -ErrorAction Stop
        Write-Host "[+] Connected to $computername" -ForegroundColor Green
        return $session
    } Catch [System.Management.Automation.Remoting.PSRemotingTransportException] {
        Write-Host "[!] Creation of Remote Session failed, Access is denied." -ForegroundColor Red
        Write-Host "[!] Exiting..." -ForegroundColor Red
        Break
    }
}

# Create a new interactive Remote Powershell Session
function Get-InteractiveSession {
    Try {
        Write-Host "[i] Connecting to $computername" -ForegroundColor Yellow
        $session = Enter-PSSession -ComputerName $computername -Credential $computername\$user -ErrorAction Stop
        Write-Host "[+] Connected to $computername" -ForegroundColor Green
        return $session
    } Catch [System.Management.Automation.Remoting.PSRemotingTransportException] {
        Write-Host "[!] Creation of Remote Session failed, Access is denied." -ForegroundColor Red
        Write-Host "[!] Make sure PSRemoting and WINRM is enabled on the target system!" -ForegroundColor Yellow
        Write-Host "[!] Exiting..." -ForegroundColor Red
        Break
    }
}

# Check if the RPC firewall rule is present, returns True if it accepts external connections, False if the rule is not present
function Get-RPCRule {
    # Check if the RPC Firewall rule is present and allows external connections
    Write-Host "[i] Checking if $computername allows External RPC connections..." -ForegroundColor Yellow
    $CheckRPCRule = Invoke-Command -Session $remotesession {
        Get-ItemProperty -Path Registry::HKLM\System\CurrentControlSet\Services\SharedAccess\Parameters\FirewallPolicy\FirewallRules | ForEach-Object {
            $_ -Match 'v2.10\|Action=Allow\|Active=TRUE\|Dir=In\|Protocol=6\|LPort=RPC'
        }
    }
    # Add the RPC Firewall rule if not yet present on the target system
    if ($CheckRPCRule -eq $True) {
        Write-Host "[+] $computername allows external RPC connections!" -ForegroundColor Green
    } else {
        Write-Host "[!] External RPC Firewall rule not found!" -ForegroundColor Red
        Try {
            Write-Host "[+] Attempting to add Firewall rule..." -ForegroundColor Yellow
            Invoke-Command -Session $remotesession -ScriptBlock {New-ItemProperty -Path HKLM:\System\CurrentControlSet\Services\SharedAccess\Parameters\FirewallPolicy\FirewallRules -Name RPCtest -PropertyType String -Value 'v2.10|Action=Allow|Active=TRUE|Dir=In|Protocol=6|LPort=RPC|App=any|Svc=*|Name=Allow RPC IN|Desc=custom RPC allow|'}
            Write-Host "[+] Firewall rule added!" -ForegroundColor Green
        } Catch {
            Write-Host "[!] Failed to add RPC allow Firewall Rule!" -ForegroundColor Red
            Write-Host "[!] Exiting..." -ForegroundColor Red
            Break
        }
    }
}

# Check the DCOM applications on the target system and write these to a textfile
function Get-DCOMApplications {
    # Get DCOM applications
    Write-Host "[i] Retrieving DCOM applications." -ForegroundColor Yellow
    $DCOMApplications = Invoke-Command -Session $remotesession -ScriptBlock {
        Get-CimInstance Win32_DCOMapplication
    }

    # Write the results to a text file
    Try {
        Out-File -FilePath .\$DCOMApplicationsFile -InputObject $DCOMApplications -Encoding ascii -ErrorAction Stop
    } Catch [System.IO.IOException] {
        Write-Host "[!] Failed to write output to file!" -ForegroundColor Red
        Write-Host "[!] Exiting..."
        Break
    }
    Write-Host "[+] DCOM applications retrieved and written to $DCOMApplicationsFile." -ForegroundColor Green
    Return $DCOMApplications  
}

# Function that checks for the default permissions parameter in the registry and cross references this with the available DCOM Applications on the system
function Get-DefaultPermissions {
    # Map the path to HKEY_CLASSES_ROOT
    Invoke-Command -Session $remotesession -ScriptBlock {
        New-PSDrive -Name HKCR -PSProvider Registry -Root HKEY_CLASSES_ROOT
    } | Out-Null

    # Loop through the registry and check every key for the LaunchPermission property, we're only interested in the keys without this property
    Write-Host "[i] Checking DCOM applications with default launch permissions..." -ForegroundColor Yellow
    Invoke-Command -Session $remotesession -ScriptBlock {
        Get-ChildItem -Path HKCR:\AppID\ | ForEach-Object {
            if(-Not($_.Property -Match "LaunchPermission")) {
                $_.Name.Replace("HKEY_CLASSES_ROOT\AppID\","")
            }
        } 
    } -OutVariable DefaultPermissionsAppID | Out-Null 

    # Store the DCOM applications present on the target machine in a variable
    $DCOMApplications = Get-DCOMApplications($remotesession)
    # Check which DCOM applications have the default permissions set
    $DefaultPermissions = $DCOMApplications | Select-String -Pattern $DefaultPermissionsAppID
    Write-Host "[+] Found $($DefaultPermissions.Count) DCOM applications without 'LaunchPermission' subkey!" -ForegroundColor Green

    Try {
        Out-File -FilePath .\$LaunchPermissionFile -InputObject $DefaultPermissions -Encoding ascii -ErrorAction Stop
    } Catch [System.IO.IOException] {
        Write-Host "[!] Failed to write output to file!" -ForegroundColor Red
        Write-Host "[!] Exiting..."
        Break
    }
    Write-Host "[+] DCOM default LaunchPermission results written to $LaunchPermissionFile" -ForegroundColor Green

    Return $DefaultPermissions
}

# Function to retrieve the CLSIDs for DCOM applications without LaunchPermissions set
function Get-CLSID($DefaultLaunchPermission) {
    # Extract all the AppIDs from the list with the default LaunchPermissions
    $DCOMAppIDs = $DefaultLaunchPermission | Select-String -Pattern '\{(?i)[0-9a-z]{8}-[0-9a-z]{4}-[0-9a-z]{4}-[0-9a-z]{4}-[0-9a-z]{12}\}' | ForEach-Object {
            $_.Matches.Value
    }

    Write-Host "[i] Retrieving CLSID's..." -ForegroundColor Yellow
    $RemoteDCOMCLSIDs = Invoke-Command -Session $remotesession -ScriptBlock {
        # Define variable to store the results
        $DCOMCLSIDs = @()
        # Loop through the registry and check which AppID with default LaunchPermissions corresponds with which CLSID
        (Get-ChildItem -Path HKCR:\CLSID\ ).Name.Replace("HKEY_CLASSES_ROOT\CLSID\","") | ForEach-Object {
            if ($Using:DCOMAppIDs -eq (Get-ItemProperty -Path HKCR:\CLSID\$_).'AppID') {
                $DCOMCLSIDs += "Name: " + (Get-ItemProperty -Path HKCR:\CLSID\$_).'(default)' + " CLSID: $_"
            } 
        }
        # Return the DCOM CLSIDs so these can be used locally
        Return $DCOMCLSIDs
    }

    # Write the output to a file
    Try {
        Out-File -FilePath .\$CLSIDFile -InputObject $RemoteDCOMCLSIDs -Encoding ascii -ErrorAction Stop
    } Catch [System.IO.IOException] {
        Write-Host "[!] Failed to write output to file!" -ForegroundColor Red
        Write-Host "[!] Exiting..."
        Break
    }
    Write-Host "[+] DCOM application CLSID's written to $CLSIDFile" -ForegroundColor Green

    # Extract the DCOM CLSIDs for future usage
    $ExtractedCLSIDs = $RemoteDCOMCLSIDs | Select-String -Pattern '\{(?i)[0-9a-z]{8}-[0-9a-z]{4}-[0-9a-z]{4}-[0-9a-z]{4}-[0-9a-z]{12}\}' | ForEach-Object {
        $_.Matches.Value
    }
    
    # Return the extracted CLSIDs
    Return $ExtractedCLSIDs
}

# Function to loop over the DCOM CLSIDs and check which CLSIDs hold more than the default amount of MemberTypes
function Get-MemberTypeCount($CLSIDs) {
    <#
    TODO:
        - Think of a way to not start unnecessary application windows and/or processes
            + Maybe create a blacklist with known non-vulnerable/interesting DCOM CLSID's to skip?
    
            Example Blacklisted CLSIDs:
            Name: Add to Windows Media Player list CLSID: {45597c98-80f6-4549-84ff-752cf55e2d29}
            Name: Windows Media Player Burn Audio CD Handler CLSID: {cdc32574-7521-4124-90c3-8d5605a34933}
            Name: Play with Windows Media Player CLSID: {ed1d0fdf-4414-470a-a56d-cfb68623fc58}
            Name: MAPI Mail Previewer CLSID: {53BEDF0B-4E5B-4183-8DC9-B844344FA104}

            There is a good chance that a lot of the installed applications on one of the machines in a Microsoft Windows domain have the same applications installed due to for example a WDWS (Windows Deployment Server).
            Creating a base blacklist (See above blacklist) and giving the user the option to provide an additional blacklist might be a valuable option.
    #>

    Write-Host "[i] Checking MemberType count..." -ForegroundColor Yellow

    # Check the default number of MemberType on the system, CLSID that is being used as a reference is the built in "Shortcut" CLSID
    # CLSID located at HKEY_CLASSES_ROOT\CLSID\{00021401-0000-0000-C000-000000000046}
    $DefaultMember = [activator]::CreateInstance([type]::GetTypeFromCLSID("00021401-0000-0000-C000-000000000046","$computername"))
    $DefaultMemberCount = ($DefaultMember | Get-Member).Count
    # Release the COM Object that was instantiated for getting the reference count of default MemberTypes
    [System.Runtime.Interopservices.Marshal]::ReleaseComObject($DefaultMember) | Out-Null

    # Create an array to store the potentially interesting DCOM applications
    $CLSIDCount = @()

    $DefaultBlackList = Get-Content -Path .\BaseBlackList.txt
    
    # Execute the following if block if the blacklist parameter is set
    if ($blacklist) {
        # Create an array to use as a future blacklist of known non-vulnerable / interesting DCOM applications
        $CustomBlackList = @()
        $CLSIDs | ForEach-Object {
            Try {
                $CLSID = $_
                # Add a delay to prevent too much load
                Start-Sleep -Milliseconds 250
                # Check if the CLSID is on the blacklist
                if (-not ($CLSID | Select-String -Pattern $DefaultBlackList)) {
                    # Instantiate the COM object by providing the CLSID and computername and count the number of MemberTypes
                    $com = [activator]::CreateInstance([type]::GetTypeFromCLSID("$CLSID","$computername"))
                    $MemberCount = ($com | Get-Member).Count
                    # Add the result to $CLSIDCount if it's more than 0 and not equal to the default amount of MemberTypes
                    if (-not ($MemberCount -eq $DefaultMemberCount) -and ($MemberCount -gt 0)) {
                        $CLSIDCount += "CLSID: $_ Count: " + $MemberCount
                        # Release the instantiated COM object
                        [System.Runtime.Interopservices.Marshal]::ReleaseComObject($com) | Out-Null
                    } else {
                        # Add the CLSIDs to be blacklisted
                        $CustomBlackList += $CLSID
                        # Release the instantiated COM object
                        [System.Runtime.Interopservices.Marshal]::ReleaseComObject($com) | Out-Null
                    }
                } else {
                    Write-Host "[i] Blacklisted CLSID found, skipping..." -ForegroundColor Yellow
                    [System.Console]::Out.Flush()
                    $CustomBlackList += $CLSID
                }
            } Catch {
                Write-Host "CLSID: $_ Cannot be instantiated"
                [System.Console]::Out.Flush()
                $CustomBlackList += $CLSID
            }
        }
        
        # Call the function to write the blacklisted CLSIDs to
        Create-CustomBlackList($CustomBlackList)

    } else {
        $CLSIDs | ForEach-Object {
            Try {
                $CLSID = $_
                # Add a delay to prevent too much load
                Start-Sleep -Milliseconds 250
                # Check if the CLSID is on the blacklist
                if (-not ($CLSID | Select-String -Pattern $DefaultBlackList)) {
                    # Instantiate the COM object by providing the CLSID and computername and count the number of MemberTypes
                    $com = [activator]::CreateInstance([type]::GetTypeFromCLSID("$CLSID","$computername"))
                    $MemberCount = ($com | Get-Member).Count
                    # Add the result to $CLSIDCount if it's more than 0 and not equal to the default amount of MemberTypes
                    if (-not ($MemberCount -eq $DefaultMemberCount) -and ($MemberCount -gt 0)) {
                        $CLSIDCount += "CLSID: $_ Count: " + $MemberCount
                        # Release the instantiated COM object
                        [System.Runtime.Interopservices.Marshal]::ReleaseComObject($com) | Out-Null
                    } else {
                        [System.Runtime.Interopservices.Marshal]::ReleaseComObject($com) | Out-Null
                    }
                } else {
                    Write-Host "[i] Blacklisted CLSID found, skipping..." -ForegroundColor Yellow
                    [System.Console]::Out.Flush()
                }                
            } Catch {
                Write-Host "CLSID: $_ Cannot be instantiated"
                [System.Console]::Out.Flush()
            }
        }
    } 

    # This process gets started in the background by instantiating its COM object
    Stop-Process -Name iexplore

    Write-Host "[+] The following COM objects might be interesting to look into: " -ForegroundColor Green
    $CLSIDCount
}

# Function to provide the option to create a custom blacklist for future use on other machines in for example a Microsoft Windows domain
function Create-CustomBlackList($BlackListedCLSIDs) {
    Write-Host "[i] Custom blacklist parameter was given, building blacklist..." -ForegroundColor Yellow

    Try {
        Out-File -FilePath .\$CustomBlackListFile -InputObject $BlackListedCLSIDs -Encoding ascii -ErrorAction Stop
        Write-Host "[i] Writing $($BlacklistedCLSIDs.Count) CLSIDs to the custom blacklist" -ForegroundColor Yellow
    } Catch [System.IO.IOException] {
        Write-Host "[!] Failed to write output to file!" -ForegroundColor Red
        Write-Host "[!] Exiting..."
        Break
    }
    Write-Host "[+] Blacklisted DCOM application CLSID's written to $CLSIDFile" -ForegroundColor Green
}

if ($interactive) {
    Write-Host "[+] Attempting interactive session with $computername" -ForegroundColor Yellow
    $remotesession = Get-InteractiveSession
} else {
    Write-Host "[+] Attempting non-interactive session with $computername" -ForegroundColor Yellow
    $remotesession = Get-NonInteractiveSession
}

# Test for the RPC Firewall rule
Get-RPCRule
# Get DCOM applications with default LaunchPermissions set
$DCOMDefaultLaunchPermissions = Get-DefaultPermissions
# Get the CLSIDs of the DCOM applications with default LaunchPermissions
$DCOMApplicationsCLSID = Get-CLSID($DCOMDefaultLaunchPermissions)
# Test the amount of members by instantiating these as DCOM
Get-MemberTypeCount($DCOMApplicationsCLSID)
