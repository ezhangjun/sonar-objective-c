#!/bin/bash
## INSTALLATION: script to copy in your Xcode project in the same directory as the .xcodeproj file
## USAGE: ./run-sonar.sh
## DEBUG: ./run-sonar.sh -v
## WARNING: edit your project parameters in sonar-project.properties rather than modifying this script
#

trap "echo 'Script interrupted by Ctrl+C'; stopProgress; exit 1" SIGHUP SIGINT SIGTERM

function startProgress() {
	while true
	do
    	echo -n "."
	    sleep 5
	done
}

function stopProgress() {
	if [ "$vflag" = "" ]; then
		kill $PROGRESS_PID &>/dev/null
	fi
}

function testIsInstalled() {

	hash $1 2>/dev/null
	if [ $? -eq 1 ]; then
		echo >&2 "ERROR - $1 is not installed or not in your PATH"; exit 1;
	fi
}

function runCommand2() {
	command=$1
	shift
	set -x
	$command "$@"
	set +x
}

# Run a set of commands with logging and error handling
function runCommand() {

	# 1st arg: redirect stdout 
	# 2nd arg: command to run
	# 3rd..nth arg: args
	redirect=$1
	shift

	command=$1
	shift
	
	if [ "$nflag" = "on" ]; then
		# don't execute command, just echo it
		echo
		echo "+" $command "$@" ">" $redirect
	elif [ "$vflag" = "on" ]; then
		echo

		set -x #echo on
		$command "$@" > $redirect
		returnValue=$?	
		set +x #echo off			
		
		if [[ $returnValue != 0 ]] ; then
			stopProgress
			echo "ERROR - Command '$command $@' failed with error code: $returnValue"
			exit $returnValue
		fi
	else
	
		$command "$@" > $redirect

		if [[ $? != 0 ]] ; then
			stopProgress
			echo "ERROR - Command '$command $@' failed with error code: $returnValue"
			exit $?
		fi

	
		echo	
	fi	
}

## COMMAND LINE OPTIONS
vflag=""
nflag=""
oclint="on"
while [ $# -gt 0 ]
do
    case "$1" in
    -v)	vflag=on;;
    -n) nflag=on;;
	-nooclint) oclint="";;	    
	--)	shift; break;;
	-*)
        echo >&2 "Usage: $0 [-v]"
		exit 1;;
	*)	break;;		# terminate while loop
    esac
    shift
done

# Usage OK
echo "Running run-sonar.sh..."

## CHECK PREREQUISITES

# xctool, gcovr and oclint installed
testIsInstalled xctool
testIsInstalled gcovr
testIsInstalled oclint

# sonar-project.properties in current directory
if [ ! -f sonar-project.properties ]; then
	echo >&2 "ERROR - No sonar-project.properties in current directory"; exit 1;
fi

## READ PARAMETERS from sonar-project.properties

# Your .xcworkspace/.xcodeproj filename
workspaceFile=`sed '/^\#/d' sonar-project.properties | grep 'sonar.objectivec.workspace' | tail -n 1 | cut -d "=" -f2- | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'`
projectFile=`sed '/^\#/d' sonar-project.properties | grep 'sonar.objectivec.project' | tail -n 1 | cut -d "=" -f2- | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'`

if [[ "$workspaceFile" != "" ]] ; then
	xctoolCmdPrefix="xctool -workspace $workspaceFile -sdk iphonesimulator -arch i386 ONLY_ACTIVE_ARCH=NO"
else
	xctoolCmdPrefix="xctool -project $projectFile -sdk iphonesimulator -arch i386 ONLY_ACTIVE_ARCH=NO"
fi	

srcDirs=`sed '/^\#/d' sonar-project.properties | grep 'sonar.sources' | tail -n 1 | cut -d "=" -f2- | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'`

# The name of your application scheme in Xcode
appScheme=`sed '/^\#/d' sonar-project.properties | grep 'sonar.objectivec.appScheme' | tail -n 1 | cut -d "=" -f2- | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'`

# The name of your test scheme in Xcode
testScheme=`sed '/^\#/d' sonar-project.properties | grep 'sonar.objectivec.testScheme' | tail -n 1 | cut -d "=" -f2- | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'`

# The file patterns to exclude from coverage report
excludedPathsFromCoverage=`sed '/^\#/d' sonar-project.properties | grep 'sonar.objectivec.excludedPathsFromCoverage' | tail -n 1 | cut -d "=" -f2- | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'`

