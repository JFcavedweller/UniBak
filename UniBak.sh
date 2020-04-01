#!/bin/bash
#---------------------------------------------------------------------------------------
#title: "UniBak" Unix Backup and Restore Script
version="0.21.2"
#author: Matt Hooker
#created: 2013-10-28
#maintainer: Matt Hooker
#contributors: Michaela Bixler
modifiedDate="2020-04-01"
devVar="n" #set to "y" when developing to prevent overwriting
#---------------------------------------------------------------------------------------
# this script is a multiplatform branch of MacBak v1.5.2, which was originally written by Dave Culp and updated by Matt Hooker before adapting to multiplatform
#---------------------------------------------------------------------------------------
#exit codes:
#0) script completed, no errors
#1) script was not run with sudo
#2) operating system not identified yet
#3) script needed to be updated
#4) not restoring data in linux
#5) backup size for server was manually rejected
#6) logged in user was not the user to have data restored to
#7) exit for windows restore
#8) exit for mac restore
#9) invalid backup/restore selection
#---------------------------------------------------------------------------------------
###global variables:######################################################################
if logname 2>&1&> /dev/null #if logname doesn't give an error, as it can in some ubuntu instances
	then
		currentUser="$(logname)"
elif [ "$SUDO_USER" != "" ] #if the $SUDO_USER variable is something, indicating who the current user is (doesn't work on mac)
	then
		currentUser="$SUDO_USER"
	else
		currentUser=$(who | awk -F ' ' '{print $1}') #alternate for finding who is logged on, but won't work if multiple users are currently logged in
fi
currentUID=$(id -u $currentUser) #retrieves the UID of the logged-in user, for permissions when mapping the server in linux
uname=$(uname -a) #determines host kernel
baseName=$(basename "$0") #name of the script
dirName=$(dirname "$0") #relative directory of where the script is located
date=$(date +%Y-%m-%d) #today's date
toolDir="hdimages/tools"
tmpDir="/tmp" #temporary directory. the idea is that the files going here are only used for a short time then can be deleted
tmpfile="$tmpDir/UniBakTemp.txt" #generic multiuse temp file
usersLog="$tmpDir/UsersLog.txt" #list of users. used for fncSourceFileSizeEstimate and fncRollCall
itemsLog="$tmpDir/ItemsLog.txt" #multiuse temp file for listing directory contents for adding to arrays later
logfileName="$date""_UniBak_log.txt" #main UniBak log, to be stored in the destination
dislockerRepo="http://www.hsc.fr/ressources/outils/dislocker/download/" #web path to dislocker download ($dislockerTar excluded since it has other uses)
dislockerTar="dislocker.tar.bz2" #dislocker tar file
###candidates for removal:################################################################
failureText="*** Skipping any contents from this failed directory ***"
profileListFile="profiles.txt"
duExclude="--exclude=*/AppData --exclude=*/Dropbox --exclude=*/Google?Drive --exclude=*/OneDrive --exclude=*/SkyDrive --exclude=*/Library --exclude=*/.trash --exclude=*/.Trash --exclude=*/.local --exclude=*/.cache --exclude=likewise-open --exclude=lost+found --exclude=.ecryptfs" #items to not count when using du to calculate profile sizes
###host-specific variables:###############################################################
if [[ "$uname" == *Linux* ]] || [[ "$uname" == *Ubuntu* ]] || [[ "$uname" == *Debian* ]] || [[ "$uname" == *debian* ]] #detects Linux kernel
	then
		host="linux" #identifies host OS throughout the script
		mountPrefix="/mnt" #where the script will create mount points
elif [[ "$uname" == *Darwin* ]] || [[ "$uname" == *Mac* ]] #detects Darwin kernel (OSX)
	then
		host="mac" #identifies host OS throughout the script
		mountPrefix="/Volumes" #where the script will create mount points
	else #error handling for if Linux or OSX are not properly detected
		echo "Operating system not identified, please update $baseName accordingly for the following uname result:"
		echo "$uname"
		exit 2
fi
###configurable variables:################################################################
scriptRepo="https://raw.githubusercontent.com/JFcavedweller/$(echo "$baseName" | awk -F '.sh' '{print $1}')/master" #web link for downloading script update
scriptRepoDevWeb="http://helpdesk.liberty.edu/hdtools/Tech%20Projects%20&%20Source%20Code%20Files/$(echo "$baseName" | awk -F '.sh' '{print $1}')/development%20version" #web link for downloading dev version of script PLEASE UPDATE #debug
if [ $(date +%j) -gt 181 ] #determines the fiscal year based on 7/1-6/30
	then
		fiscalYear=$(($(date +%Y)+1)) #current year +1 if currently in the next calendar year's fiscal year
	else
		fiscalYear=$(date +%Y) #current year if calendar and fiscal years match
