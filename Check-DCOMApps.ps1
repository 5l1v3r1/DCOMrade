<#
.SYNOPSIS
Powershell script for checking possibly vulnerable DCOM applications.

.DESCRIPTION
This script is able to check if the external RPC allow Firewall rule is present, enumerate the DCOM applications and check the Methods / Properties of the 
DCOM applications for possible vulnerabilities. 

The first check is the RPC check which verifies whether or not RPC connections from external are allowed.
The RPC connection can be recognized in the Windows Firewall with the following query:
v2.10|Action=Allow|Active=TRUE|Dir=In|Protocol=6|LPort=RPC

The Windows registry holds this value at the following location:
HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\services\SharedAccess\Parameters\FirewallPolicy\FirewallRules

If the rule is not present it is added with the following Powershell oneliner:
New-ItemProperty -Path HKLM:\System\CurrentControlSet\Services\SharedAccess\Parameters\FirewallPolicy\FirewallRules -Name RPCtest -PropertyType String -Value 'v2.10|Action=Allow|Active=TRUE|Dir=In|Protocol=6|LPort=RPC|App=any|Svc=*|Name=Allow RPC IN|Desc=custom RPC allow|'

After adding the RPC firewall rule the script will enumerate the DCOM applications present on the machine and verify which CLSID belongs to which DCOM application.

The DCOM applications will get instantiated by the script and the amount of MemberTypes present will be checked, the DCOM applications might be interesting if it doesn't
hold the same as the default amount of MemberTypes (this is checked by counting the amount of MemberTypes when instantiating the default CLSID of "Shortcut") and holds more
MemberTypes than 0.

.PARAMETER computername
The computername of the victim machine

.PARAMETER user
The username of the victim

.PARAMETER interactive
Set this to $True if you want an interactive session with the machine

.PARAMETER blacklist
Set this to $True if you want to create a custom blacklist out of the CLSIDs that cannot be instantiated

.EXAMPLE
PS > Check-DCOMApps.ps1 -computername victim -user alice
Use this above command and parameters to start a non-interactive session

.EXAMPLE
PS > Check-DCOMApps.ps1 -computername victim -user alice -interactive $True
Use this command and parameters to start a interactive session

.EXAMPLE
PS > Check-DCOMApps.ps1 -computername victim -user alive -blacklist $True

.LINK
https://github.com/sud0woodo

.NOTES 
Access to the local/domain administrator account on the target machine is needed to enable PSRemoting and check/change the Firewall rules.
To enable the features needed, execute the following commands:

PS > Enable-PSRemoting -SkipNetworkProfileCheck -Force

Author: Axel Boesenach
#>

# Assign arguments to parameters
param(
    [Parameter(Mandatory=$True,Position=1)]
    [String]$computername,

    [Parameter(Mandatory=$True,Position=2)]
    [String]$user,

    [Parameter(Mandatory=$True,Position=3)]
    [ValidateSet("win7","win10")]
    [String]$os,

    [Parameter(Mandatory=$False,Position=4)]
    [Boolean]$interactive,

    [Parameter(Mandatory=$False,Position=5)]
    [Boolean]$blacklist
    )

# Define filenames to write to
$DCOMApplicationsFile = "DCOM_Applications_$computername.txt"
$LaunchPermissionFile = "DCOM_DefaultLaunchPermissions_$computername.txt"
$CLSIDFile = "DCOM_CLSID_$computername.txt"

# Create two blacklists: Windows 7 and Windows 10
$Win7BlackListFile = "Win7BlacklistedCLSIDS.txt"
$Win10BlackListFile = "Win10BlackListedCLSIDS.txt"
$CustomBlackListFile = "Custom_Blaclisted_CLSIDs_$computername.txt"

$VulnerableSubsetFile = "VulnerableSubset.txt"
$PossibleVulnerableFile = "Possible_Vuln_DCOMapps_$computername.txt"


# Welcome logo

