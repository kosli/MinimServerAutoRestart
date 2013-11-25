#!/bin/sh
CONF=/etc/config/qpkg.conf
QPKG_NAME="MinimServerRestart"

# configuration
STATUS_REQUEST_TRIES=5
STATUS_REQUEST_TIMEOUT=10
STATUS_RUNNING_RETRY_TIMEOUT=10

# initialization
RESTART_HOME=$(/sbin/getcfg $QPKG_NAME Install_Path -d FALSE -f $CONF)
RESTART_LOG="$RESTART_HOME"/restart.log
RESTART_CONFIG="$RESTART_HOME"/restart.config
ERROR_LOG="$RESTART_HOME"/inotify-stderr.log

MINIM_HOME=$(/sbin/getcfg MinimServer Install_Path -d FALSE -f $CONF)
MINIM_CONFIG="$MINIM_HOME/data/minimserver.config"

MINIM_STDIN_PIPE="/tmp/minimserver-stdin.pipe"
MINIM_PID_FILE="/var/run/minimserver.pid"
PID=`cat $MINIM_PID_FILE`
MINIM_OUT_LOG="/tmp/minimserver-out-$PID.log"

# function to retrieve MinimServer output
minimserver_out ()
{
	if [ -e $MINIM_OUT_LOG ]; then
		BEFORE_LINES=$(wc -l $MINIM_OUT_LOG | cut -d ' ' -f 1)
	else
		BEFORE_LINES="0"
	fi
	let BEFORE_LINES=$BEFORE_LINES+1

	# when MINIM_PID_FILE does not exist, it must be assumed that MinimServer is not running
	[ ! -e "$MINIM_PID_FILE" ] && return 4
	PID=$(cat "$MINIM_PID_FILE") > /dev/null
	# when PID_FILE is empty, it must be assumed that MinimServer is not running
	[ -z "$PID" ] && return 4
	# check whether a process with the PID from PID_FILE is run by the daemon user
	PID_CHECK=$(ps | grep "$PID" | grep "minimser") > /dev/null
	# if not, MinimServer is not running
	[ -z "$PID_CHECK" ] && return 4
	
	if [ -p $MINIM_STDIN_PIPE ]; then
		# do in background to avoid the package to hang in some rare cases
		echo "about" > $MINIM_STDIN_PIPE &
	else
		# minimstdinpipe is not available
		return 1
	fi
	
	if [ -e $MINIM_OUT_LOG ]; then
		COUNTER=$STATUS_REQUEST_TIMEOUT
		while [ "$COUNTER" -ne "0" ]
		do
			OUTPUT_LINE=$(tail -n +$BEFORE_LINES $MINIM_OUT_LOG | grep 'is running\|stopped\|starting\|stopping\|restarting\|closing\|exiting')
			[ -n "$OUTPUT_LINE" ] && break
			sleep 1
			let COUNTER=$COUNTER-1
		done
		# MinimServer did not respond
		[ "$COUNTER" == "0" ] && return 2
	else
		# minimserver-out.log is not available
		return 3
	fi
	
	echo $OUTPUT_LINE
}

parse_config () {
	# $1 ... property name
	# $2 ... default value
	if [ -f "$RESTART_CONFIG" ]; then
		# get the property value
		PROPERTY="$(sed '/^\#/d' $RESTART_CONFIG | grep $1 | cut -d'=' -f 2)"
		if [ -z "$PROPERTY" ]; then
			# property is not available, set to default
			echo "$1"="$2" >> $RESTART_CONFIG
			PROPERTY="$2"
		fi
	else
		# the config file is not available.
		# create it and set property to default
		echo "$1"="$2" >> $RESTART_CONFIG
	fi
	# return the property value
	echo "$PROPERTY"
}


# cehck for inotifywait errors
FIRST_ERR_LINE=$({ tail -n +1 -f $ERROR_LOG & } | head -n 1)
if echo $FIRST_ERR_LINE | grep -q 'Setting up watches.'; then
	echo $FIRST_ERR_LINE >> $RESTART_LOG