fi
server=("fs3.liberty.edu") #list of servers to be recursively mounted when fncServerMount is called
share=("hdbackups") #list of shares to be recursively mounted when fncServerMount is called, and the index of this list must match server
mountpoint=("hdbackups") #list of mount point names to be recursively mounted when fncServerMount is called, and the index of this list must match server
likewisePath="likewise-open/SENSENET" #if using likewise-open to handle domain account logins, specify the path here
scriptRepoMain="/$mountPrefix/$toolDir/scripts" #filesystem path to where scripts are located
logDir="/$mountPrefix/hdbackups/logs" #filesystem path to collective log archive
###global functions#####################################################################
function fncRootCheck { #checks that the script is run with elevated permissions frev=0 fmod=0
	uid=$(id -u)
	if [ "$uid" != "0" ]
		then
			read -p "Please run this script as the logged-in user with 'sudo' preceding the command."
			exit 1
	fi
} #end fncRootCheck
function fncVersionCompare { # compares version of script local copy $1 to production copy $2, and outputs $versionNewest frev=2 fmod=0 frevDate=2015-10-09
	feelerCorrupt="n" #presets to "n" since this script may be called recursively
	localFeeler="$(cat "$1" 2> /dev/null)" #reads the entire first (usually local version is called) copy of the script
	feeler="$(cat "$2" 2> /dev/null)" #reads the entire second (usually server's production or dev version is called) copy of the script
	localFeelerVersion=$(echo "$localFeeler" | grep "version=" | head -1 | awk -F '"' '{print $2}') #reads the version number from the first script
	feelerVersion=$(echo "$feeler" | grep "version=" | head -1 | awk -F '"' '{print $2}') #reads the version number from the second script
	if [ "$feelerVersion" = "" ]
		then
			feelerCorrupt="y" #if the second script's version cannot be determined, then it is flagged as corrupt
		else
			localFeelerDev=$(echo "$localFeeler" | grep "devVar=" | head -1 | awk -F '"' '{print $2}') #checks if the first script is a dev version
			if [ "$localFeelerVersion" = "$feelerVersion" ] #versions are the same
				then
					versionNewest="same"
				else
					versionNum=$(echo "$localFeelerVersion" | awk -F. '{ printf("%d%03d%03d%03d\n", $1,$2,$3,$4); }') #formats version number for comparison
					feelerVersionNum=$(echo "$feelerVersion" | awk -F. '{ printf("%d%03d%03d%03d\n", $1,$2,$3,$4); }') #formats version number for comparison
					feelerTest=("$versionNum" "$feelerVersionNum") # puts the two version numbers in an array for comparison
					first=$(printf "%s\n" "${feelerTest[@]}" | sort -nr | grep -m 1 -o '[0-9]\+') #sorts numbers by name such that highest is on top, and only that is read
					if [ "$versionNum" == "$first" ] #local version is more recent
						then
							versionNewest="local"
						else
							versionNewest="server"
					fi
			fi
	fi
} #end fncVersionCompare
function fncSelfUpdater { #script self-updater frev=11 fmod=0 frevDate=2019-10-02
	#requires $uname, $dirName, $baseName, $scriptRepoMain, $scriptRepoDevWeb, $tmpDir, $devVar, fncVersionCompare frev=1+, fncMasterInstaller
	#$1 is -u to force self-update, $2 is -s to sync (specify a different script to update, and use a placeholder for $1), $3 is the script to update if $1 is -s
	function fncSelfUpdater_doTheThing { #embedded function that handles version comparing and what to do once a fresh copy of the script has been downloaded
		fncVersionCompare "$localScript" "$prodScript"
		if [ "$feelerCorrupt" = "y" ]
			then
				echo "Unable to determine the production version of $localScriptName. Source may be missing, corrupt, or otherwise inaccessible"
		elif [ "$1" != "-u" ] && [ "$1" != "-d" ] && [ "$versionNewest" == "same" ] #if versions match and the -u switch is not used
			then
				echo "$localScriptName is currently at the most recent release version ($feelerVersion), and will not be updated"
		elif [ "$versionNewest" == "local" ] && [ "$localFeelerDev" != "y" ]
			then
				echo "The local copy of $localScriptName v$localFeelerVersion is newer than v$feelerVersion which is on the server. Please run \"sudo UpdatePusher.sh push\""
		elif [ "$1" != "-u" ] && [ "$1" != "-d" ] && [ "$localFeelerDev" = "y" ] && [ "$versionNewest" = "local" ] #else if not forcing update, and if dev that it is new enough to be valid
			then
				echo "This is a current development version of $localScriptName, not updating..."
				echo "Exit and run script with \"-u\" to update to latest production version."
				echo "Exit and run script with \"-d\" to update to latest development version."
				sleep 2
			else #if the above conditions are not met, downloads the current release of the script to the originating location
				echo "Updating $localScriptName..."
				rm "$localScript" 2> /dev/null
				rsync -q "$prodScript" "$localScript"
				chmod +x "$localScript" #necessary to make script executable for all linux and OSX Mavericks and newer
				chown "$currentUser" "$localScript" 2> /dev/null #sets current user as the owner
				echo "Updated $localScriptName has been downloaded to $dirName."
				if [ "$2" != "-s" ] #if the script is not pulling fresh copies of other scripts, then exit
					then
						exit 3
				fi
		fi
	}
	if [ "$2" = "-s" ] #if sync switch is used
		then
			localScript="$dirName/$3"
			localScriptName="$3"
			prodScript="$scriptRepoMain/$3"
	elif [ "$1" = "-d" ] #if dev version download is selected
		then
			localScript="$dirName/$baseName"
			localScriptName="$(basename "$localScript")"
			prodScript="$tmpDir/$baseName"
			localFeelerDev="$devVar"
			scriptRepoSelection="$scriptRepoDevWeb"
		else #standard parameters for self updater
			localScript="$dirName/$baseName"
			localScriptName="$(basename "$localScript")"
			prodScript="$tmpDir/$baseName"
			localFeelerDev="$devVar"
			scriptRepoSelection="$scriptRepo"
	fi
	echo
	if [[ "$1" = "-q" ]] #manual skip of updating
		then
			echo "Updating skipped as specified with -q"
		else
			if [[ "$uname" == *Linux* ]] #VPN connection required to access helpdesk.liberty.edu/hdtools, checks first for Linux
				then
					#if [ ! -e /usr/sbin/openconnect ] #if openconnect is not installed, install it
					#	then
					#		packages=(openconnect)
					#		fncMasterInstaller
					#fi
					#if ! ps -A | grep openconnect > /dev/null #if openconnect is not running, run it
					#	then
					#		echo "Connecting to vpn.liberty.edu..."
					#		openconnect vpn.liberty.edu -b #connects to vpn.liberty.edu
					#		vpnConnected="true" #variable used to determine whether the session should be disconnected later
					#fi
					sleep 2
					echo
					echo "Downloading fresh copy of $baseName..."
					wget --no-check-certificate -qO "$prodScript" "$scriptRepoSelection/$baseName" #downloads fresh copy of script to tmpDir
					fncSelfUpdater_doTheThing
					#if [ "$vpnConnected" = "true" ]
					#	then
					#		killall openconnect
					#		vpnConnected=""
					#fi
				else #assumes mac if not Linux
					if [ -e /opt/cisco/anyconnect ] #if anyconnect is installed, call it
						then
							#if ! ps -A | grep anyconnect > /dev/null #if openconnect is not running, run it
							#	then
							#		echo "Connecting to vpn.liberty.edu..."
							#		anyconnect connect vpn.liberty.edu #connects to vpn.liberty.edu
							#		vpnConnected="true" #variable used to determine whether the session should be disconnected later
							#fi
							sleep 2
							echo
							echo "Downloading fresh copy of $baseName..."
							curl -fskL -o "$prodScript" "$scriptRepoSelection/$baseName" #downloads fresh copy of script to tmpDir
							fncSelfUpdater_doTheThing
								#if [ "$vpnConnected" = "true" ]
								#	then
								#		echo "Disconnecting from vpn.liberty.edu..."
								#		killall anyconnect
								#		vpnConnected=""
								#fi
					fi
			fi
	fi
} #end fncSelfUpdater
function fncMenuGenerator { #default navigational menu generator for the script frev=5 fmod=0 frevDate=2018-07-04
	while true
	do
		if [ "$1" != "noclear" ]
			then
				clear
		fi
		echo "*****************************************"
		echo "$menuTitle"
		echo "*****************************************"
		if [ "$menuHeader1" != "" ]
			then
				echo "[#] $menuHeader1$menuHeader2$menuHeader3"
		fi
		for i in ${!menuList[*]}
		do
			menuItem="${menuList[$i]}"
			menuItemTail="${menuListTails[$i]}"
			echo "[$(($i+1))]: $menuItem $menuItemTail"
		done
		echo "*****************************************"
		if [ "$menuExtra" = "y" ]
			then
				echo "$menuExtraText"
				echo "*****************************************"
		fi
		read -p "Select option and press 'Enter': " menuSelect
		menuSelect=$(echo "$menuSelect" | grep -o '[0-9]\+') #sanitizes the menu selection so that only numbers are allowed, to not throw an error when comparing in the next step
		if [[ "$menuSelect" -lt $(($i+2)) ]] && [[ "$menuSelect" -gt 0 ]]
			then
				break
			else
				continue
		fi
	done
	menuOutput="${menuList[$(($menuSelect-1))]}" #added an easy-to-use variable for output
	unset menuListTails
	menuExtra=n
} #end fncMenuGenerator
function fncDeviceMenuHandler { #handles menu selection of servers and storage devices frev=4 fmod=0 frevDate=2015-11-30
	unset menuList
	unset menuListTails
	unset menuListGhost1
	unset menuListGhost2
	if [ "$qstnIncludeServers" = "y" ] #if variable is set to include servers on the device list
		then
			for i in ${!share[*]} #adds servers to start of list. currently a for loop is not necessary, but ensures proper copying
			do
				if [ "${serverMountSuccess[$i]}" = "true" ] #checks that the server was mounted successfully
					then
						if df | grep -E "${server[$i]}[\/]+${share[$i]}" > /dev/null #this should always be true
							then
								mountpointTest=$(df | grep -E "${server[$i]}[\/]+${share[$i]}" | grep -Eo "$mountPrefix/${share[$i]}.*") #checks to see if the server is automounted to an unexpected location (ex. /Volumes/hdbackups-1 instead of /Volumes/hdbackups)
								if [ "$mountPrefix/${mountpoint[$i]}" != "$mountpointTest" ]
									then
										echo "\\\\${server[$i]}\\${share[$i]} was expected to be mounted to $mountPrefix/${mountpoint[$i]} but was mounted to $mountpointTest. Adjusting array to compensate..."
										mountpoint[$i]=$(echo "$mountpointTest" | grep -Eo "${share[$i]}.*") #updates mount point
										sleep 2
								fi
							else
								echo "Hesitant. \\\\${server[$i]}\\${share[$i]} does not appear to be mounted. Exiting script." #Elcor sanity check
								exit
						fi
						menuList[${#menuList[*]}]="server: \\\\${server[$i]}\\${share[$i]}"
						menuListGhost1[${#menuListGhost1[*]}]="\\\\${server[$i]}\\${share[$i]}" #server path without the "server: "
						menuListGhost2[${#menuListGhost2[*]}]="cifs" #type of filesystem. may later add functionality to determine the type
						if [ "$qstnIncludeFreeSpace" = "y" ]
							then
								fncEstimateFreedom $mountPrefix/${mountpoint[$i]}
								menuListTails[$((${#menuList[*]}-1))]="- $estimatedFreedom available"
						fi
				fi
			done
	fi
	fncFilesystemDetector #detects locally-connected storage
	rootPartition=$(df / | grep -Eo '/dev/[[:alnum:]]*') #determines which partition the root filesystem is on
	for i in ${!filesystemList[*]}
	do
		if [ "${filesystemListPartition[$i]}" != "$rootPartition" ] && [ "${filesystemListPartition[$i]}" != "$sourceDrivePartition" ] && [ "${filesystemListType[$i]}" != "swap" ]
			then
				menuList[${#menuList[*]}]="${filesystemList[$i]}"
				menuListGhost1[${#menuListGhost1[*]}]="${filesystemListPartition[$i]}" #retains match of partition label (/dev/*) for partitions added to the menu list
				menuListGhost2[${#menuListGhost2[*]}]="${filesystemListType[$i]}" #retains match of partition type for partitions added to the menu list
				mountCheck=$(df | grep "${filesystemListPartition[$i]}" | awk -F '% +' '{print $NF}')
				if [ "$qstnIncludeFreeSpace" = "y" ] && [ -n "$mountCheck" ] #only shows space available if the partition is mounted already
					then
						fncEstimateFreedom "${filesystemListPartition[$i]}"
						menuListTails[$((${#menuList[*]}-1))]="- ${filesystemListPartition[$i]} - $estimatedFreedom available"
				elif [ -n "$mountCheck" ] #mounted, but don't need to display free space
					then
						menuListTails[$((${#menuList[*]}-1))]="- ${filesystemListPartition[$i]}"
					else #not mounted
						menuListTails[$((${#menuList[*]}-1))]="- ${filesystemListPartition[$i]} (not mounted)"
				fi
		fi
	done
	menuList[${#menuList[*]}]="Manual Selection"
	fncMenuGenerator
	echo
	if [ "$menuSelect" = "${#menuList[*]}" ] #if the last option (manual) is selected
		then
			echo "Manually place the path to the correct drive..."
			read driveSelection
			driveSelection=$(echo "$driveSelection" | grep -Eo "[^\'].*[^\' *]") #strips off the single quotes, if dragging the location
		else
			driveSelectionPartition="${menuListGhost1[$(($menuSelect-1))]}" #/dev/* label for the selected partition
			driveSelectionType="${menuListGhost2[$(($menuSelect-1))]}" #filesystem type for the selected partition
			if [ "$driveSelectionType" != "cifs" ]
				then
					fncFilesystemMounter $driveSelectionPartition
				else
					for i in ${!share[*]} #checks selection against available servers
					do
						if [ "${menuList[$(($menuSelect-1))]}" = "server: \\\\${server[$i]}\\${share[$i]}" ]
							then
								driveSelection="$mountPrefix/${mountpoint[$i]}/backups"
								break #breaks the for loop if the server matches and was mounted properly
						fi
					done
			fi
	fi
	unset qstnIncludeServers
	unset qstnIncludeFreeSpace
} #end fncDeviceMenuHandler
function fncFilesystemDetector { #detects all filesystems connected to the computer, whether mounted or not frev=0 fmod=0 frevDate=2015-10-14
	if [ "$host" = "linux" ]
		then
			filesystemList=($(ls /dev/disk/by-uuid/)) #/dev/disk/by-uuid/ lists all connected filesystems by uuid
			for i in ${!filesystemList[*]}
			do
				filesystemBlkid=$(blkid | grep ${filesystemList[$i]})
				filesystemListPartition[$i]=$(echo "$filesystemBlkid" | awk -F ':' '{print $1}') #finds the device label (/dev/sd?)
				filesystemListType[$i]=$(echo "$filesystemBlkid" | awk -F 'TYPE="' '{print $2}' | awk -F '"' '{print $1}') #finds the filesystem type
				if [[ "$filesystemBlkid" = *\ LABEL=* ]]
					then
						filesystemList[$i]=$(echo "$filesystemBlkid" | awk -F ' LABEL="' '{print $2}' | awk -F '"' '{print $1}') #replaces the UUID with the label
				fi
			done
	elif [ "$host" = "mac" ]
		then
			diskutilOutput="$(diskutil list | grep '[0-9]:' | grep -v 'GUID_partition_scheme' | grep -v 'EFI EFI')" #all visible and valid partitions, updated for Sierra +
			filesystemListPartition=($(echo "$diskutilOutput" | awk -F ' ' '{print $NF}'))
			filesystemListType=($(echo "$diskutilOutput" | awk -F ' ' '{print $2}'))
			for i in ${!filesystemListPartition[*]}
			do
				filesystemList[$i]=$(echo "$diskutilOutput" | grep "${filesystemListPartition[$i]}" | awk -F "${filesystemListType[$i]} " '{print $2}' | awk -F ' +[0-9|.]* [T|G|M|K]B' '{print $1}')
				if [ "${filesystemList[$i]}" = "" ] #if there is no mount point
					then
						filesystemList[$i]="${filesystemListPartition[$i]}"
				fi
				filesystemListPartition[$i]="/dev/${filesystemListPartition[$i]}"
			done
		else
			echo "Error: host $host not recognized. Panic. Aaaaaaaahhhhhhhh."
	fi
} #end fncFilesystemDetector
function fncFilesystemMounter { #handles automatic, advanced mounting of $1 (/dev/sd?) frev=0 fmod=0 frevDate=2015-10-14]
	unset qstnBitlocker
	mountCheck=$(df | grep "$1" | awk -F '% +' '{print $NF}')
	if [ -z "$mountCheck" ] #if there is no mount point for $1
		then
			tempMount="$mountPrefix/tmp"
			if [ ! -d "$tempMount" ] #creates mount point if necessary
				then
					mkdir "$tempMount"
			fi
			umount "$tempMount" 2>&1&> /dev/null
			if [ "$platformMode" = "linux4windows" ]
				then
					unset menuList
					unset menuListTails
					menuTitle="Does this drive use bitlocker?"
					menuList=("no" "yes")
					fncMenuGenerator
					qstnBitlocker="$menuOutput"
			fi
			if [ "$qstnBitlocker" = "yes" ] #prompts for mounting bitlocker filesystem
				then
					tempMount="$mountPrefix/tmp"
					unset menuList
					unset menuListTails
					menuTitle="Is dislocker installed?"
					menuList=(no yes)
					fncMenuGenerator
					dislockerInstalled="$menuOutput" #dislocker is a utility for mounting bitlocker-encrypted filesystems. if this check fails, then the source will be downloaded, compiled, and installed
					echo
					if [ "$dislockerInstalled" = "no" ] #downloads, compiles, installs dislocker if not present
						then
							pwd=$(pwd) #saves present working directory
							cd /opt
							wget --no-check-certificate -qO "/opt/$dislockerTar" "$dislockerRepo/$dislockerTar" #Download dislocker
							echo "Downloaded $dislockerTar"
							tar -xvf "/opt/$dislockerTar" #extract tar
							if [ -d "/opt/dislocker/src" ] #makes sure that download succeeded (subfolder present)
								then
									packages=(gcc cmake make libfuse-dev libpolarssl-dev ruby-dev) #required packages for dislocker
									fncMasterInstaller
									cd /opt/dislocker/src
									cmake .
									make
									sudo make install​
								else
									echo "Unable to download Dislocker"
									rm "/opt/$dislockerTar"
									rmdir "/opt/dislocker"
									exit
							fi
							cd "$pwd" #switches back to the previous working directory
					fi
					while true #verifies that dislocker is installed
					do
						if man dislocker 2>&1&> /dev/null #this will determine whether dislocker is installed properly
							then
								break
							else
								clear
								echo "Dislocker is not properly installed."
								echo "Please install manually by doing the following:"
								echo
								echo "Open a new terminal window or tab"
								echo "type 'cd /opt/dislocker/src'"
								echo "type 'cmake .' (don't forget the space, period)"
								echo "type 'make'"
								echo "type 'sudo make install'"
								echo
								read -p "Press 'Enter' in this window when complete."
								continue
						fi
					done
					while true
					do
						#read -p "Type 'r' to use the recovery key, or 'p' for the standard pin: " keymode
						keymode=r #this is set manually for now, as Dislocker does not actually support entering the regular pin. may add .bek file functionality later
						if [ "$keymode" = "r" ] || [ "$keymode" = "R" ] #will use the recovery key
							then
								echo "Please enter the recovery key (include dashes):"
								read bitlockerkey
								if [ ! -d "$mountPrefix/dislocker" ]
									then
										mkdir "$mountPrefix/dislocker"
								fi
								umount $mountPrefix/dislocker
								dislocker -V "$1" -p$bitlockerkey -- $mountPrefix/dislocker
								mount -o loop $mountPrefix/dislocker/dislocker-file "$tempMount" #attempts to mount a bitlocker-encrypted filesystem using the recovery key
						elif [ "$keymode" = "p" ] || [ "$keymode" = "P" ] #will use the pin number
							then
								read -p "Please enter the pin number: " bitlockerkey
								dislocker -V "$1" -c$bitlockerkey -- $mountPrefix/tmp #attempts to mount a bitlocker-encrypted filesystem using the recovery key
							else
								echo "Invalid selection. Please press 'p' or 'r' when asked." #typing 'r' or 'p' is apparently difficult. you will now hear about it
						fi
						if [ -d "$tempMount/$homes" ] #checks for successful mount
							then
								break
							else
								echo "Unsuccessful mount. Try again."
								continue
						fi
					done
				else #if not bitlocker mode
					if [ "$host" = "linux" ]
						then
							if [ "$driveSelectionType" = "ntfs" ]
								then
									driveSelectionType="ntfs-3g" #mount uses '-t ntfs-3g' for ntfs partitions
							fi
							echo "Attempting normal mount of $1 to $tempMount..."
							mount -t "$driveSelectionType" "$1" "$tempMount" #standard mount attempt
							if ! df | grep "$1" 2>&1&> /dev/null #checks for successful mount
								then
									echo "$1 unable to mount to $tempMount. Trying to mount forcefully..."
									mount -t "$driveSelectionType" -o ro,remove_hiberfile "$1" "$tempMount" #forceful, read-only mount and also removes hiberfil
							fi
					elif [ "$host" = "mac" ]
						then
							read -p "Currently unable to force mount for mac. Please do so manually, then press 'Enter'"
					fi
					if ! df | grep "$1" 2>&1&> /dev/null #checks for successful mount
						then
							echo "$1 unable to mount to $tempMount after forceful attempt. Try another method of data access."
							exit
					fi
			fi #end qstnBitlocker if
			driveSelection="$tempMount"
		else
			driveSelection="$mountCheck"
	fi
} #end fncFilesystemMounter
function fncPrimaryUserHandler {
	unset menuList
	unset menuListTails
	for i in ${!usersList[*]}
	do
		menuList[$i]="${usersList[$i]}"
	done
	fncMenuGenerator
	echo
	userSelection="${menuList[$(($menuSelect-1))]}" #converts the index to the selected username
}
function fncRealityCheck { #verifies that the backup location is not on the same partition as the system root. this should not be necessary, but technology happens frev=0 fmod=0 frevDate=2015-10-05
	sourceTest="$(df "$source" | awk -F ' ' '{print $1}' | awk -F 'Filesystem' '{print $1}')"
	destTest="$(df "$destination" | awk -F ' ' '{print $1}' | awk -F 'Filesystem' '{print $1}')"
	localTest="$(df "/" | awk -F ' ' '{print $1}' | awk -F 'Filesystem' '{print $1}')"
	if [ "$1" = "-t" ]
		then
			echo "Transfer mode enabled, skipping reality check."
			echo
	elif [ "$destTest" = "$sourceTest" ]
		then
			read -p "WARNING: SOURCE $source AND DESTINATION $destination ARE BOTH LOCATED ON $sourceTest. CHECK CONNECTION AND RE-RUN SCRIPT, OR RE-RUN THE SCRIPT WITH THE '-t' SWITCH TO OVERRIDE."
			exit
	elif [ "$destTest" = "$localTest" ]
		then
			read -p "WARNING: BACKUP DIRECTORY $destination IS LOCATED ON THE SYSTEM ROOT PARTITION. CHECK CONNECTION AND RE-RUN SCRIPT, OR RE-RUN THE SCRIPT WITH THE '-t' SWITCH TO OVERRIDE."
			exit
		else
			echo "Verified that the backup location has not been mysteriously unmounted and moved to the system root's partition."
			echo
	fi
} #end fncRealityCheck
function fncMasterInstaller { #function to modify repositories, then check for and, if necessary, install specified packages. created by Michaela Bixler frev=4 fmod=0 frevDate=2018-10-17
	flavor=$(cat /proc/version | egrep -o '(ubuntu|debian|fedora|Red Hat|ARCH|Microsoft)' | head -1) #retrieves flavor from /proc
	if [ "$flavor" = "ubuntu" ] || [ "$flavor" = "debian" ] || [ "$flavor" = "fedora" ] || [ "$flavor" = "Red Hat" ] || [ "$flavor" = "ARCH" ] || [ "$flavor" = "Microsoft" ]
	then
		 for i in ${packages[@]}; do     #loops through packages array
			  if [ "$flavor" = "ubuntu" ] || [ "$flavor" = "debian" ] || [ "$flavor" = "Microsoft" ] #installs package for Ubuntu and derivatives, Debian and derivatives, and Microsoft for the Ubuntu shell
			  then
				   if ! dpkg -l | grep -qw $i     #if the package is not installed, install it
				   then
						#checks if repos are correct, appends the correct repo & updates
						if ! egrep -q '^d.*(universe|contrib).*$' /etc/apt/sources.list && ! egrep -q '^d.*(multiverse|non-free).*$' /etc/apt/sources.list
						then
							 if [ "$flavor" = "ubuntu" ]
							 then
								  sed -i '/^d.*archive.*$/ s/$/ universe multiverse/' /etc/apt/sources.list
								  apt-get update
							 else
								  sed -i '/^d.*http\.debian.*$/ s/$/ contrib non-free/' /etc/apt/sources.list
								  apt-get update
							 fi
						 fi

						 apt-get install $i
						 
					else
					   echo "$i is already installed"
					fi

				   elif [ "$flavor" = "fedora" ] || [ "$flavor" = "Red Hat" ]    #installs package in Fedora, Red Hat, and CentOS
				   then
						if ! rpm -qa | grep -qw $i  #if package does not exist, then install
						then
							yum install $i
						fi

				   elif [ "$flavor" = "ARCH" ]    #installs package in Arch
				   then
						if ! pacman -Q $i   #if package does not exist, then install
						then
							pacman -Sy $i
						fi
				   fi
		 done
		 
	else     #catches unsupported flavors
		 echo "This script does not support automatic installs for this flavor of Linux"
		 echo "Please exit the script and manually install necessary packages"
		 echo "Would you like to exit [y/n]"
		 read action
		 if [ "$action" = "Y" ] || [ "$action" = "y" ] || [ "$action" = "yes" ]
		 then
			  exit
		 fi
	fi
} #end fncMasterInstaller
function fncLicenseCheckpoint { #checks for the ability of Windows to use OEM activation, from within Linux
	if [ -e "$sourceDrive/Windows/System32/license.rtf" ]
		then
			winEdition="WINDOWS $(cat "$sourceDrive/Windows/System32/license.rtf" | awk -F ' WINDOWS ' '{print $2}' | awk -F '\' '{print $1}' | grep -v '^[[:space:]]*$')"
			echo "The currently-installed edition of Windows is:" 2>&1 | tee -a "$backupDir/$logfileName"
			echo "$winEdition" 2>&1 | tee -a "$backupDir/$logfileName"
			echo 2>&1 | tee -a "$backupDir/$logfileName"
	fi
	if [ -e "/sys/firmware/acpi/tables/MSDM" ]
		then
			echo "MSDM table detected. License key for Windows 8, 8.1, or 10 is available." 2>&1 | tee -a "$backupDir/$logfileName"
			msdmKey=$(cat "/sys/firmware/acpi/tables/MSDM" | awk '{ print substr( $0, length($0) - 28, length($0) ) }' 2> /dev/null) #extracts key from MSDM file
			echo "$msdmKey" >> "$backupDir/$logfileName"
	elif [ -e "/sys/firmware/acpi/tables/SLIC" ]
		then
			slicDump=$(hd /sys/firmware/acpi/tables/SLIC | grep 000000e0 | awk -F ' ' '{print $4,$5,$6,$7}')
			if [ "$slicDump" = "00 00 00 00" ]
				then
					echo "SLIC table detected. Windows Vista should be able to activate with automated OEM licensing." 2>&1 | tee -a "$backupDir/$logfileName"
			elif [ "$slicDump" = "01 00 02 00" ]
				then
					echo "SLIC table detected. Windows 7 or Vista should be able to activate with automated OEM licensing." 2>&1 | tee -a "$backupDir/$logfileName"
				else
					echo "WARNING: SLIC table has been detected, but version could not be determined. Automated OEM licensing may not be successful." 2>&1 | tee -a "$backupDir/$logfileName"
			fi
		else
			echo "WARNING: Neither the MSDM nor the SLIC tables are present on the system. Automated OEM licensing on this system WILL NOT be successful." 2>&1 | tee -a "$backupDir/$logfileName"
	fi
}
function fncIntegrityCheck { #verifies that the source and destination have the correct items frev=4 fmod=0 frevDate=2015-11-11
	fncIntegrityCheckDebugLog="$backupDir/integrityCheckDebug_$ritm.txt" #debug
	missingLog="$tmpDir/$destination/missingFileLog.txt"
	missingSource="$tmpDir/$destination/missingFilesSource.txt"
	sourceFilesystem=$(df "$source" | awk -F ' ' '{print $1}' | sed '/Filesystem/d') #determines which partition was used for the source
	destinationFilesystem=$(df "$(dirname $destination)" | awk -F ' ' '{print $1}' | sed '/Filesystem/d') #determines which partition was used for the destination
	#echo "source filesystem is $sourceFilesystem" >> "$fncIntegrityCheckDebugLog" #debug
	#echo "destination filesystem is $destinationFilesystem" >> "$fncIntegrityCheckDebugLog" #debug
	function fncFileSeeker {
		missingCount=$(wc -l <"$missingSource" | grep -Eo '[0-9]+' )
		unset linecount
		while read line #used to check for the presence of each item which should be present, in the destination
		do

			if [ -e "$source/$line " ] #detects trailing space after $line, in the source directory, and adds the space to $line
				then
					line="$line "
			fi
			clear
			let "linecount += 1"
			echo "Checking integrity of file $linecount of $missingCount ($(echo "$linecount*100/$missingCount" | bc)% complete)"
			if [ ! -d "$source/$line" ] && [ "$line" != "" ] #skips directories and null lines
				then
					if [ ! -e "$destination/$line" ] #if the file doesn't exist in the destination
						then
							echo "$line" >> "$missingLog"
							echo "$line missing" 2>&1 | tee -a "$backupDir/$logfileName"
						else
							sourceItemSize=$(ls -l "$source/$line" | grep -Eo ' +[0-9]+ [[:alpha:]]{3} +[0-9]{1,2}' | awk -F ' ' '{print $1}') 2>&1&> /dev/null #source's $line size, in bytes
							destinationItemSize=$(ls -l "$destination/$line" | grep -Eo ' +[0-9]+ [[:alpha:]]{3} +[0-9]{1,2}' | awk -F ' ' '{print $1}') 2>&1&> /dev/null #destination's $line size, in bytes
							if [ "$sourceItemSize" != "$destinationItemSize" ]
								then
									echo "$line" >> "$missingLog"
									echo "failure on $line:" 2>&1 | tee -a "$backupDir/$logfileName"
									echo "source size=$sourceItemSize | destination size=$destinationItemSize" 2>&1 | tee -a "$backupDir/$logfileName"
									echo "debug: $(ls -l "$source/$line" | grep -Eo ' +[0-9]+ [[:alpha:]]{3} +[0-9]{1,2}')" 2>&1 | tee -a "$backupDir/$logfileName"
									echo "debug: $(ls -l "$source/$line")" 2>&1 | tee -a "$backupDir/$logfileName"
							fi
					fi
			fi
		done < "$missingSource"
	}
	if [ ! -d "$tmpDir$destination" ] #if the temp directory doesn't exist, make it
		then
			mkdir -p "$tmpDir$destination"
	fi
	rm "$missingLog" 2>&1&> /dev/null #clears missing items list (if it exists, which it shouldn't) since that is determined in the upcoming steps
	cp "$sourceFilesList" "$missingSource" #this function will utilize a separate list of source files to preserve the original, since it gets shortened
	fncFileSeeker
	if [ -f "$missingLog" ] #these steps only necessary if anything is missing
		then
			clear
			echo "The following files are missing or corrupt in the destination:"
			echo
			cat "$missingLog"
			echo
			read -p "Press 'Enter' to continue..."
			unset menuList
			unset menuListTails
			menuTitle="Would you like to retry copying?"
			menuList=(yes no)
			fncMenuGenerator
			qstnRetryCopy="$menuOutput"
			if [ "$qstnRetryCopy" = "yes" ]
				then
					read -p "How many attempts should UniBak attempt? " retryCount #will stop retrying once verified that all files have been copied successfully
					echo
					for ((i=0; i<$retryCount; i++))
					do
						#fncRealityCheck $1
						mv "$missingLog" "$missingSource"
						echo "Retrying rsync copy attempt $((i+1))/$retryCount (note that rsync is silent at this time)..."
						echo
						rsync -q --progress --files-from="$missingSource" "$source" "$destination" 2>&1 | tee -a "$destination/$logfileName" #this reads the missing source list and rsyncs accordingly. -q suppresses output because of verification after this, -l recreates symbolic links instead of copying the actual contents which should be elsewhere in the backup. --recursive is not used because rsync reads each file and folder from the list
						rm "$missingSource" 2>&1&> /dev/null #no longer needed unless the next pass is necessary, where it is created again
						fncFileSeeker
						if [ ! -f "$missingLog" ]
							then
								break #retry succeeded, no further need to resume loop
							else
								cp "$missingLog" "$missingSource" #resets list to try again
						fi
					done
			fi
	fi
	clear
	if [ -f "$missingLog" ]
		then
			echo "The following files are still missing in the destination after $((i+1)) attempts." 2>&1 | tee -a "$destination/$logfileName"
			echo "Please attempt manual copy if needed:"
			echo
			cat "$missingLog" 2>&1 | tee -a "$destination/$logfileName"
		else
			echo "Verified that all files have been copied successfully from $sourceFilesystem to $destinationFilesystem." 2>&1 | tee -a "$destination/$logfileName"
			sleep 2
	fi
	echo
	rm $missingSource
	if [ "$1" = "paranoid" ] #thorough mode compares the total backup sizes in the source and destination locations
		then
			backupReportLog="$date-BackupReport.txt"
			sizeDiscrepancyLog="$tmpdir/$date_$ritm_SizeDiscrepancy.txt"
			rm "$sizeDiscrepancyLog" #clears the size discrepancy log each time the function is run to avoid repeating
			while read line
			do
				if [ -f "$source/$line" ] #only counts actual files
					then
						clear #used to refresh the window
						echo "Running paranoid check of transfer..."
						echo "Currently found bytes: source:$sourceFileSizePrecise | destination:$destinationFileSizePrecise" #running total of size calculations
						unset testSourceFileSize
						unset testDestinationFileSize
						testSourceFileSize=$(du -k -d 0 "$source/$line" | awk -F ' ' '{print $1}') #determines size of individual source file
						testDestinationFileSize=$(du -k -d 0 "$destination/$line" | awk -F ' ' '{print $1}') #determines size of individual source file
						if [ "$testSourceFileSize" = "" ] #if there is no reported size
							then
								testSourceFileSize=0
						fi
						if [ "$testDestinationFileSize" = "" ] #if there is no reported size
							then
								testDestinationFileSize=0
						fi
						if [ "$testSourceFileSize" != "$testDestinationFileSized" ] #if sizes don't match
							then
								echo "Size mismatch for $line (source: $testSourceFileSize | dest: $testDestinationFileSize)" | 2>&1 | tee -a "$sizeDiscrepancyLog"
						fi
						let "sourceFileSizePrecise += $testSourceFileSize" > /dev/null #incrementally counts the size of the source files
						let "destinationFileSizePrecise += $testDestinationFileSize" > /dev/null #incrementally counts the size of the destination files
				fi
			done < "$sourceFilesList"
			clear
			sourceFileSizePreciseGB=$(echo "scale=1; $sourceFileSizePrecise/1048576" | bc) #separate variable to view size in GB
			destinationFileSizePreciseGB=$(echo "scale=1; $destinationFileSizePrecise/1048576" | bc) #separate variable to view size in GB
			while read line
			do
				if [ -f "$source/$line" ]
					then
						let "sourceFileCount += 1"
				fi
			done < "$sourceFilesList"
			#let "sourceFileCount -= $(ls "$source" | grep ".txt" | wc -l)" #removes .txt files in the source root from the count
			destinationFileCount=$(find "$destination" -type f | wc -l) #counts all files in the destination
			let "destinationFileCount -= $(ls "$destination" | grep ".txt" | wc -l)" #removes .txt files in the backup root from the count
			paranoidSizeCompare=$(echo "scale=1; $destinationFileSizePrecise*100/$sourceFileSizePrecise" | bc) #calculates completion percentage by size
			paranoidCountCompare=$(echo "scale=1; $destinationFileCount*100/$sourceFileCount" | bc) #calculates completion percentage by count
			echo "BACKUP REPORT for $date:" 2>&1 | tee -a "$destination/$backupReportLog" #begins a separate backup report for paranoid mode
			echo "$sourceFileCount items at $sourceFileSizePreciseGB""GB ($sourceFileSizePrecise""KB) were inventoried for transfer from $sourceFilesystem." 2>&1 | tee -a "$destination/$backupReportLog"
			echo "$destinationFileCount items at $destinationFileSizePreciseGB""GB ($destinationFileSizePrecise""KB) were transferred to $destinationFilesystem." 2>&1 | tee -a "$destination/$backupReportLog"
			echo "$paranoidSizeCompare""% of transfer complete by size check." 2>&1 | tee -a "$destination/$backupReportLog"
			echo "$paranoidCountCompare""% of transfer complete by file and directory count." 2>&1 | tee -a "$destination/$backupReportLog"
			if [ -f "$missingLog" ] #shows anything that failed the integrity check
				then
					echo
					read -p "Press 'Enter' to view missing items..."
					echo 2>&1 | tee -a "$destination/$backupReportLog"
					echo "The following items were not transferred successfully:" 2>&1 | tee -a "$destination/$backupReportLog"
					echo 2>&1 | tee -a "$destination/$backupReportLog"
					cat "$missingLog" 2>&1 | tee -a "$destination/$backupReportLog"
					echo 2>&1 | tee -a "$destination/$backupReportLog"
			fi
			if [ -f "$sizeDiscrepancyLog" ] #debug shows anything that failed the paranoid size check
				then
					echo
					read -p "Press 'Enter' to view items with mismatched sizes..."
					echo 2>&1 | tee -a "$destination/$backupReportLog"
					echo "The following items show mismatched sizes:" 2>&1 | tee -a "$destination/$backupReportLog"
					echo 2>&1 | tee -a "$destination/$backupReportLog"
					cat "$sizeDiscrepancyLog" 2>&1 | tee -a "$destination/$backupReportLog"
					echo 2>&1 | tee -a "$destination/$backupReportLog"
			fi
			cat "$destination/$backupReportLog" >> "$destination/$logfileName" #pins backup report to main logfile
			echo
			read -p "Press 'Enter' to continue..."
	fi
} #end fncIntegrityCheck
function fncCheckSMART {
	echo "Preparing to check hard drive health using SMART..."
	#verify drive supports SMART
	#ask to whether to run short test
	#display results
}
function fncEstimateFreedom { #quickly evaluates free space on destination, in human-readable format $1 frev=0 fmod=0 frevDate=2015-10-13
	estimatedFreedom="$(df -h | grep "$1" | awk -F ' ' '{print $4}' | grep -Eo '[0-9]+.*\>' | head -1)"
} #end fncEstimateFreedom
function fncFirefoxBookmarksHandler { #handles size-checking and moving of firefox bookmarks
	firefoxProfileLocation="$sourceDrive/$homeland/$userProfile/AppData/Roaming/Mozilla/Firefox/Profiles" #identifies default appdata location for Firefox bookmarks for Windows user accounts
	firefoxProfiles=($(ls "$firefoxProfileLocation")) #saves the list of all firefox profiles for this user account
	firefoxProfileNames=($(ls "$firefoxProfileLocation" | grep -o '\..*' | awk -F '.' '{print $2}')) #separates the name of the profile from the hash string
	if [ "${firefoxProfiles[*]}" != "" ] #if there are any folders under Profiles
		then
			firefoxBackupDir="$backupDir/$homeland/$userProfile/Desktop/Firefox Bookmarks" #establishes path of backup location, to user's desktop
			mkdir -p "$firefoxBackupDir"
			for i in ${!firefoxProfiles[*]}
			do
				mkdir "$firefoxBackupDir/${firefoxProfileNames[$i]}" #creates folder named with the short name of the profile
				echo "Copying Firefox bookmarks from profile ${firefoxProfileNames[$i]} for user $userProfile..." 2>&1 | tee -a "$backupDir/$logfileName"
				rsync -q "$firefoxProfileLocation/${firefoxProfiles[$i]}/places.sqlite" "$firefoxBackupDir/${firefoxProfileNames[$i]}/" 2>&1 | tee -a "$backupDir/$logfileName"
				let "sourceFileCount += 1" #counts the places.sqlite file for use in integrity check later
			done
			toolName="FoxyRestore.bat" #batch file that handles restoring bookmarks to their correct location
			toolDest="$firefoxBackupDir" #location where FoxyRestore.bat will be saved
			fncToolFinder #handles downloading of the tool to its destination
			let "sourceFileCount += 1" #counts FoxyRestore.bat for use in integrity check later
		else
			echo "No Firefox profiles were found for user $userProfile" 2>&1 | tee -a "$backupDir/$logfileName"
	fi
}
function fncToolFinder { #handles finding and downloading any specified script, utility, idea, tool, or soul which may be located on our server in the scripts folder
	if [ -f "/$mountPrefix/$toolDir/scripts/$toolName" ] #logDir is used to start the relative path instead of serverPath because the LCM switch used to bring that location down a level. logDir is consistent
		then
			echo "Copying $toolName from fs3/hdimages..." 2>&1 | tee -a "$backupDir/$logfileName"
			rsync -q "/$mountPrefix/$toolDir/scripts/$toolName" "$toolDest" #copies the script to whatever the tool's defined destination is
	elif ping -c1 helpdesk.liberty.edu > /dev/null
		then
			echo "Downloading $toolName from helpdesk.liberty.edu/hdtools..." 2>&1 | tee -a "$backupDir/$logfileName"
			if [[ "$uname" == *Linux* ]]
				then #will use wget for linux and curl for mac
					wget --no-check-certificate -qO "toolDest/$toolName" "$scriptRepo/$toolName"
				else
					curl -fskL -o "$toolDest/$toolName" "$scriptRepo/$toolName"
			fi
	elif [ -f "$dirName/$toolName" ] #this is last in case it is outdated, since any scripts with a self-updater will exit, and if this location is needed then that means it can't self-update
		then
			echo "Copying $toolName from the host script's local directory..." 2>&1 | tee -a "$backupDir/$logfileName"
			rsync -q "$dirName/$toolName" "$toolDest" #copies the script to whatever the tool's defined destination is
		else
			unset menuList
			unset menuListTails
			menuTitle="Is $toolName an optional tool?"
			menuList=(yes no)
			fncMenuGenerator
			if [ "$menuOutput" = "yes" ]
				then
					echo "Unable to locate $toolName. Since it is optional, the script will continue anyway." 2>&1 | tee -a "$backupDir/$logfileName"
				else
					echo "Unable to locate $toolName. Since it is not optional, the script will exit." 2>&1 | tee -a "$backupDir/$logfileName"
					echo "Please verify connectivity or place a local copy in the same directory that $baseName is in."
					exit
			fi
	fi
	chmod +x "$toolDest/$toolName" #necessary to make script executable for all linux and OSX Mavericks and newer
}
function fncAppDataHandler { #called during fncBackupXtra, this reads the appDataMisc[] array to add relevant items to the source files list
	for j in ${!appDataMisc[*]} #checks all locations specified in the array, and adds relevant items to the backup list
			do
				if ls "$source/$userProfile/${appDataMisc[$j]}" 2>&1&> /dev/null #if the directory listed in appDataMisc[] has any contents
					then
						find "$source/$userProfile/${appDataMisc[$j]}/" | sed "s@$sourceDrive@@" >> "$sourceFilesList"
						echo "$userProfile/${appDataMisc[$j]} has been found and is added to backup list" 2>&1 | tee -a "$backupDir/$logfileName"
					else
						echo "$userProfile/${appDataMisc[$j]} was not found, or was empty." >> "$backupDir/$logfileName"
				fi
			done
}
function fncServerMount { #created from mountdrives.sh v1.3 written by Matt Hooker frev=12 fmod=0 frevDate=2020-02-21
	#be sure that fncUserIdentifier, $uname, $currentUser, $currentUID, ${server}, ${share}, ${mountpoint}, and $mountPrefix are globally available
	clear
	if [[ "$uname" == *Linux* ]] #if linux, make sure cifs-utils is installed
		then
			packages=(cifs-utils)
			fncMasterInstaller
	fi
	fncUserIdentifier
	echo "$baseName will attempt to mount one or more servers to $mountPrefix/ as user $serverUsername..."
	echo
	for i in ${!mountpoint[*]}
	do
		if ping -c 1 ${server[$i]} 2>&1&> /dev/null
			then
				if [[ $(ls -l "$mountPrefix/${mountpoint[$i]}" | awk -F '-' '{print $1}') != *drwx* ]] #if the server has no writeable folders, then unmount to remount
					then
						umount "$mountPrefix/${mountpoint[$i]}" 2> /dev/null
						sleep 2
				fi
				if [ ! -d "$mountPrefix/${mountpoint[$i]}" ] #if server mount location doesn't exist, create it
					then
						mkdir -p "$mountPrefix/${mountpoint[$i]}"
				fi
				chmod 600 "$mountPrefix/${mountpoint[$i]}"
				blnAuthFailure=0
				while true
				do
					if df | grep ${mountpoint[$i]} 2>&1&> /dev/null #can proceed to the next network location shows in mount points
						then
							echo "\\\\${server[$i]}\\${share[$i]} is mounted to $mountPrefix/${mountpoint[$i]}"
							serverMountSuccess[$i]="true"
							blnAuthFailure=0
							break
					elif [ ! -n "$serverPassword" ]
						then
							read -s -p "Please enter $serverUsername's password: " serverPassword
							if [[ "$serverPassword" == *@* ]] || [[ "$serverPassword" == *#* ]] || [[ "$serverPassword" == *!* ]]
								then
									echo "Incompatible character(s) detected in password. Password may need to be entered additional times for the workaround." #list of password characters that interfere with mount.cifs or mount_smbfs
							fi
							echo
					fi
					echo "attempting to mount \\\\${server[$i]}\\${share[$i]} to $mountPrefix/${mountpoint[$i]}..."
					if [[ "$uname" == *Linux* ]]
						then
							if [[ "$serverPassword" == *@* ]] || [[ "$serverPassword" == *#* ]] || [[ "$serverPassword" == *!* ]] #list of password characters that interfere with mount.cifs
								then
									mount -t cifs -o username="$serverUsername",domain="SENSENET",uid=$currentUID,vers=2.1 "\\\\${server[$i]}\\${share[$i]}" "$mountPrefix/${mountpoint[$i]}" #mounts the server in Linux but does not use the password string
								else
									mount -t cifs -o username="$serverUsername",password="$serverPassword",domain="SENSENET",uid=$currentUID,vers=2.1 "\\\\${server[$i]}\\${share[$i]}" "$mountPrefix/${mountpoint[$i]}" #mounts the server in Linux using the validated password
							fi
					elif [[ "$serverPassword" == *@* ]] #the symbol "@" will break the mount_smbfs line, so a variation of the command will be used
						then
							echo "Illegal character detected in password. Please re-enter password when prompted."
							mount_smbfs //"$serverUsername@${server[$i]}/${share[$i]}" "$mountPrefix/${mountpoint[$i]}" #mounts the server in OSX, but without password
						else
							mount_smbfs //"$serverUsername:$serverPassword@${server[$i]}/${share[$i]}" "$mountPrefix/${mountpoint[$i]}" #mounts the server in OSX
					fi
					if [ ! "$(ls -A $mountPrefix/${mountpoint[$i]})" ] #check to alert if the serverpath does not exist
						then
							sleep 2
					fi
					if [ ! "$(ls -A $mountPrefix/${mountpoint[$i]})" ] #check to alert if the serverpath does not exist
						then
							let "blnAuthFailure += 1"
					fi
					if [ "$blnAuthFailure" -gt "0" ]
						then
							clear
							echo "Attempt to mount server by $serverUsername failed."
							echo "Check network connection and account, then try password again."
							read -s -p "Password: " serverPassword
							clear
					fi
					if [ "$blnAuthFailure" -gt "1" ]
						then
							clear
							menuTitle="Login failed at least twice. Skip server \\\\${server[$i]}\\${share[$i]}?."
							menuList=(yes no)
							fncMenuGenerator
							if [ "$menuOutput" = "yes" ] #if yes, then removes share from list and moves to next item. else, continues to retry at risk of locking account
								then
									unset server[$i]
									unset share [$i]
									unset mountpoint[$i]
									break
							fi
					fi
				done
			else
				echo "Unable to ping ${server[$i]}. Skipping mount."
				serverMountSuccess[$i]="false"
		fi
	done
} #end fncServerMount
function fncUserIdentifier { #used to identify the current technician. if a likewise-open domain account then the current user is assumed to be the one using the script frev=2 fmod=0 frevDate=2016-06-21
	if id -Gn "$currentUser" | grep -Eo "SENSENET_USER_[[:alpha:]]+" 2>&1&> /dev/null #if current user is in the custom sensenet user identifier group, which is manually created per profile for this function
		then
			serverUsername="$(id -Gn "$currentUser" | grep -Eo "SENSENET_USER_[[:alpha:]]+" | awk -F '_' '{print $3}')"
	elif id -Gn "$currentUser" | grep " techies " 2>&1&> /dev/null #checks whether the current user is a domain profile in the "techies" group. the surrounding spaces ensure that only the regular "techies" group is identified
		then
			serverUsername="$currentUser"
	elif [ "$serverUsername" = "" ] #if serverUsername has not already been determined
		then
			read -p "Enter your Liberty username: " serverUsername
	fi
} #end fncUserIdentifier
function fncSwitchDecoder { #interprets multiple switches to ensure that correct modes are utilized frev=0 fmod=0 frevDate=2015-10-01
	switchInput="$(echo "$@" | tr -d '[ \t\-]')"
	#echo "debug: \$switchInput is $switchInput" #debug
	if [[ "$switchInput" == *h* ]] || [[ "$switchInput" == *H* ]] || [[ "$switchInput" == *\?* ]] #displays switch help
		then
			swHelp="y"
			echo
			echo "---------------------------------------------------------"
			echo "******|-UniBak- Backup and Restore Script v$version-|*******"
			echo "---------------------------------------------------------"
			echo
			echo "To run this script, use a terminal and use 'sudo' before the command."
			echo
			echo "Advanced usage:"
			echo "----------------------------------------------------------------------"
			echo "-a   | backs up data for all users"
			echo "----------------------------------------------------------------------"
			echo "-lcm | adjusts functionality for use in the LCM program"
			echo "----------------------------------------------------------------------"
			echo "-u   | forcibly updates UniBak with the version located on the server"
			echo "----------------------------------------------------------------------"
			echo "-t   | used to transfer directly from one operational system to another"
			echo "----------------------------------------------------------------------"
			echo "-m   | used to reject .exe and .zip files from the downloads folder,"
			echo "     | for use with malware cleanup on Windows"
			echo "----------------------------------------------------------------------"
			echo "-x   | converts Windows XP backups to NT 6.x format"
			echo "----------------------------------------------------------------------"
			exit 0
	fi
	if [[ "$switchInput" == *a* ]] || [[ "$switchInput" == *A* ]] #all users
		then
			swAllUsers="y"
			echo "-a selected. Will back up all users"
	fi
	if [[ "$switchInput" == *lcm* ]] || [[ "$switchInput" == *LCM* ]] #LCM mode
		then
			swLCM="y"
			switchInput="$(echo "$switchInput" | awk -F 'lcm' '{print $1$2}')" #removes lcm so that the function does not get confused with -m
			echo "-lcm selected. Will treat backup as an LCM backup"
	fi
	if [[ "$switchInput" == *m* ]] || [[ "$switchInput" == *M* ]] #mitigates malware by not backing up certain file types
		then
			swMalware="y"
			echo "-m selected. Will omit certain files from backup, to mitigate malware risk."
	fi
	if [[ "$switchInput" == *t* ]] || [[ "$switchInput" == *T* ]] #used for transferring directly computer-to-computer
		then
			swTransfer="y"
			echo "-t selected. Host-to-host transfer mode enabled."
	fi
	if [[ "$switchInput" == *u* ]] || [[ "$switchInput" == *U* ]] #forces script to update
		then
			swSelfUpdateForce="-u"
			echo "-u selected. Will self-update $baseName."
	fi
	if [[ "$switchInput" == *x* ]] || [[ "$switchInput" == *X* ]] #converts Windows XP backups to NT 6.x format
		then
			swUpgradeXP="y"
			echo "-x selected. Will back up a Windows XP environment to the NT 6.x format."
	fi
} #end fncSwitchDecoder
function fncMultiSelectionMenuHandler { #allows multiple items to be selected from a single menu frev=2 fmod=0 frevDate=2018-07-06
	unset itemQueue #resets output array
	unset itemQueueTail #resets output tail array
	unset toggle #resets selection boolean array
	unset menuExtra
	while true #loop for refreshing the menu and handling multiple selection
	do
		unset menuList #resets menu item array for rebuild
		unset menuListTails #resets menu item tail array for rebuild
		for i in ${!itemsList[*]} #each refresh of the menu requires rebuilding of the menu items and displaying the selection toggle
		do
			menuList[$i]="${toggle[$i]}${itemsList[$i]}" #displays toggle indicator in front of the item
			if [ -e "${itemsListTail[$i]}" ] #if statement prevents the dash from appearing if there is no tail specified
				then
					menuListTails[$i]="- ${itemsListTail[$i]}" #places dash separator for tail
			fi
		done
		menuList[${#menuList[*]}]="Done selecting, proceed with script" #adds a menu item for completing the selection process
		fncMenuGenerator #generates menu with supplied data
		echo
		if [ "$menuSelect" = "${#menuList[*]}" ] #if the last option (continue) is selected, break the loop
			then
				for i in ${!itemsList[*]} #used for counting
				do
					if [ "${toggle[$i]}" = "*" ] #if toggle is on
						then
							itemQueue[${#itemQueue[*]}]="${itemsList[$i]}" #adds selected item to the output list of all selected items
							itemQueueTail[${#itemQueueTail[*]}]="${itemsListTail[$i]}" #adds tail to output list in case the script needs it
					fi
				done
				break
			else
				if [ "${toggle[$(($menuSelect-1))]}" = "*" ] #if toggle is on
					then
						toggle[$(($menuSelect-1))]="" #turns off toggle
					else #if toggle is off
						toggle[$(($menuSelect-1))]="*" #turns on toggle
				fi
				continue
			fi
	done
	unset menuHeader1
	unset menuHeader2
	unset menuHeader3
} #end fncMultiSelectionMenuHandler
function fncBackup {
	rsync --timeout=20 --files-from="$sourceFilesList" "$source" "$backupDir/" 2>&1 | tee -a "$backupDir/$logfileName" #this reads the missing source list and rsyncs accordingly. -q suppresses output because of verification after this, -l recreates symbolic links instead of copying the actual contents which should be elsewhere in the backup. --recursive is not used because rsync reads each file and folder from the list
}
function fncBackupPrep {
	if [ "$platformMode" == "linux4windows" ] || [ "$platformMode" == "mac4windows" ] #backing up Windows
		then
			if [ "$1" = "-m" ] #extra malware mitigating features, to be used selectively
				then
					echo "-m switch used, will exclude any .exe or .zip files from Downloads, Desktop, Pictures, Music" 2>&1 | tee -a "$backupDir/$logfileName"
					echo 2>&1 | tee -a "$backupDir/$logfileName"
					find "$source/$userProfile" -type d \( -iwholename "$source/$userProfile/AppData" -o -iwholename "$source/$userProfile/Dropbo[\ \(\)[:alpha:]]*" -o -iwholename "$source/$userProfile/Google Drive" -o -iwholename "$source/$userProfile/SkyDrive" -o -iwholename "$source/$userProfile/OneDriv[\ \-\(\)[:alpha:]]*" \) -prune -o -print | grep -Ev "Desktop/.+\.[Ll][Nn][Kk]|\.instrea.+|[Nn][Tt][Uu][Ss][Ee][Rr]\..+|/[Dd]esktop\.[Ii][Nn][Ii]|/Thumbs\.db|\.recently\-used\.xbel|.+\.scr|~\$.+|$source/$userProfile/(Desktop|Downloads|Pictures|Music|Videos)+/.+\.([Ee][Xx][Ee]|[Zz][Ii][Pp])" | sed "s@$sourceDrive@@" >> "$sourceFilesList" #this filters out what should not be backed up from the main locations, and saves it in a list at the location specified for $sourceFilesList
				else
					find "$source/$userProfile" -type d \( -iwholename "$source/$userProfile/AppData" -o -iwholename "$source/$userProfile/Dropbo[\ \(\)[:alpha:]]*" -o -iwholename "$source/$userProfile/Google Drive" -o -iwholename "$source/$userProfile/SkyDrive" -o -iwholename "$source/$userProfile/OneDriv[\ \-\(\)[:alpha:]]*" \) -prune -o -print | grep -Ev 'Desktop/.+\.[Ll][Nn][Kk]|\.instrea.+|[Nn][Tt][Uu][Ss][Ee][Rr]\..+|/[Dd]esktop\.[Ii][Nn][Ii]|/Thumbs\.db|\.recently\-used\.xbel|.+\.scr|~\$.+' | sed "s@$sourceDrive@@" >> "$sourceFilesList" #this filters out what should not be backed up from the main locations, and saves it in a list at the location specified for $sourceFilesList
			fi
	elif [ "$platformMode" == "linux4mac" ] || [ "$platformMode" == "mac4mac" ] #backing up Mac
		then
			if [ "$1" = "-m" ] #extra malware mitigating features, to be used selectively
				then
					echo "-m switch used, will exclude any .exe, .zip, .dmg, .rdp, .app files from Downloads" 2>&1 | tee -a "$backupDir/$logfileName"
					echo 2>&1 | tee -a "$backupDir/$logfileName"
					find "$source/$userProfile" -type d \( -iwholename "$source/$userProfile/.Trash" -o -iwholename "$source/$userProfile/Library" -o -iwholename "$source/$userProfile/Dropbo[\ \(\)[:alpha:]]*" -o -iwholename "$source/$userProfile/Google Drive" \) -prune -o -print | grep -Ev ".+\.localized|.+/About [[:alpha:]]+\.lpdf/.*|$source/$userProfile/Downloads/.+\.([Ee][Xx][Ee]|[Zz][Ii][Pp]|[Dd][Mm][Gg]|[Aa][Pp][Pp]|rdp)" | sed "s@$sourceDrive@@" >> "$sourceFilesList" #this filters out what should not be backed up from the main locations, and saves it in a list at the location specified for $sourceFilesList
				else
					find "$source/$userProfile" -type d \( -iwholename "$source/$userProfile/.Trash" -o -iwholename "$source/$userProfile/Library" -o -iwholename "$source/$userProfile/Dropbo[\ \(\)[:alpha:]]*" -o -iwholename "$source/$userProfile/Google Drive" \) -prune -o -print | grep -Ev ".+\.localized|.+/About [[:alpha:]]+\.lpdf/.*" | sed "s@$sourceDrive@@" >> "$sourceFilesList" #this filters out what should not be backed up from the main locations, and saves it in a list at the location specified for $sourceFilesList
			fi
		else #backing up Linux
			find "$source/$userProfile" -type d \( -iwholename "$source/$userProfile/.trash" -o -iwholename "$source/$userProfile/.cache" -o -iwholename "$source/$userProfile/.dropbox" -o -iwholename "$source/$userProfile/.dropbox-dist" -o -iwholename "$source/$userProfile/.local" -o -iwholename "$source/$userProfile/Dropbox" \) -prune -o -print | sed "s@$sourceDrive@@" >> "$sourceFilesList" #this filters out what should not be backed up from the main locations, and saves it in a list at the location specified for $sourceFilesList
	fi
	if [ "$dropboxSelected" = "yes" ]
		then
			ls "$source/$userProfile" | grep -E 'Dropbo[\ \(\)[:alpha:]]*' > "$tmpfile"
			while read line
			do
				find "$source/$userProfile/$line" -type f | sed "s@$sourceDrive@@" >> "$sourceFilesList"
			done <"$tmpfile"
	fi
}
function fncBackupXtra {
	if [ "$platformMode" == "linux4windows" ] || [ "$platformMode" == "mac4windows" ] #backing up Windows
		then
			appDataMisc=("AppData/Local/Google/Chrome/User Data/Defaults/Bookmarks" "AppData/Roaming/Microsoft/Signatures" "AppData/Roaming/Microsoft/Document Building Blocks" "AppData/Roaming/Microsoft/Sticky Notes" "AppData/Local/Microsoft/Outlook/Offline Address Books") #AppData items that require no special options
			fncAppDataHandler #runs through the above specified locations which don't require special attention
			if ls "$source/$userProfile/AppData/Roaming/Microsoft/Templates" | grep ".oft" > "$tmpfile" #checks for .oft Microsoft templates
				then
					while read line
					do
						echo "$source/$userProfile/AppData/Roaming/Microsoft/Templates/$line" >> "$sourceFilesList"
					done <"$tmpfile"
					echo "Microsoft \".oft\" template(s) has been found and is added to backup list" 2>&1 | tee -a "$backupDir/$logfileName"
				else
					echo "Microsoft \".oft\" template(s) not found." 2>&1 | tee -a "$backupDir/$logfileName"
			fi
			if ls "$source/$userProfile/AppData/Local/Packages/" | grep "Microsoft.MicrosoftStickyNotes_" > "$tmpfile" #checks for newer (W10 1703+) sticky notes
				then
					while read line
					do
						find "$source/$userProfile/AppData/Local/Packages/$line" -type f | sed "s@$sourceDrive@@" >> "$sourceFilesList"
					done <"$tmpfile"
					echo "Sticky Notes (Windows 10 1703+) have been found and added to backup list" 2>&1 | tee -a "$backupDir/$logfileName"
				else
					echo "Sticky Notes not found." 2>&1 | tee -a "$backupDir/$logfileName"
			fi
			if ls "$source/$userProfile/AppData/Local/Microsoft/Outlook" | grep ".pst" > "$tmpfile" #checks for .pst Outlook archives
				then
					while read line
					do
						echo "$line has been found in AppData and is being migrated to $userProfile/Documents/Outlook Files" 2>&1 | tee -a "$backupDir/$logfileName"
						mkdir -p "$backupDir/$homeland/$userProfile/Documents/Outlook Files" 2>/dev/null #makes the directory. skips checking and hides error output for if this repeats
						rsync -q "$sourceDrive/$homeland/$userProfile/AppData/Local/Microsoft/Outlook/$line" "$backupDir/$homeland/$userProfile/Documents/Outlook Files" >> "$backupDir/$logfileName"
						let "sourceFileCount += 1"
					done <"$tmpfile"
				else
					echo "Outlook \".pst\" file(s) not found in the legacy AppData location." 2>&1 | tee -a "$backupDir/$logfileName"
			fi
			fncFirefoxBookmarksHandler #increased complexity and code reuse warrants a separate global function
	elif [ "$platformMode" == "linux4mac" ] || [ "$platformMode" == "mac4mac" ] #backing up Mac
		then
			appDataMisc=("Library/Application Support/Firefox" "/Library/Application Support/Google/Chrome/Default/Bookmarks" "Library/StickiesDatabase") #Library items that require no special options
			fncAppDataHandler
			if ls "$source/$userProfile/Library/Safari/" | grep "Bookmarks.plist" 2>&1&> /dev/null #checks for Safari Bookmarks.plist file
				then
					echo "$homeland/$userProfile/Library/Safari/Bookmarks.plist" >> "$sourceFilesList"
					echo "Safari bookmarks for $userProfile have been found and added to backup list" 2>&1 | tee -a "$backupDir/$logfileName"
				else
					echo "Safari bookmarks not found for $userProfile." >> "$backupDir/$logfileName"
			fi
	fi
}
function fncSourceFileSizeEstimate { #checks size of profiles excluding Library and Dropbox
	unset usersListSizeEstimate
	unset usersListDropboxSizeEstimate
	ls "$sourceDrive/$homes" > "$usersLog" #flagged try to remove $homes
	while read line #filters the list of items in the home or Users folder to determine actual users and the shared profile
	do
		if [ "$line" = "All Users" ] || [ "$line" = "Default" ] || [ "$line" = "Default.migrated" ] || [ "$line" = "Default User" ] || [ "$line" = "desktop.ini" ] || [ "$line" = ".DS_Store" ] || [ "$line" = ".localized" ]
			then
				continue
		else
				usersList[${#usersList[*]}]="$line"
				continue
		fi
	done < "$usersLog"
	rm "$usersLog"
	echo "Calculating size of relevant files in each user profile..." 2>&1 | tee -a "$logfileName"
	echo "Note: Zero does not mean empty" 2>&1 | tee -a "$logfileName"
	echo 2>&1 | tee -a "$logfileName"
	echo "User | Size w/o dropbox | Size w/ dropbox" 2>&1 | tee -a "$logfileName"
	for i in ${!usersList[*]} #flagged for testing
	do
		j="$sourceDrive/$homes/${usersList[$i]}" #shortening the working path so the exclusions don't take up so much space below
		if [ "$host" = "mac" ] #du for mac uses -I to exclude, linux uses --exclude
			then
				usersListSizeEstimate[$i]=$(du -d 0 -k -I "$j"/AppData -I "$j"/Dropbo[\ \(\)[:alpha:]]* -I "$j"/Google?Drive -I "$j"/OneDriv[\ \-\(\)[:alpha:]]* -I "$j"/SkyDrive -I "$j"/Library -I "$j"/.trash -I "$j"/.Trash -I "$j"/.local -I "$j"/.cache -I lost+found -I .ecryptfs "$j" | awk -F ' ' '{print $1}') #calculates size and excludes specified items, trimming to numbers only
				usersListDropboxSizeEstimate[$i]=$(du -d 0 -k "$j"/Dropbo[\ \(\)[:alpha:]]* 2>/dev/null | awk -F ' ' '{s+=$1} END {print s}') #calculates size just of dropbox, combining individual sizes
			else
				usersListSizeEstimate[$i]=$(du -d 0 -k --apparent-size --exclude="$j"/AppData --exclude="$j"/Dropbo[\ \(\)[:alpha:]]* --exclude="$j"/Google?Drive --exclude="$j"/OneDriv[\ \-\(\)[:alpha:]]* --exclude="$j"/SkyDrive --exclude="$j"/Library --exclude="$j"/.trash --exclude="$j"/.Trash --exclude="$j"/.local --exclude="$j"/.cache --exclude=lost+found --exclude=.ecryptfs "$j" | awk -F ' ' '{print $1}') #calculates size and excludes specified items, trimming to numbers only
				usersListDropboxSizeEstimate[$i]=$(du -d 0 -k --apparent-size "$j"/Dropbo[\ \(\)[:alpha:]]* 2>/dev/null | awk -F ' ' '{s+=$1} END {print s}') #calculates size just of dropbox, combining individual sizes
		fi
		if ! [[ "${usersListDropboxSizeEstimate[$i]}" =~ ^[0-9]+([.][0-9]+)?$ ]] #if the dropbox size estimate for the profile isn't an actual number (null or something invalid)
			then
				echo "Dropbox for ${usersList[$i]} not found. ${usersListDropboxSizeEstimate[$i]}" 2>&1 | tee -a "$logfileName" #after message, adds the value of the estimate just in case it's not null
				usersListDropboxSizeEstimate[$i]="0" #after recording/displaying original value, setting to zero to not break calculations
		fi
		echo "${usersList[$i]} | $(echo "scale=2; ${usersListSizeEstimate[$i]} / 1048576" | bc) GB | $(echo "scale=2; ${usersListSizeEstimate[$i]} / 1048576 + ${usersListDropboxSizeEstimate[$i]} / 1048576" | bc) GB" 2>&1 | tee -a "$logfileName" #calculation converts to GB and 2 decimal places, showing without and with dropbox included
	done
	echo
	menuTitle="Will Dropbox data be included in the backup?"
	menuList=( yes no )
	fncMenuGenerator noclear
	dropboxSelected="$menuOutput"
	echo "Dropbox selected for backup? - $dropboxSelected" >> "$logfileName"
}
function fncRestore {
	if [ "$host" = "mac" ] #this can be removed when the function is optimized for linux/mac restores
		then
			echo "Assigning ownership of the files to $primaryUser..."
			chown -R "$primaryUser" "$dataPath" #makes the current user the owner of the primary profile from the backup
			echo "finding data..."
			find "$dataPath/Users/$primaryProfile/" -type d -maxdepth 1 | awk -F $dataPath/Users/$primaryProfile/ '{print $2}'> "$dataPath/profileFolders.txt"
			find "$dataPath/Users/$primaryProfile/" -type f -maxdepth 1 | awk -F $dataPath/Users/$primaryProfile/ '{print $2}' > "$dataPath/profileFiles.txt"

			while read document
			do
				if [ "$document" != "" ]
				then
					mv -v "$dataPath/Users/$primaryProfile/$document" "$homeFolder" 2>&1 | tee -a "$logfileName"
				fi
			done < "$dataPath/profileFiles.txt"

			while read folder
			do
				folder=$(echo $folder | cut -c 2-)													#removes / at the beginning of folder name

				if [ "$folder" != "" ] 																#condition is necessary otherwise it operates on the primaryProfile folder
				then
					if [ -d "$homeFolder/$folder" ]													#tests if the directory exists
					then
						mv -v "$dataPath/Users/$primaryProfile/$folder"/* "$homeFolder/$folder/" 2>&1 | tee -a "$logfileName"
						mv -v "$dataPath/Users/$primaryProfile/$folder"/.[!.]* "$homeFolder/$folder/" 2>&1 | tee -a "$logfileName"	#moves hidden files
						if [ -n "$(find "$dataPath/Users/$primaryProfile/$folder" -prune -empty)" ]			#tests if the directory is now empty
						then
							rmdir "$dataPath/Users/$primaryProfile/$folder"				# removes folders
						else
							echo "could not remove $folder because not all items could be moved"
						fi
					else
						mv -v "$dataPath/Users/$primaryProfile/$folder" "$homeFolder" 2>&1 | tee -a "$logfileName"		#move directories that do not already exist
					fi
				fi
			done < "$dataPath/profileFolders.txt"

			if [ -n "$(find "$dataPath/Users/$primaryProfile" -prune -empty)" ]			#tests if the directory is now empty
			then
				rmdir "$dataPath/Users/$primaryProfile"				# removes user's folder
			else
				echo "could not remove $primaryProfile because not all items have been moved"
			fi
	fi
}
function fncAdminRights { #assigns admin rights to a user
	if [ "$host" = "mac" ]
		then
			dscl . -append /Groups/admin GroupMembership $primaryUser
			dscacheutil -flushcache
	fi
}
function fncSoftestDataHandler { #checks for and backs up Softest exams and answers
	if find "$sourceDrive/Program Files (x86)/Examsoft/" | grep -Eo  'Program Files \(x86\)/Examsoft/Softest [0-9]+\.[0-9]+/[0-9]+/.+' >> "$sourceFilesList" #if there is a Softest program files folder, containing folders named just with numbers. this line facilitates both the IF, and the amendment to the $sourceFilesList in one step
		then
			echo "Softest exams and answers marked for backup" 2>&1 | tee -a "$logfileName"
	fi
}
function fncFontsHandler { #handles backing up of fonts. may be expanded in the future
	echo "Not Implemented yet. Base size is 375MB, will need to trim that down for efficiency, or make this optional."
}
###main UniBak script########################################################
fncSwitchDecoder "$@"
fncRootCheck
fncSelfUpdater $1
fncTempFileCleanup
unset menuList
unset menuListTails
menuTitle="UniBak Backup Script $(if [ "$devVar" = "y" ]; then echo "Dev Version"; fi) v$version"
menuList=(Backup Restore Exit)
fncMenuGenerator
unibakMode="$menuOutput"
if [ "$unibakMode" != "Exit" ]
	then
		unset menuList
		unset menuListTails
		menuTitle="Please select the profile type for $unibakMode:"
		menuList=(windows mac linux)
		fncMenuGenerator
		platformMode="$host"4"$menuOutput"
		if [ "$menuOutput" == "windows" ]
			then
				sharedProfile="Public"
				homes="Users"
				homeland="Users"
		elif [ "$menuOutput" == "mac" ]
			then
				sharedProfile="Shared"
				homes="Users"
				homeland="Users"
		elif [ "$menuOutput" == "linux" ]
			then
				sharedProfile="shared"
				homes="home"
				homeland="home"
		fi
		if [ "$platformMode" = "mac4linux" ] #catches modes which are not yet implemented
			then
				clear
				echo "The backup mode $platformMode is not yet implemented."
				exit
		fi
		fncServerMount

fi
if [ "$unibakMode" = "Backup" ]
	then
		if [ "$platformMode" == "linux4linux" ] || [ "$platformMode" == "mac4mac" ] #if linux4windows or linux4mac then the answer is clearly 'no'
			then
				unset menuList
				unset menuListTails
				menuTitle="Are you currently using the operating system that you are intending to back up?"
				menuList=(yes no)
				fncMenuGenerator
				sourceLocal="$menuOutput"
			else
				sourceLocal="no"
		fi
		if [ "$sourceLocal" = "yes" ]
			then
				sourceDrive="/" #source is the main filesystem
				sourceDrivePartition=$(df / | grep -o '/dev/sd[a-z][0-9]') #sets the current root partition
			else
				menuTitle="Select the number for the correct source to back up from:"
				fncDeviceMenuHandler
				sourceDrive="$driveSelection" #sets the selection from the menu to the source drive
				sourceDrivePartition="$driveSelectionPartition"
		fi #end sourceLocal if
		clear
		fncSourceFileSizeEstimate #lists sizes of user folders in source directory
		menuTitle="Select the number for the correct backup destination:"
		qstnIncludeServers="y"
		qstnIncludeFreeSpace="y"
		fncDeviceMenuHandler
		backupDest="$driveSelection" #sets the selection from the menu to the destination drive
		echo
		if [ "$1" = "-lcm" ] || [ "$2" = "-lcm" ] #Create folder for the backup to be stored in
			then
				echo "Please enter the customer's username to title the backup folder:" #username for LCM
			else
				echo "Please enter the ticket number of the current request to title the backup folder:" #ticket number for others
		fi
		while true #provides error checking to ensure that the backup name is actually something
		do
			read ritm #this named for the original requested item naming format, this is the name of the backup usually a ticket number
			if [ "$ritm" == "" ]
				then
					echo
					echo "A name is required for the backup. Try again."
					echo
					continue
				else
					break
			fi
		done
		if [ "$1" = "-lcm" ] || [ "$2" = "-lcm" ] #appends the name of the backup for LCM mode
			then
				ritm="LCM_$ritm"
		fi
		backupDir="$backupDest/$ritm"
		mkdir -p "$backupDir" #creates the backup directory
		if [ -z "$serverUsername" ] #if this variable was not used, we will collect the technician's username for the log
			then
				while true #provides error checking to ensure that a valid username is selected
				do
					echo "What is your Liberty username?"
					read serverUsername
					if [ "$serverUsername" == "" ]
						then
							echo "Without a valid username, YOU SHALL NOT PASS!"
							continue
						else
							break
					fi
				done
		fi
		echo "UniBak v$version log" >> "$backupDir/$logfileName" #records UniBak version to the log file
		echo "Data from $ritm backed up from $sourceDrive to $backupDir by $serverUsername on $date" >> "$backupDir/$logfileName" #records destination, technician username, and date to log file
		echo "Selected filesystem $sourceDrive at $sourceDrivePartition is a $(fdisk -l $sourceDrivePartition | grep -Eo '[0-9]+\.{,1}[0-9]{,1} [[:alpha:]]{1,3}' | head -1)$(fdisk -l | grep $sourceDrivePartition  | grep -Eo '\ [[:alnum:] ]+filesystem')" >> "$backupDir/$logfileName" #displays details (size and type) about the selected filesystem
		echo >> "$backupDir/$logfileName"
		if [ "$platformMode" = "linux4windows" ] || [ "$platformMode" = "mac4windows" ] #if a Windows backup, attempts to identify proper OS version/edition
			then
				fncLicenseCheckpoint
				echo
				read -p "Press 'Enter' to continue..."
				echo
		fi
		if [ "$1" = "-r" ] #if recovery mode is used, sets the specified user as the one to back up without prompt, else the default shared profile is selected
			then
				userProfile="$2"
		elif [ "$1" = "-a" ] #if the all profile switch is used
			then
				find $sourceDrive/$homeland -maxdepth 1 -type d ! -path "$sourceDrive/$homeland" ! -path "$sourceDrive/$homeland/likewise-open" > "$backupDir/$profileListFile" #main profiles listed in file
				find $sourceDrive/$homeland/$likewisePath -maxdepth 1 -type d ! -path "$sourceDrive/$homeland/$likewisePath" >> "$backupDir/$profileListFile" #sensenet profiles listed in file
				#profileCount=$(cat "$backupDir/$profileListFile"| wc -l) #reads list of profiles to count the number of them
			else
				userProfile="$sharedProfile" #ensures that the shared folder gets backed up. this variable changes in the while loop
		fi
		if [ "$1" = "-a" ] #if the all profile switch is used
			then
				while read line #reads through the list of profiles for backing up every profile that is at least 10MB
					do
						################################################
						clear
						echo "All-user backup currently unavailable. Please run UniBak normally and select users manually."
						exit
						################################################
						userProfile=$(basename "$line") #pulls the base folder name from the full path
						folderSize=$(du -k -d 0 "$line" | awk -F ' ' '{print $1}') #checks size of the profile folder
						echo $folderSize
						if [ "$folderSize" -gt "10000" ] #if >= 10MB
							then
								if [ "$platformMode" == "linux" ] && [ -d "$sourceDrive/$homeland/$likewisePath/$userProfile" ] #if a SENSENET account added to linux with likewise-open
									then
										mkdir -p "$backupDir/$homeland/$userProfile"
										profileDomain=true
									else
										mkdir -p "$backupDir/$homeland/$userProfile"
										profileDomain=false
								fi
								#fncRealityCheck $1
								fncBackupPrep
								echo "Inventoried data from the profile $userProfile" 2>&1 | tee -a "$backupDir/$logfileName"
							else
								echo "the profile $userProfile is $folderSize, and is under the 10MB limit. if needed, back up manually." 2>&1 | tee -a "$backupDir/$logfileName"
						fi
				done < "$backupDir/$profileListFile"
			else
				unset usersQueue
				unset itemsList
				unset itemsListTail
				for i in ${!usersList[*]} #checks the list for a shared profile, and if present adds to the list automatically
				do
					itemsList[$i]="${usersList[$i]}"
					itemsListTail[$i]="${usersListSizeEstimate[$i]}"
				done
				menuTitle="Which user profiles would you like to backup data FROM?"
				fncMultiSelectionMenuHandler
				for i in ${!itemQueue[*]}
				do
					usersQueue[$i]="${itemQueue[$i]}"
				done
				echo "Will back up the following users:" 2>&1 | tee -a "$backupDir/$logfileName"
				echo "${usersQueue[*]}" 2>&1 | tee -a "$backupDir/$logfileName"
				echo 2>&1 | tee -a "$backupDir/$logfileName"
				sleep 2
				sourceFilesList="$backupDir/sourceFilesList.txt" #defining the variable which identifies the location of the source files
				rm "$sourceFilesList" 2>&1&> /dev/null #this removes the source files list just in case it's already there
				destination="$backupDir"
				#fncRealityCheck $1
				source="$sourceDrive/$homeland"
				for i in ${!usersQueue[*]} #prepares for main backup per user, and builds the list for the main backup
				do
					userProfile="${usersQueue[$i]}"
					if [ "$platformMode" == "linux" ] && [ -d "$sourceDrive/$homeland/$likewisePath/$userProfile" ] #if a SENSENET account added to linux with likewise-open
						then
							mkdir -p "$backupDir/$likewisePath/$userProfile"
							#source="$sourceDrive/$homeland"
							echo "Inventorying profile $userProfile..."
							fncBackupPrep #determines file list
							fncBackupXtra #backs up appdata items, etc.
					elif [ -d "$sourceDrive/$homeland/$userProfile" ] #makes sure the selected profile exists before trying the copy
						then
							mkdir -p "$backupDir/$homeland/$userProfile"
							#source="$sourceDrive/$homeland"
							echo "Inventorying profile $userProfile..."
							fncBackupPrep #determines file list
							fncBackupXtra #backs up appdata items, etc.
					else
							echo "Profile '$userProfile' not found." 2>&1 | tee -a "$backupDir/$logfileName"

					fi
				done
		fi
		ls -c "$sourceDrive" > "$itemsLog" #lists the root of the source drive
		unset itemsList
		unset itemsListTail
		while read line
		do
			if [ "$line" = "Users" ] || [ "$line" = "Windows" ] || [ "$line" = "bin" ] || [ "$line" = "boot" ] || [ "$line" = "dev" ] || [ "$line" = "etc" ] || [ "$line" = "home" ] || [ "$line" = "lib" ] || [ "$line" = "mnt" ] || [ "$line" = "root" ] || [ "$line" = "tmp" ] || [[ "$line" == vmlinuz* ]] || [[ "$line" == initrd* ]] || [ "$line" = "lost+found" ] || [ "$line" = "System Volume Information" ] || [ "$line" = "pagefile.sys" ] || [ "$line" = "hiberfil.sys" ] || [ "$line" = "Applications" ] || [ "$line" = "ConditionalItems.plist" ] || [ "$line" = "Library" ] || [ "$line" = "Network" ] || [ "$line" = "System" ] || [ "$line" = "Volumes" ] || [ "$line" = "cores" ] || [ "$line" = "installer.failrequests " ] || [ "$line" = "net" ] || [ "$line" = "opt" ] || [ "$line" = "private " ] || [ "$line" = "sbin" ] || [ "$line" = "usr" ] || [ "$line" = "var" ] || [ "$line" = ".DS_Store" ] || [ "$line" = ".DocumentRevisions-V100" ] || [ "$line" = ".IABootFiles" ] || [ "$line" = ".IAProductInfo" ] || [ "$line" = ".PKInstallSandboxManager" ] || [ "$line" = ".Spotlight-V100" ] || [ "$line" = ".TemporaryItems" ] || [ "$line" = ".Trashes" ] || [ "$line" = ".file" ] || [ "$line" = ".fseventsd" ] || [ "$line" = ".hotfiles.btree" ] || [ "$line" = ".vol" ] || [ "$line" = "Config.Msi" ] || [ "$line" = "Program Files" ] || [ "$line" = "Program Files (x86)" ] || [ "$line" = "ie9stubStart.txt" ] || [ "$line" = "ProgramData" ] || [ "$line" = "\$Recycle.Bin" ] || [ "$line" = "MSOCache" ] || [ "$line" = "oracle" ] || [ "$line" = "FUPLOAD" ] || [ "$line" = "bootmgr" ] || [ "$line" = "found.000" ] || [ "$line" = "_SMSTaskSequence" ] || [ "$line" = "Recovery" ] || [ "$line" = "PerfLogs" ] || [ "$line" = "BOOTSECT.BAK" ] || [ "$line" = "config.sys" ] || [ "$line" = "autoexec.bat" ] #excludes a long list of things which would normally be in the root of a windows, mac, or linux filesystem, and normally not backed up
				then
					continue
			else
					itemsList[${#itemsList[*]}]="$line"
					continue
			fi
		done < "$itemsLog"
		rm "$itemsLog"
		menuTitle="Please select any items in the filesystem root needing to be backed up:"
		fncMultiSelectionMenuHandler
		if [ -n "${itemQueue[*]}" ]
			then
				echo >> "$backupDir/$logfileName"
				echo "Backing up ${itemQueue[*]} from the root of $sourceDrive" >> "$backupDir/$logfileName"
				echo >> "$backupDir/$logfileName"
				for line in "${itemQueue[*]}"
				do
					find "$sourceDrive/$line" | awk -F "$sourceDrive/" '{print $2}' >> "$itemsLog"
					while read line2
					do
						echo "$line2" >> "$sourceFilesList"
						let  "rootItemCount += 1"
					done < "$itemsLog"
				done
				echo "Added $rootItemCount items from the filesystem root to the source files list."
				sleep 1
				echo >> "$backupDir/$logfileName"
			else
				echo >> "$backupDir/$logfileName"
				echo "No items were selected for backup from the root of $sourceDrive" >> "$backupDir/$logfileName"
				echo >> "$backupDir/$logfileName"
		fi
		fncSoftestDataHandler #checks for and backs up Softest exams and answers
		clear
		echo "Backing up selected user profiles, please be patient..."
		source="$sourceDrive"
		fncBackup #backs up all files based on the list generated in all fncBackupPrep instances
		fncIntegrityCheck paranoid #ensures that all data that should have been backed up was
		echo
		if [ -n "$msdmKey" ] #if the windows 8-10 product key is retrieved, ask where it should be placed.
			then
				menuTitle="Select the user to whose desktop the Windows product key will be placed:"
				usersList=($(ls $backupDir/$homeland/))
				usersList=(${usersList[*]} skip) #adds the ability to skip this step. should generally only be used on Liberty computers
				fncPrimaryUserHandler
				keymaster=$userSelection
				if [ "$keymaster" != "skip" ]
					then
						echo "$msdmKey" > "$backupDir/$keymaster/Desktop/productkey.txt" #saves the product key to the text file on the backup's desktop
						echo "Product key $msdmKey has been saved to a file on $keymaster's desktop." 2>&1 | tee -a "$backupDir/$logfileName"
					else
						echo "Technician declined saving the Windows product key $msdmKey to a profile." 2>&1 | tee -a "$backupDir/$logfileName"
				fi
		fi
		echo 2>&1 | tee -a "$backupDir/$logfileName"
		echo "Source File List:" >> "$backupDir/$logfileName"
		echo >> "$backupDir/$logfileName"
		cat "$sourceFilesList" >> "$backupDir/$logfileName" #archives the source file list in the main log, since rsync is now quiet
		if [ -d "$logDir" ] #if the server is accessible, copy the log file to there
			then
				logCopyBackup="$date"_"$ritm"_UniBak_backuplog.txt
				rsync -q "$backupDir/$logfileName" "$logDir/$logCopyBackup"
				echo "Archived a copy of the logfile to the server."
			else
				echo "Unable to access $logDir. Not archiving logfile to the server."
		fi
elif [ "$unibakMode" = "Restore" ]
	then
		clear
		if [ "$host" = "mac" ]
			then
				unset menuList
				unset menuListTails
				menuTitle="Please select the applicable restore format:" #this is asking where the data is located, not necessarily where it was originally backed up to
				menuList=("Server or External" "Local (usually for Liberty-owned pickups)")
				fncMenuGenerator
				restoreFromServer="$menuSelect"
			else
				restoreFromServer="1"
		fi
		if [ "$restoreFromServer" = "1" ] #restoring from server or external
			then
				menuTitle="Select the number for the correct source to restore from:"
				qstnIncludeServers="y"
				fncDeviceMenuHandler
				restoreSource="$driveSelection"
				unset menuList
				unset menuListTails
				menuTitle="Would you like to type the backup name or browse?"
				menuList=("Type" "Browse")
				fncMenuGenerator
				if [ "$menuOutput" = "Type" ]
					then
						echo "Type the backup name in $driveSelection:"
						read ritm
					else
						ls "$restoreSource" > "$itemsLog"
						unset menuList
						unset menuListTails
						menuTitle="Select the Backup you would like to restore:"
						while read line
						do
							menuList[${#menuList[*]}]="$line"
						done < "$itemsLog"
						fncMenuGenerator
						ritm="$menuOutput"
				fi
				prefix=$(echo "$ritm" | grep -Eo '[0-9]{4}-[0-9]{2}-[0-9]{2}.') #if there is a date code on the RITM, identify it
				if [ -n "$prefix" ] #if the ritm is dated
					then
						ritm=$(echo "$ritm" | sed "s@$prefix@@g") #strip the date
						mv "$restoreSource/$prefix$ritm" "$restoreSource/$ritm" #rename to not have the date format
				fi
				source="$restoreSource/$ritm"
				fDate="$(date +%Y-%m-%d_$ritm)" #dates the RITM prior to copying. this variable is the name for the backup
				destination="/$homes/$currentUser/Desktop/$ritm"
				mkdir -p "$destination"
				sourceFilesList="$destination/sourceFilesList.txt" #defining the variable which identifies the location of the source files
				if [ ! -e "$sourceFilesList" ] #for legacy/manual backups, this builds a source file list for if there isn't one
					then
						echo "Building file inventory from $source..."
						find "$source" -print | awk -F "$source" '{ print $2 }' > "$sourceFilesList"
				fi
				echo
				echo "Restoring data to $destination, please be patient..."
				rsync -q --files-from="$sourceFilesList" "$source" "$destination" #copies data to the current user's desktop
				fncIntegrityCheck paranoid #ensures that the data copied successfully and completely from the backup location, and that it was 18 before dating it
				mv "$restoreSource/$ritm/" "$restoreSource/$fDate/" #rename folder on source with Date-Stamp
				echo "Data has been copied to the current user's desktop."
		fi #end check for whether the data is being restored from the external
		# the "local" option starts here, the "server" and "external" options will also use this part, and the following question makes them stop if not putting the data in place
		unset menuList
		unset menuListTails
		menuTitle="Is the primary user's profile already created?"
		menuList=(yes no)
		fncMenuGenerator
		qstnPrimaryProfileCreated="$menuOutput"
		if [ "$qstnPrimaryProfileCreated" = "yes" ]
			then
				if [ "$restoreFromServer" = "1" ] #if just restored, then the path is already known
					then
						dataPath="$destination"
					else #locates the backup in the local Users folder
						dataPath=$(find "/$homes" 2> /dev/null | grep -m 1 -o "/$homes/.*/Desktop/20[0-9][0-9]-[0-9][0-9]-[0-9][0-9].[[:alnum:]]*")
						unset menuList
						unset menuListTails
						menuTitle="Select path to data:"
						menuList[0]="$dataPath"
						menuList[1]="other location"
						fncMenuGenerator
						if [ "$menuOutput" = "other location" ]
							then
								echo "Please provide the correct path of the data to restore:"
								read dataPath
								dataPath=$(echo "$dataPath" | grep -Eo "[^\'].*[^\' *]") #strips off the single quotes, if dragging the location
						fi
				fi #ends check to see if data was restored this time
				if [ -e "$dataPath/Documents" ] #facilitates backwards-compatibility with older backups, or manual backups of a specific user's profile
					then
						mkdir "$dataPath/$homes"
						mv "$dataPath" "$dataPath/$homes/$currentUser" 2>&1 | tee -a "$dataPath/$logfileName"
				fi
				unset menuList
				unset menuListTails
				menuTitle="Are you logged in as the primary user who will receive the restored data?"
				menuList=(yes no)
				fncMenuGenerator
				qstnAsPrimaryUser="$menuOutput"
				if [ "$qstnAsPrimaryUser" = "yes" ]
					then
						primaryUser="$currentUser"
					else
						menuTitle="Select the current primary user of the computer, to whose profile data will be restored:"
						usersList=($(ls /$homes/))
						fncPrimaryUserHandler
						primaryUser=$userSelection
				fi #end check for primary user of this computer
				if [ ! -d "$dataPath/$homes/$primaryUser" ] #assumes that if the current user's name matches a profile that they sync, otherwise it prompts here for primary profile
					then
						while true
						do
							menuTitle="Please select the backed-up profile belonging to the current primary user:"
							usersList=($(ls $dataPath/$homes/))
							fncPrimaryUserHandler
							primaryProfile=$userSelection
							if [ -d "$dataPath/$homes/$primaryProfile" ]
								then
									break
								else
									continue
							fi
						done
					else
						primaryProfile=$primaryUser
				fi #end primary user check
				homeFolder="/$homes/$primaryUser"
				fncRestore
				#makes a desktop location for Shared and other profiles
				mkdir "$homeFolder/Desktop/OtherProfiles"
				#the line below is the ideal command, but bash for OSX does not support 'mv -t' which is required to work properly
				#find $dataPath/$homes -maxdepth 1 -mindepth 1 -not -name *$primaryProfile -print0 | xargs -0 mv -t $homeFolder/Desktop/OtherProfiles
				mv $dataPath/$homes/* $homeFolder/Desktop/OtherProfiles/ 2>&1 | tee -a "$homeFolder/Desktop/$logfileName"
				rm -r $homeFolder/Desktop/OtherProfiles/$primaryUser 2>&1 | tee -a "$homeFolder/Desktop/$logfileName" #removes the remnants of the primary profile, should only be duplicates and/or folder structure
				rm -r $dataPath 2>&1 | tee -a "$homeFolder/Desktop/$logfileName" #removes the empty backup folder from the desktop
				unset menuList
				unset menuListTails
				menuTitle="Data restored successfully. Would you like to assign admin rights to the primary user? (applies to Liberty University machines)"
				menuList=(yes no)
				fncMenuGenerator
				if [ "$menuOutput" = "yes" ]
					then
						fncAdminRights
				fi
			else #exits because the logged-in user is not having data restored to their profile
				echo "Please restart script when primary user's account is created."
				exit 6
		fi #end logged-in-as-primary-user if
		if [ -d "$logDir" ]
			then
				logCopyRestore="$date"_"$ritm"_UniBak_restorelog.txt
				rsync -q "$backupDir/$logfileName" "$logDir/$logCopyRestore"
				echo "Archived a copy of the logfile to the server."
			else
				echo "Unable to access $logDir. Not archiving logfile to the server."
		fi
elif [ "$unibakMode" = "Verify" ]
	then
		echo "Verification not currently available. Data should have been verified during backup/restore phase."
elif [ "$unibakMode" = "Exit" ]
	then
		exit
	else
		echo "What's going on?"
fi #end backup/restore if
echo "Operations complete. Exiting script."
exit 0