Write-Host "MMMMMMMMMMMMMMMMMMMMMWN" -f Yellow -nonewline; Write-Host "0O" -f Red -nonewline; Write-Host "KWMMMMMMMMMMMMM" -f Yellow -NoNewline; Write-Host " ######################################################################## " -f Red
Write-Host "MMMMMMMMMMMMMMMMMMMMMMMN" -f Yellow -nonewline; Write-Host "OooO" -f Red -nonewline; Write-Host "XWMMMMMMMMMM" -f Yellow -NoNewline; Write-Host " ######################################################################## " -f Red
Write-Host "MMMMMMMMMMMMMMMMMMMMMMMMWK" -f Yellow -nonewline; Write-Host "o;cx" -f red -nonewline; Write-Host "KWMMMMMMMM" -f Yellow -NoNewline; Write-Host " ######################################################################## " -f Red
Write-Host "MMMMMMMMMMN0kxkOO0KXNWMMMMNk" -f Yellow -nonewline; Write-Host ":,:x" -f red -nonewline; Write-Host "KWMMMMMM" -f Yellow -NoNewline; Write-Host " ######################################################################## " -f Red
Write-Host "MMMMMMMMN0o" -f Yellow -nonewline; Write-Host ";'''',;" -f Red -nonewline; Write-Host "lOXNMMMMMW0" -f Yellow -nonewline; Write-Host "c,,:" -f Red -nonewline; Write-Host "kNMMMMM" -f Yellow -NoNewline; Write-Host " ######################################################################## " -f Red
Write-Host "MMMMMMNOl" -f Yellow -NoNewline; Write-Host ";'''''," -f Red -nonewline; Write-Host "ckXWMMMMMMMMWKl" -f Yellow -nonewline; Write-Host ",',o" -f Red -nonewline; Write-Host "KWMMM" -f Yellow -NoNewline; Write-Host " ######################################################################## " -f Red
Write-Host "MMMWNOl;" -f Yellow -NoNewline; Write-Host "'''''''" -f Red -nonewline; Write-Host "c0WMMMMMMMMMMMWKc" -f Yellow -nonewline; Write-Host "''," -f Red -nonewline; Write-Host "lKWMM" -f Yellow -NoNewline; Write-Host " ###DCOMrade###DCOMrade###DCOMrade###DCOMrade###DCOMrade###DCOMrade###### " -f Red
Write-Host "MMW0l" -f Yellow -NoNewline; Write-Host ",'''''',''," -f Red -nonewline; Write-Host "ckXWMMMMMMMMMMWO" -f Yellow -nonewline; Write-Host ":'',o" -f Red -nonewline; Write-Host "XMM" -f Yellow -NoNewline; Write-Host " ######DCOMRADE###DCOMRADE###DCOMRADE###DCOMRADE###DCOMRADE###DCOMRADE### " -f Red
Write-Host "MMMXkccx" -f Yellow -NoNewline; Write-Host ",'k',l,''," -f Red -nonewline; Write-Host "ck0XWMMMMMMMMNd" -f Yellow -nonewline; Write-Host ",'';" -f Red -nonewline; Write-Host "xWM" -f Yellow -NoNewline; Write-Host " ##########DCOMrade###DCOMrade###DCOMrade###DCOMrade###DCOMrade###DCOM### " -f Red
Write-Host "MMMMWXkcckXWMNO" -f Yellow -NoNewline; Write-Host "l,'',;" -f Red -nonewline; Write-Host "ckXWMMMMMMWk" -f Yellow -nonewline; Write-Host ";'''" -f Red -nonewline; Write-Host "lXM" -f Yellow -NoNewline; Write-Host " ###" -f Red -NoNewline; Write-Host "   Powershell Script to enumerate vulnerable DCOM Applications" -f Yellow -NoNewline; Write-Host "    ### " -f Red
Write-Host "MMMMMMWNNWMMMMWNO" -f Yellow -NoNewline; Write-Host "l,'''," -f Red -nonewline; Write-Host "cxXWMMMMWO" -f Yellow -nonewline; Write-Host ";'''" -f Red -nonewline; Write-Host "lKM" -f Yellow -NoNewline; Write-Host " ######################################################################## " -f Red
Write-Host "MMMMMMMMMMMMMMMMMNO" -f Yellow -NoNewline; Write-Host ",;,''," -f Red -nonewline; Write-Host "cxXWMMNd" -f Yellow -nonewline; Write-Host ",'''" -f Red -nonewline; Write-Host "oXM" -f Yellow -NoNewline; Write-Host " ######################################################################## " -f Red
Write-Host "MMMMMMMMMMMMMMMMMMMNKO" -f Yellow -NoNewline; Write-Host "l,''," -f Red -nonewline; Write-Host "cxXNk" -f Yellow -nonewline; Write-Host ":''';" -f Red -nonewline; Write-Host "kWM" -f Yellow -NoNewline; Write-Host " ######################################################################## " -f Red
Write-Host "MMMMMMMWWX0OkOXWMMMMMMNk" -f Yellow -NoNewline; Write-Host ",'',:c" -f Red -nonewline; Write-Host "" -f Yellow -nonewline; Write-Host ";'''; " -f Red -nonewline; Write-Host "xNMM" -f Yellow -NoNewline; Write-Host " ######################################################################## " -f Red
Write-Host "MMMMMWNOl" -f Yellow -NoNewline; Write-Host ":,,'," -f Red -nonewline; Write-Host "cdk0KXNNNX" -f Yellow -nonewline; Write-Host "0o;''''''':" -f Red -nonewline; Write-Host "kNMMM" -f Yellow -NoNewline; Write-Host " ######################################################################## " -f Red
Write-Host "MMMWKkl" -f Yellow -NoNewline; Write-Host ";'';ll;''',;::cc::;,''''''," -f Red -nonewline; Write-Host "lKWMMM" -f Yellow -NoNewline; Write-Host " ######################################################################## " -f Red
Write-Host "MNOo" -f Yellow -NoNewline; Write-Host ":,'," -f Red -nonewline; Write-Host "cxKNN0xl" -f Yellow -NoNewline; Write-Host ";,''''''''''," -f Red -nonewline; Write-Host "::" -f Yellow -NoNewline; Write-Host ",''," -f Red -nonewline; Write-Host ":xKWM" -f Yellow -NoNewline; Write-Host " ######################################################################## " -f Red
Write-Host "Ko" -f Yellow -NoNewline; Write-Host ",'''," -f Red -nonewline; Write-Host "oKWMMMMMNKOkdddooodxk0XKkc" -f Yellow -NoNewline; Write-Host ",''," -f Red -nonewline; Write-Host ":xX" -f Yellow -NoNewline; Write-Host " ######################################################################## " -f Red
Write-Host "d" -f Yellow -NoNewline; Write-Host ",''," -f Red -nonewline; Write-Host ":xXMMMMMMMMMMMMMMWWMMMMMMMWXkc" -f Yellow -NoNewline; Write-Host ",''" -f Red -nonewline; Write-Host ";x" -f Yellow -NoNewline; Write-Host " ######################################################################## " -f Red
Write-Host "Oc,;" -f Yellow -NoNewline; Write-Host "o0WMMMMMMMMMMMMMMMMMMMMMMMMMMWKo" -f Yellow -NoNewline; Write-Host ",," -f Red -nonewline; Write-Host "c0" -f Yellow -NoNewline; Write-Host " ######################################################################## " -f Red


