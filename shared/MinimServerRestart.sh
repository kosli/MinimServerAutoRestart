#!/bin/sh
CONF=/etc/config/qpkg.conf
QPKG_NAME="MinimServerRestart"

RESTART_USER="minimautorestart"
RESTART_HOME="`cat /etc/passwd | grep "MinimServerAutoRestart daemon user" | cut -f6 -d':'`"
RESTART_LOG="$RESTART_HOME"/restart.log
RESTART_CONFIG="$RESTART_HOME"/restart.config
ERROR_LOG="$RESTART_HOME"/inotify-stderr.log

MINIM_HOME="`cat /etc/passwd | grep "MinimServer daemon user" | cut -f6 -d':'`"
MINIM_CONFIG="$MINIM_HOME/appData/minimserver.config"

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
 
case "$1" in
  start)
    ENABLED=$(/sbin/getcfg $QPKG_NAME Enable -u -d FALSE -f $CONF)
    if [ "$ENABLED" != "TRUE" ]; then
        echo "$QPKG_NAME is disabled."
        exit 1
    fi
    : ADD START ACTIONS HERE
    source /etc/profile
    
    # check for inotifywait being available
    which inotifywait > /dev/null
    if [ $? -ne 0 ]; then
            echo "The inotifywait binary is not available. Please reinstall the MinimServer Auto Restart package." >> $SYNOPKG_TEMP_LOGFILE
            exit 1
    fi
    
    # grep pid of minimautorestart.sh
    PID=$(ps -w | grep "^ *[0-9]* minimaut.*[m]inimautorestart.*" | awk '{print $1}')
    if [ -n "$PID" ]; then
            echo "MinimServer Auto Restart is already running." >> $SYNOPKG_TEMP_LOGFILE
            exit 1
    else
            # extract minimserver content directories
            if [ -z "$MINIM_HOME" ]; then
                    echo "The home directory of MinimServer could not be extracted. Please install MinimServer." >> $SYNOPKG_TEMP_LOGFILE
                    exit 1
            fi
        
            if [ -f "$MINIM_CONFIG" ]; then
                    # first sed replaces '\n' by '\'
                    # second sed quotes fields separated by '\'
                    # third sed replaces '\"' by '"'
                    # workaround is required because it is not possible to match NOT \n. May be improved!
                    CONTENT_DIRS=$(cat $MINIM_CONFIG | grep contentDir | cut -d ' ' -f 3- | sed  's/\\n/\\/g' | sed 's/[^\][^\]*/"&" /g' | sed 's/\\"/"/g')
            else
                    echo "minimserver.config could not be located in ${MINIM_HOME}/appData." >> $SYNOPKG_TEMP_LOGFILE
                    exit 1
            fi
            if [ -z "CONTENT_DIRS" ]; then
                    echo "Content directories could not be retrieved." >> $SYNOPKG_TEMP_LOGFILE
                    exit 1
            fi
              
            echo $(date) > $RESTART_LOG
            echo "Starting MinimServer Auto Restart service v${SYNOPKG_PKGVER}." >> $RESTART_LOG
        
            # extract inotify properties
            INOTIFY_EVENTS="$(parse_config inotifyEvents close_write,move,delete,create)"
            INOTIFY_EXCLUDE="$(parse_config inotifyExclude '@eaDir|Thumbs\.db')"
            INOTIFY_ROOT="$(parse_config inotifyRoot false)"

            # initiate inotifywait monitoring
            echo "Watching the following directory(ies): $CONTENT_DIRS" >> $RESTART_LOG
            echo "Watching for the following events: $INOTIFY_EVENTS" >> $RESTART_LOG  
            echo "Exclude from intotify events: $INOTIFY_EXCLUDE" >> $RESTART_LOG
            if [ "$INOTIFY_ROOT" == "true" ]; then
                    echo "Invoking inotifywait with root permissions..." >> $RESTART_LOG
                    su -s /bin/sh -c "inotifywait -m -r -e $INOTIFY_EVENTS --exclude '$INOTIFY_EXCLUDE' $CONTENT_DIRS >> $RESTART_LOG 2>$ERROR_LOG &"
            else
                    echo "Invoking inotifywait by the daemon user..." >> $RESTART_LOG
                    chown -R $RESTART_USER $RESTART_LOG
                    su - $RESTART_USER -s /bin/sh -c "inotifywait -m -r -e $INOTIFY_EVENTS --exclude '$INOTIFY_EXCLUDE' $CONTENT_DIRS >> $RESTART_LOG 2>$ERROR_LOG &"
            fi
            sleep 1
            chown -R $RESTART_USER $RESTART_HOME

            # initiate the infinite wtch loop
            su - $RESTART_USER -s /bin/sh -c "${SYNOPKG_PKGDEST}/minimautorestart.sh '$CONTENT_DIRS' &"
    fi
    exit 0
    ;;

  stop)
    : ADD STOP ACTIONS HERE
    [ -n "$(ps -w | grep "^ *[0-9]* [m]inimaut")" ] && ps -w | grep "^ *[0-9]* [m]inimaut" | awk '{ print $1}' | xargs kill > /dev/null 2>&1
    # if inotify has been invoked with root permissions, this has to be killed, too
    [ -n "$(ps -w | grep "^ *[0-9]* [r]oot.*inotifywait -m -r -e")" ] && ps -w | grep "^ *[0-9]* [r]oot.*inotifywait -m -r -e" | awk '{ print $1}' | xargs kill > /dev/null 2>&1
    sleep 4
    exit 0 
    ;;

  status)
    if `ps -w | grep "^ *[0-9]* minimaut.*[m]inimautorestart.*" > /dev/null`; then
      exit 0
    else
      exit 1
    fi
    ;;

  log)
    echo $RESTART_HOME/restart.log
    exit 0
    ;;

  restart)
    $0 stop
    $0 start
    ;;

  *)
    echo "Usage: $0 {start|stop|restart|status|log}"
    exit 1
esac

exit 0