else
	echo "An inotify error occured, see $ERROR_LOG." >> $RESTART_LOG
	exit 1
fi
SECOND_ERR_LINE=$({ tail -n +2 -f $ERROR_LOG & } | head -n 1)
if echo $SECOND_ERR_LINE | grep -q 'Watches established'; then
	echo $SECOND_ERR_LINE >> $RESTART_LOG
else
	echo "An inotify error occured, see $ERROR_LOG." >> $RESTART_LOG
	exit 1
fi
echo "Successfully initialized inotifywait." >> $ERROR_LOG

# infinite watch loop
while :
do
	echo "*************************************" >> $RESTART_LOG
	echo $(date) >> $RESTART_LOG
	echo "Watching directory(ies) $1 for file system events..." >> $RESTART_LOG
	# block the script till the next inotify event appears in $RESTART_LOG
	{ tail -n 0 -f $RESTART_LOG & } | head -n 1 > /dev/null
	
	# extract auto restart properties
	FIRST_TIMEOUT="$(parse_config firstTimeout 5)"
	RESTART_TIMEOUT="$(parse_config restartTimeout 20)"
	RESTART_BEHAVIOUR="$(parse_config restartBehaviour awaitRunning)"
	
	# after an event occured, await the first timeout for possibly related events
	echo $(date) >> $RESTART_LOG
	echo "Awaiting $FIRST_TIMEOUT seconds timeout for related events..." >> $RESTART_LOG
	sleep $FIRST_TIMEOUT
	
	# check $RESTART_LOG for possibly subsequent events
	PREV_LINE="Awaiting $RESTART_TIMEOUT seconds timeout to restart..."
	echo $PREV_LINE >> $RESTART_LOG
	sleep $RESTART_TIMEOUT
	POST_LINE=$(tail -n 1 $RESTART_LOG)
	
	while [ ! "$PREV_LINE" == "$POST_LINE" ]
	do
		PREV_LINE="Resetting $RESTART_TIMEOUT seconds timeout to restart..."
		echo $PREV_LINE >> $RESTART_LOG
		sleep $RESTART_TIMEOUT
		POST_LINE=$(tail -n 1 $RESTART_LOG)
	done
	
	# retrieve the MinimServer status
	#######################################
	STATUS_REQUEST_FLAG=1
	COUNTER=$STATUS_REQUEST_TRIES
	while [ "$STATUS_REQUEST_FLAG" -ne "0" -a "$COUNTER" -ne "0" ]
	do
		STATUSLINE="$(minimserver_out)"
		STATUS_REQUEST_FLAG=$?
		case "$STATUS_REQUEST_FLAG" in
			"1")
				echo "minimstdinpipe is not available. Please install the MinimServer package 0.63.3 or above." >> $RESTART_LOG
				STATUSLINE="empty"
				# MinimServer seems to be to old (or minimstdinpipe has been accidentally deleted), no need to retry
				COUNTER=1
			;;
			"2")
				echo "MinimServer seems to be not responsive. Trying again $COUNTER times..." >> $RESTART_LOG
				STATUSLINE="empty"
				sleep 2
			;;
			"3")
				echo "The file $MINIM_OUT_LOG is not available. Trying again $COUNTER times..." >> $RESTART_LOG
				STATUSLINE="empty"
				sleep 2
			;;
			"4")
				echo "MinimServer seems not to be running." >> $RESTART_LOG
				STATUSLINE="empty"
				# MinimServer is not running, no need to retry
				COUNTER=1
			;;
		esac
		let COUNTER=COUNTER-1
	done
	#######################################
	[ -n "$STATUSLINE" -a ! "$STATUSLINE" == "empty" ] && echo $STATUSLINE >> $RESTART_LOG
	
	# take action depending on the MinimServer status
	if echo $STATUSLINE | grep -q 'is running'; then
		echo "Restarting now..." >> $RESTART_LOG
		echo "restart" > $MINIM_STDIN_PIPE
	elif echo $STATUSLINE | grep -q 'stopped\|stopping\|closing\|exiting'; then
		echo "No restart will be issued." >> $RESTART_LOG
	elif echo $STATUSLINE | grep -q 'starting\|restarting'; then				
		# MinimServer is currently starting. Evaluate the restartBehaviour property.
		echo "The restartBehaviour property is set to ${RESTART_BEHAVIOUR}." >> $RESTART_LOG
		case "$RESTART_BEHAVIOUR" in
			"forceRestart")
				echo "Stopping and restarting now..." >> $RESTART_LOG
				echo "stop" > $MINIM_STDIN_PIPE
				sleep 2
				echo "restart" > $MINIM_STDIN_PIPE
			;;
			"awaitRunning")
				echo "Waiting 10 seconds..." >> $RESTART_LOG
				sleep $STATUS_RUNNING_RETRY_TIMEOUT
				
				STATUS="false"
				while [ "$STATUS" == "false" ]
				do
					# retrieve the MinimServer status
					#######################################
					STATUS_REQUEST_FLAG=1
					COUNTER=$STATUS_REQUEST_TRIES
					while [ "$STATUS_REQUEST_FLAG" -ne "0" -a "$COUNTER" -ne "0" ]
					do
						STATUSLINE="$(minimserver_out)"
						STATUS_REQUEST_FLAG=$?
						case "$STATUS_REQUEST_FLAG" in
							"1")
								echo "minimstdinpipe is not available. Please install the MinimServer package 0.63.3 or above." >> $RESTART_LOG
								STATUSLINE="empty"
								# MinimServer seems to be to old (or minimstdinpipe has been accidentally deleted), no need to retry
								COUNTER=1
							;;
							"2")
								echo "MinimServer seems to be not responsive. Trying again $COUNTER times..." >> $RESTART_LOG
								STATUSLINE="empty"
								sleep 2
							;;
							"3")
								echo "The file $MINIM_OUT_LOG is not available. Trying again $COUNTER times..." >> $RESTART_LOG
								STATUSLINE="empty"
								sleep 2
							;;
							"4")
								echo "MinimServer seems not to be running." >> $RESTART_LOG
								STATUSLINE="empty"
								# MinimServer is not running, no need to retry
								COUNTER=1
							;;
						esac
						let COUNTER=COUNTER-1
					done
					#######################################
					
					if echo $STATUSLINE | grep -q 'is running'; then
						echo "MinimServer is running. Restarting now..." >> $RESTART_LOG
						echo "restart" > $MINIM_STDIN_PIPE
						STATUS="true"
					elif echo $STATUSLINE | grep -q 'stopped\|stopping\|closing\|exiting'; then
						echo "MinimServer is stopped. No restart will be issued." >> $RESTART_LOG
						STATUS="true"
					elif echo $STATUSLINE | grep -q 'starting\|restarting'; then
						echo "MinimServer is still starting. Waiting another 10 seconds..." >> $RESTART_LOG
						sleep $STATUS_RUNNING_RETRY_TIMEOUT
					else
						echo "MinimServer status could not be retrieved. Do nothing." >> $RESTART_LOG
						if [ -n "$STATUS_OUTPUT" ]; then
							echo "##############################" >> $RESTART_LOG
							echo "$STATUS_OUTPUT" >> $RESTART_LOG
							echo "##############################" >> $RESTART_LOG
						fi
						STATUS="true"
					fi
				done
			;;
			"doNothing")
				echo "MinimServer is starting. Do nothing." >> $RESTART_LOG
			;;
			*)
				echo "$RESTART_BEHAVIOUR is not a valid option. Do nothing." >> $RESTART_LOG
			;;
		esac
	else
		echo "MinimServer status could not be retrieved. Do nothing." >> $RESTART_LOG
		if [ -n "$STATUS_OUTPUT" ]; then
			echo "##############################" >> $RESTART_LOG
			echo "$STATUS_OUTPUT" >> $RESTART_LOG
			echo "##############################" >> $RESTART_LOG
		fi
	fi
done