# Add victim machine to trusted hosts
# NOTE: This will prompt if you are sure you want to add the remote machine to the trusted hosts, press Y to confirm
$TrustedClients = Get-Item WSMan:\localhost\Client\TrustedHosts
if ($computername -notin $TrustedClients) {
    Set-Item WSMan:\localhost\Client\TrustedHosts -Value "$computername" -Concatenate
}

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
        
        - Create base blacklists based on Operating system version
            + Windows 7
            + Windows 8/8.1
            + Windows 10
    #>

    Write-Host "[i] Checking MemberType count..." -ForegroundColor Yellow

    $DefaultMemberCount = Invoke-Command -Session $remotesession -ScriptBlock {
        # Check the default number of MemberType on the system, CLSID that is being used as a reference is the built in "Shortcut" CLSID
        # CLSID located at HKEY_CLASSES_ROOT\CLSID\{00021401-0000-0000-C000-000000000046}
        $DefaultMember = [activator]::CreateInstance([type]::GetTypeFromCLSID("00021401-0000-0000-C000-000000000046","localhost"))
        $DefaultMemberCount = ($DefaultMember | Get-Member).Count
        # Release the COM Object that was instantiated for getting the reference count of default MemberTypes
        [System.Runtime.Interopservices.Marshal]::ReleaseComObject($DefaultMember) | Out-Null

        Return $DefaultMemberCount
    }

    # Create an array to store the potentially interesting DCOM applications
    $CLSIDCount = @()
    # Create an array to store the potentially vulnerable DCOM applications
    $VulnerableCLSID = @()
    # Create an array to store errors as a log
    $ErrorLog = @()

    # Read in the Blacklist depending on which OS was chosen
    switch($os) {
        "win7" {
            $DefaultBlackList = Get-Content -Path $Win7BlackListFile
        }
        "win10" {
            $DefaultBlackList = Get-Content -Path $Win10BlackListFile
        }
    }
    
    # Execute the following if block if the blacklist parameter is set
    if ($blacklist) {
        # Create an array to use as a future blacklist of known non-vulnerable / interesting DCOM applications
        $CustomBlackList = @()
        # Loop over the list with CLSIDs to be tested
        $CLSIDs | ForEach-Object {
            Try {
                $CLSID = $_
                # Check if the CLSID is on the blacklist
                if (-not ($CLSID | Select-String -Pattern $DefaultBlackList)) {
                    # Get the count of MemberType from the victim machine by instantiating it remotely 
                    $MemberCount = Invoke-Command -Session $remotesession -ScriptBlock {
                        Try {
                            # Instantiate the COM object by providing the CLSID and computername and count the number of MemberTypes
                            $COM = [activator]::CreateInstance([type]::GetTypeFromCLSID("$Using:CLSID","localhost"))
                            $MemberCount = ($COM | Get-Member).Count
                            # Release the instantiated COM object
                            [System.Runtime.Interopservices.Marshal]::ReleaseComObject($COM) | Out-Null -ErrorAction Continue
                            Return $MemberCount
                        } Catch [System.Runtime.InteropServices.COMException], [System.Runtime.InteropServices.InvalidComObjectException], [System.UnauthorizedAccessException] {
                            $ErrorLog += "[!] Caught Exception CLSID: $Using:CLSID"
                        }
                    } 
                    # Add the result to $CLSIDCount if it's more than 0 and not equal to the default amount of MemberTypes
                    if (-not ($MemberCount -eq $DefaultMemberCount) -and ($MemberCount -gt 0)) {
                        $CLSIDCount += "CLSID: $CLSID MemberType Count: " + $MemberCount
                        # Add the potentially vulnerable CLSIDs to the array
                        $VulnerableCLSID += $CLSID
                        
                    } else {
                        # Add the CLSIDs to be blacklisted
                        $CustomBlackList += $CLSID
                    }
                } else {
                    #Write-Host "[i] Blacklisted CLSID found, skipping..." -ForegroundColor Yellow
                    $CustomBlackList += $CLSID
                }
            } Catch [System.UnauthorizedAccessException]{
                $ErrorLog += "[!] CLSID: $CLSID Cannot be instantiated"
                $CustomBlackList += $CLSID
            }
        }
        
        # Call the function to write the blacklisted CLSIDs to
        Create-CustomBlackList($CustomBlackList)

    } else {
        $CLSIDs | ForEach-Object {
            Try {
                $CLSID = $_
                # Check if the CLSID is on the blacklist
                if (-not ($CLSID | Select-String -Pattern $DefaultBlackList)) {
                    $MemberCount = Invoke-Command -Session $remotesession -ScriptBlock {
                        Try {
                        # Instantiate the COM object by providing the CLSID and computername and count the number of MemberTypes
                        Write-Host "[+] Checking CLSID: $Using:CLSID"
                        $COM = [activator]::CreateInstance([type]::GetTypeFromCLSID("$Using:CLSID","localhost"))
                        $MemberCount = ($COM | Get-Member).Count
                        # Release the instantiated COM object
                        [System.Runtime.Interopservices.Marshal]::ReleaseComObject($COM) | Out-Null -ErrorAction Continue
                        Return $MemberCount
                        } Catch [System.Runtime.InteropServices.COMException], [System.Runtime.InteropServices.InvalidComObjectException], [System.UnauthorizedAccessException] {
                            $ErrorLog += "[!] Caught Exception CLSID: $Using:CLSID"
                        }
                    }
                    # Add the result to $CLSIDCount if it's more than 0 and not equal to the default amount of MemberTypes
                    if (-not ($MemberCount -eq $DefaultMemberCount) -and ($MemberCount -gt 0)) {
                        $CLSIDCount += "CLSID: $CLSID MemberType Count: " + $MemberCount
                        # Add the potentially vulnerable CLSIDs to the array
                        $VulnerableCLSID += $CLSID
                    }
                } else {
                    $ErrorLog += "[i] Blacklisted CLSID found: $CLSID"
                }
                                
            } Catch {
                $ErrorLog += "[!] CLSID: $CLSID Cannot be instantiated"
            }
        }
    }

    Create-ErrorLog($ErrorLog)

    Write-Host "[+] The following COM objects might be interesting to look into: " -ForegroundColor Green
    $CLSIDCount

    Write-Host "[+] Trying potentially vulnerable CLSIDs with $VulnerableSubsetFile" -ForegroundColor Green
    Get-VulnerableDCOM($VulnerableCLSID)
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

