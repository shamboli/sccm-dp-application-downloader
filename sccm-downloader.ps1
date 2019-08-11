########################################################################################################################
# Title:       Project ARCUS
# Date:        06/13/2016
#
# Description: Client-side script for rebuilding SCCM packages. Pulls packages from SCCM DP via HTTP.
#			   Downloads are called via Invoke-WebRequest, however, this can easily be modified to
#			   support BITS or .NET web requests. This script requires no administrator access to run,
#			   only user web access and the names of the proper SCCM servers. Advanced package information
#			   can be retrieved by a user in the site ConfigMgr group (or one that can run a WMI query on a given server) 
#			   but this information can also be obtained by using the signature files available under SMSSIG$.
#
#			   This script allows any user to retrieve packages from an SCCM server via HTTP, permitting the server 
#			   name is known. At the current time, this version is only designed for use on one machine. This may be changed
#			   in future versions.
# 
# Caveats:     This script runs and stores data locally on the user's machine, but is designed more towards being 
#		       distributed as a "multi-machine" computational process. The more machines available to process the resultant
#		       packages, the faster they will be downloaded (400+ packages split over 8 machines is faster than 1 doing 400).
#		       This software can also be pushed directly to a network share, however, depending on the availability of the server
#		       accepting the files, this may end up being significantly slower than writing locally, zipping, 
#			   copying and unzipping the packages remotely. The worldwide version calls for 150GB of storage space to run correctly
#			   as there are some rather large packages, and it's difficult to determine the total file size of the SCCM repository before 
#			   beginning. This can be overridden by calling the script with an optional int32 parameter with the desired size.
# 
# Usage:	   Follow the on-screen prompts. 
########################################################################################################################
clear

Write-Host "Welcome to the Project ARCUS (LTN Build). Follow the prompts below."`n
Write-Host "To determine the IIS version, navigate to the server website, eg:"
Write-Host "http://sccm-server.contoso.com"`n


# Detect override
$sizeOverride = $args[0]
if ($sizeOverride -is [int]) {
	# Override size 
	Write-Host "Size override detected. Disk req is currently $sizeOverride GB"`n
	$totalSpace = $sizeOverride
} else {
	# default size
	$totalSpace = "25"
}

##### Initial user input #####
#
# Grab SCCM server names
$serverName = Read-Host "Enter the distribution point server name (eg, sccm-server.contoso.com)"
# Ask user if they have ConfigMgr for proper naming conventions
$configMgr = Read-Host "Is this account in a ConfigMgr group (Y/N)"
if($configMgr -eq "y") {
	$rootServer= Read-Host "Enter an upstream SCCM server name (eg, sccm-server.contoso.com)"
	$siteCode = Read-Host "Enter the site code associated with the above (eg, US1)"
} else {
	# Add possible crappy parse for the future
	Write-Host "No ConfigMgr access returned."`n
}
##### Initial user input #####


##### Initialize variables #####
#
$pkgPath = "$env:UserProfile\Packages\"
$sigTempPath = Join-Path $pkgPath "Signatures"
$iniTempPath = Join-Path $pkgPath "INITemp"
$iniResultPath = Join-Path $pkgPath "Result"
$iniWeb = "http://$serverName.contoso.com/SMS_DP_SMSPKG$/pkglib"
$pkgWeb = "http://$serverName.contoso.com/SMS_DP_SMSPKG$/"
$sigWeb = "http://$serverName.contoso.com/SMS_DP_SMSSIG$/" 
$a = 0

# Delete original folder
Remove-Item "$env:UserProfile\Packages" -Recurse -Force -EA SilentlyContinue | Out-Null

# Test INI path ¿¿¿¿¿
if (test-path $iniResultPath) {
	Write-Host "INI result path exists. Proceeding..."
} else {
	Write-Host "INI result path missing. Writing path."
	New-Item $iniResultPath -type directory -Force | Out-Null
}
#
##### Initialize variables #####