if [ "$vflag" = "on" ]; then
 	echo "Xcode workspace file is: $workspaceFile"
 	echo "Xcode project file is: $projectFile"
 	echo "Xcode application scheme is: $appScheme"
 	echo "Xcode test scheme is: $testScheme"
 	echo "Excluded paths from coverage are: $excludedPathsFromCoverage" 	
fi

## SCRIPT

# Start progress indicator in the background
if [ "$vflag" = "" ]; then
	startProgress &
	# Save PID
	PROGRESS_PID=$!
fi

# Create sonar-reports/ for reports output
if [[ ! (-d "sonar-reports") && ("$nflag" != "on") ]]; then
	if [ "$vflag" = "on" ]; then
		echo 'Creating directory sonar-reports/'
	fi
	mkdir sonar-reports
	if [[ $? != 0 ]] ; then
		stopProgress
    	exit $?
	fi
fi

# Extracting project information needed later
echo -n 'Extracting Xcode project information'
runCommand /dev/null $xctoolCmdPrefix -scheme "$appScheme" clean
runCommand /dev/stdout $xctoolCmdPrefix -scheme "$appScheme" -reporter json-compilation-database:compile_commands.json build

# Unit tests and coverage
if [ "$testScheme" = "" ]; then
	echo 'Skipping tests as no test scheme has been provided!'
	
	# Put default xml files with no tests and no coverage...
	echo "<?xml version='1.0' encoding='UTF-8' standalone='yes'?><testsuites name='AllTestUnits'></testsuites>" > sonar-reports/TEST-report.xml
	echo "<?xml version='1.0' ?><!DOCTYPE coverage SYSTEM 'http://cobertura.sourceforge.net/xml/coverage-03.dtd'><coverage><sources></sources><packages></packages></coverage>" > sonar-reports/coverage.xml
else

	echo -n 'Running tests using xctool'	
	runCommand sonar-reports/TEST-report.xml $xctoolCmdPrefix -scheme "$testScheme" -reporter junit GCC_GENERATE_TEST_COVERAGE_FILES=YES GCC_INSTRUMENT_PROGRAM_FLOW_ARCS=YES test

	echo -n 'Computing coverage report'
	# Extract the path to the .gcno/.gcda coverage files
	coverageFilesPath=$(grep 'command' compile_commands.json | sed 's#^.*-o \\/#\/#;s#",##' | grep "${projectFile%%.*}.build" | awk 'NR<2' | xargs dirname)
	if [ "$vflag" = "on" ]; then
		echo
		echo "Path for .gcno/.gcda coverage files is: $coverageFilesPath"
	fi

	# Build the --exclude flags
	excludedCommandLineFlags=""
	echo $excludedPathsFromCoverage | sed -n 1'p' | tr ',' '\n' > tmpFileRunSonarSh
	while read word; do
		excludedCommandLineFlags+=" --exclude $word"
	done < tmpFileRunSonarSh
	rm -rf tmpFileRunSonarSh
	if [ "$vflag" = "on" ]; then
		echo "Command line exclusion flags for gcovr is: $excludedCommandLineFlags"
	fi
	
	# Run gcovr with the right options
	runCommand sonar-reports/coverage.xml gcovr -r . $coverageFilesPath $excludedCommandLineFlags --xml 
	
fi	

if [ "$oclint" = "on" ]; then

	# OCLint
	echo -n 'Running OCLint...'
	
	# Build the --include flags
	currentDirectory=${PWD##*/}
	includedCommandLineFlags=""
	echo "$srcDirs" | sed -n 1'p' | tr ',' '\n' > tmpFileRunSonarSh
	while read word; do
		includedCommandLineFlags+="--include .*/${currentDirectory}/${word}.*"
	done < tmpFileRunSonarSh
	rm -rf tmpFileRunSonarSh
	if [ "$vflag" = "on" ]; then
		echo
		echo -n "Path included in oclint analysis is: $includedCommandLineFlags"
	fi
	
	# Run OCLint with the right set of compiler options
	runCommand /dev/stdout oclint-json-compilation-database $includedCommandLineFlags -- -report-type pmd -o sonar-reports/oclint.xml
else
	echo 'Skipping OCLint (test purposes only!)'
fi

# SonarQube
echo -n 'Running SonarQube using SonarQube Runner'
runCommand /dev/null sonar-runner
	
# Kill progress indicator
stopProgress

exit 0