function Create-ErrorLog ($ErrorLog) {
    Write-Host "[i] Writing errors to logfile" -ForegroundColor Yellow

    Try {
        Out-File -FilePath .\"errorlog_$computername.txt" -InputObject $ErrorLog -Encoding ascii -ErrorAction Stop
    } Catch [System.IO.IOException] {
        Write-Host "[!] Failed to write output to file!" -ForegroundColor Red
        Write-Host "[!] Exiting..."
        Break
    }
    Write-Host "[+] Blacklisted DCOM application CLSID's written to $CLSIDFile" -ForegroundColor Green
}

# Function that checks the possible vulnerable DCOM applications with the textfile of strings
# NOTE: This checks with a max depth of 3
function Get-VulnerableDCOM($VulnerableCLSIDs) {
    <# 
    !!! NOTE !!!
    The following variable assignment is very bad practice, however I could not figure out how to suppress the errors thrown
    The suppressed errors are not of importance for enumerating this script. The errors are generated by looping over the 
    DCOM MemberTypes, if there are no more MemberTypes but the depth is less than 3 it generates the error
    !!! NOTE !!! 
    #>
    $ErrorActionPreference = 'SilentlyContinue'

    # Read in the subset file with strings that might indicate a vulnerability
    $VulnerableSubset = Get-Content $VulnerableSubsetFile

    # Create array to store potentially vulnerable CLSIDs
    $VulnerableCLSID = @()

    Write-Host "[i] This might take a while...`n" -ForegroundColor Yellow
    # Loop over the interesting CLSIDs from the function Get-MemberTypeCount
    $VulnerableCLSIDs | ForEach-Object {
        $CLSID = $_ 
        Write-Host "[i] Checking CLSID: $CLSID" -ForegroundColor Yellow
        $Vulnerable = Invoke-Command -Session $remotesession -ScriptBlock {
            # Instantiate the CLSID
            $COM = [activator]::CreateInstance([type]::GetTypeFromCLSID($Using:CLSID, "localhost"))
            # Get all the members of depth 1
            $COMMemberNames1 = $COM | Get-Member | ForEach-Object {$_.Name}
            # Create an array for members of depth 3
            $COMMembers3 = @()
            Try {
                # Loop over the members and their names (Depth 1)
                $COMMemberNames1 | ForEach-Object {
                    $COMName1 = $_
                    $COMMembers2 = $COM.$COMName1
                    if ((Get-Member -InputObject $COMMembers2).Count -ne 12) {
                        Get-Member -InputObject $COMMembers2 | ForEach-Object {
                            # Check if the membernames are present in the subset with strings that might indicate a vulnerability
                            if ($_.Name | Select-String -Pattern $Using:VulnerableSubset) {
                                $COMMembers3 += "[+] Possible Vulnerability found: $_ CLSID: $Using:CLSID Path: " + $COM + "." + $COMName1
                            }
                        }
                    }
                    # Loop over the members and their names (Depth 2)
                    $COMMembers2 | ForEach-Object {
                        $COMMember2 = $_
                        if ((Get-Member -InputObject $COMMember2).Count -ne 12) {
                            Get-Member -InputObject $COMMember2 | ForEach-Object {
                                # Check if the membernames are present in the subset with strings that might indicate a vulnerability
                                if ($_.Name | Select-String -Pattern $Using:VulnerableSubset) {
                                    $COMMembers3 += "[+] Possible Vulnerability found: $_ CLSID: $Using:CLSID Path: " + $COM + "." + $COMName1 + "." + $_.Name
                                }
                            }
                        }
                        # Loop over the members and their names (Depth 3)
                        Get-Member -InputObject $COMMember2 | ForEach-Object {$_.Name} | ForEach-Object {
                            $COMMember3 = $_
                            $COMName2 = $COMMember2.$COMMember3
                            if ((Get-Member -InputObject $COMName2).Count -ne 12) {
                                Get-Member -InputObject $COMName2 | ForEach-Object {
                                    # Check if the membernames are present in the subset with strings that might indicate a vulnerability
                                    if ($_.Name | Select-String -Pattern $Using:VulnerableSubset) {
                                        $COMMembers3 += "[+] Possible Vulnerability found: $_ CLSID: $Using:CLSID Path: " + $COM + "." + $COMName1 + "." + $COMMember3 + "." + $_.Name
                                    }
                                }
                            }
                        }
                    }
                }
                Return $COMMembers3
                [System.Runtime.Interopservices.Marshal]::ReleaseComObject($COM) | Out-Null -ErrorAction Continue
            } Catch [System.InvalidOperationException], [Microsoft.PowerShell.Commands.GetMemberCommand] {
                Write-Host "[i] Caught exception"
            }
        }
        $VulnerableCLSID += $Vulnerable
    }
    # Output the potentially vulnerable MemberTypes and CLSIDs, remove duplicates
    $OutputVulnerableCLSID = $VulnerableCLSID | Sort-Object -Unique

    # Write the possible Vulnerable DCOM applications to file
    Write-Host "[i] Writing possible vulnerable DCOM applications to: $PossibleVulnerableFile" -ForegroundColor Yellow
    Try {
        Out-File -FilePath .\$PossibleVulnerableFile -InputObject $OutputVulnerableCLSID -Encoding ascii -ErrorAction Stop
        Write-Host "[i] Written possible vulnerable DCOM applications to: $PossibleVulnerableFile" -ForegroundColor Yellow
    } Catch [System.IO.IOException] {
        Write-Host "[!] Failed to write output to file!" -ForegroundColor Red
        Write-Host "[!] Exiting..."
        Break
    }
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