##### Functions #####
# RetrieveNameFromRoot - Pulls package name from root SCCM server
# Seems like this needs ConfigMgr access. Use RetrieveNameFromSig for now.
Function RetrieveNameFromRoot([string]$ContentID, [string]$rootServer, [string]$siteCode) {	
	Get-WMIObject -Namespace root\sms\site_$siteCode -Computername $rootServer -class SMS_DeploymentType -Property "LocalizedDisplayName" -filter "ContentID = '$($ContentID.Split(".")[0])'" | Select -ExpandProperty LocalizedDisplayName -Unique
}
#
# RetrieveNameFromSig - Pulls "generalized" package name from given SCCM server based on contentID. The names are rather unreliable.
Function RetrieveNameFromSig([string]$contentID) {
	# Build filepath
	$sigTempName = [string](GenerateRandomString) + ".ARC"
	$contentSig = $contentID + ".tar"
	$combinedPath = $sigWeb + $contentSig
	
	# Download and parse for string
	Invoke-WebRequest $combinedPath -OutFile $sigTempName
	$sigValue = ((Get-Content $sigTempName) -split "`0")[0]

	# Delete temp file & return
	Remove-Item -path $sigTempName -Force
	return $sigValue
}
#
# GenerateRandomString - Generates random string of 11 characters, utilizing uppercase letters of the alphabet
Function GenerateRandomString() {
	$length = "11"
	$sourceData = $NULL
    for ($a=65;$a -le 90;$a++) {
        $sourceData+=,[char][byte]$a
    }
	for ($loop=1; $loop -le $length; $loop++) {
		$tempString+= ($sourceData | Get-Random)
	}
	$tempString = "ARCUS_" + $tempString
	return $tempString
}
#
# Copy-Folder - Pulls packages recursively via http 
Function Copy-Folder([string]$source, [string]$destination) {
    if (!$(Test-Path($destination))) {
		Write-Host `n"Directory does not exist. Creating directory."`n $destination
        New-Item $destination -type directory -Force | Out-Null
    } 	
    # Get the initial file list from the web page
	$webString = (Invoke-WebRequest $source).Content
	
    $lines = [Regex]::Split($webString, "<br>")
    # Parse each line, looking for files
    foreach ($line in $lines) {
		#write-host $line
		if ($line.ToUpper().Contains("HREF")) {
            # File or Folder
            if (!$line.ToUpper().Contains("&lt;dir&gt")) {
                # Not Parent Folder entry
                $items =[Regex]::Split($line, """")
                $items = [Regex]::Split($items[2], "(>|<)")
                $item = $items[2]
				
				#write-host $item
				$itemName = Split-Path $item -Leaf
				# Get the header of the item to determine if it's a file or a directory
				$response = Invoke-WebRequest -Method Head -Uri $source$itemName | Select -ExpandProperty RawContent
				
				if (!($response -match "Content-Length: 0")) {
					# File
					Write-Host "Processing file: " $itemName
					Invoke-WebRequest $source$itemName -OutFile $destination$itemName
					#Write-host "Path: " $source$itemName
					#Write-Host "Destination: " $destination$itemName
				} else {
					# "Folder"
					$itemName = $itemName+"\"
					Write-host `n"* Folder found, processing: " $itemName
					Copy-Folder $source$itemName $destination$itemName
				}
			}
        }
    }
}
#
# PullINIFromServer - Grabs all the INI files for parsing
Function PullINIFromServer {
	$iniList = @(Invoke-WebRequest $iniWeb -UseBasicParsing | Select -ExpandProperty Links | Select -Property Href)
	foreach ($item in $iniList.Href) {
		$itemName = Split-Path $item -Leaf
		Invoke-WebRequest $item -OutFile "$iniTempPath\$itemName"
	}

	# Grab all the Content_ parameters and strip duplicates
	Get-ChildItem $iniTempPath | Select-String -Pattern "Content_" | ForEach {($_.Line).Replace('=','')} | Set-Content "$iniResultPath\Result.ini"
	Write-Host "Packages identified: " (Get-Content "$iniResultPath\Result.ini").Count
	
	# Delete original INIs
	Remove-Item $iniTempPath -Recurse -Force -EA SilentlyContinue | Out-Null
}
#
# RemoveInvalidChars - Removes invalid characters before building a file path
Function RemoveInvalidChars([string]$invalidString) {
	$invalidChars = [IO.Path]::GetInvalidFileNameChars() -join ''
	$re = "[{0}]" -f [RegEx]::Escape($invalidChars)
	$invalidString -replace $re
}
#
##### Functions #####

##### Main #####
# Check for available disk space before setup 
$diskSpace = Get-WmiObject Win32_LogicalDisk -Filter "DeviceID='C:'" | Select-Object Size,FreeSpace
$diskSpaceGB = [math]::Floor((($diskSpace.FreeSpace) / 1GB ))
if ($diskSpaceGB -ge $totalSpace) {
	## Run 
	if (test-path $pkgPath) {
		Write-Host "Package path exists. Proceeding..."`n
	} else {
		Write-Host "Package path missing. Creating path!"`n
		New-Item $pkgPath -type directory -Force | Out-Null
	}
	# Signature temp path
	if (test-path $sigTempPath) {
		Write-Host "Signature temp path exists. Proceeding..."`n
	} else {
		Write-Host "Signature temp path missing. Creating path!"`n
		New-Item $sigTempPath -type directory -Force | Out-Null
	}
	# Pull INIs from server
	if (test-path $iniTempPath) {
		Write-Host "INI temp path exists. Proceeding..."`n
	} else {
		Write-Host "INI temp path missing. Creating path!"`n
		New-Item $iniTempPath -type directory -Force | Out-Null
		
		# Build new INI repo
		Write-Host "Amalgamating INI files from $serverName."`n
		PullINIFromServer $iniWeb
	}
	
	# Actual script 
	$iniResultPath = Join-Path $iniResultPath ("Result.ini")
	$contentNames = Get-Content "$iniResultPath"
	
	$start = Get-Date
	$a = 0
	Write-Host "Resolving names from content identifiers." 
	$itemList = @()
	ForEach ($item in $contentNames) {
		$itemObject = New-Object -TypeName PSObject
		if($configMgr -eq "y") {
			# ConfigMgr WMI query for proper package naming
			# Add invocation over runspace pool instead of serially downloading
			$pkgName = RetrieveNameFromRoot $item $rootServer $siteCode

			
			$itemObject | Add-Member -Type NoteProperty -Name "DisplayName" -value $pkgName -Force
			$itemObject | Add-Member -Type NoteProperty -Name "ContentID" -value $item -Force

		} else {
			# FIX ME LATER
			# Supplementary query to for sub par package naming from signature
			$pkgName = RetrieveNameFromSig $item
			
			$itemObject | Add-Member -Type NoteProperty -Name "DisplayName" -value $pkgName -Force
			$itemObject | Add-Member -Type NoteProperty -Name "ContentID" -value $item -Force
		}
		
		$itemList += $itemObject
		
		# Percent
		$a++
		$contentAmount = $contentNames.Count
		$percentComplete = ($a/$contentAmount*100)
		$percentRounded = [math]::round($percentComplete,2)
		
		# Time 
		$elapsed = (Get-Date) - $start
		$totalTime = ($elapsed.TotalSeconds) / ($percentRounded / 100.0)
		$remain = $totalTime - $elapsed.TotalSeconds
		$eta = (Get-Date).AddSeconds($remain)
		
		# Display bar
		Write-Progress -Activity "Resolving names from $rootServer. Completion time: $eta" -status "Percent complete:  " -PercentComplete $percentComplete -CurrentOperation "$percentRounded% complete. `r`r`r`r $a records of $contentAmount resolved." -ID 1
	}

	$userChoice = $itemList | Out-GridView -Title "Resolved Content Names" -PassThru 
	
	$a = 0 
	foreach($item in $userChoice) {
		# Build package paths 
		$itemPath = [IO.Path]::Combine($pkgPath, "Downloaded", (RemoveInvalidChars $item.DisplayName))
		if ($(Test-Path($itemPath))) {
			Write-Host `n"Directory exists, creating incremented directory."`n$itemPath
			$itemPath = $itemPath+(1)
			New-Item $itemPath -type directory -Force | Out-Null
		}
		
		write-host $pkgWeb$item/
		
		$itemWebName = $item.ContentID
		Copy-Folder "$pkgWeb$itemWebName/" "$itemPath\" 
		
		# Percent
		$a++
		$contentAmount = $contentNames.Count
		$percentComplete = ($a/$contentAmount*100)
		$percentRounded = [math]::round($percentComplete,2)
		
		# Time 
		$elapsed = (Get-Date) - $start
		$totalTime = ($elapsed.TotalSeconds) / ($percentRounded / 100.0)
		$remain = $totalTime - $elapsed.TotalSeconds
		$eta = (Get-Date).AddSeconds($remain)
		
		# Display bar 
		Write-Progress -Activity "Writing package data to $itemPath. Completion time: $eta" -status "Percent complete: " -PercentComplete $percentComplete -CurrentOperation "$percentRounded% complete. `r`r`r`r $a records of $contentAmount retrieved."
	}

} else {
	## Quit
	Write-Host "Not enough free space to continue operation. Press any key to exit."
	#ps4... $x = $host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
	cmd /c pause | Out-null
	exit
}