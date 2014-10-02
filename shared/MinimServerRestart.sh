#!/bin/sh
CONF=/etc/config/qpkg.conf
QPKG_NAME="MinimServerRestart"

# RESTART_USER="minimautorestart"
RESTART_HOME=$(/sbin/getcfg $QPKG_NAME Install_Path -d FALSE -f $CONF)
RESTART_LOG="$RESTART_HOME"/restart.log
RESTART_CONFIG="$RESTART_HOME"/restart.config
ERROR_LOG="$RESTART_HOME"/inotify-stderr.log

MINIM_HOME=$(/sbin/getcfg MinimServer Install_Path -d FALSE -f $CONF)
MINIM_CONFIG="$MINIM_HOME/data/minimserver.config"

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

    # check for inotifywait being available
    which inotifywait > /dev/null
    if [ $? -ne 0 ]; then
            echo "The inotifywait binary is not available. Please reinstall the MinimServer Restart package."
            exit 1
    fi

    # grep pid of minimautorestart.sh
    PID=$(ps -w | grep "^ *[0-9]* minimaut.*[m]inimautorestart.*" | awk '{print $1}')
    if [ -n "$PID" ]; then
            echo "MinimServer Restart is already running."
            exit 1
    else
            # extract minimserver content directories
            if [ -z "$MINIM_HOME" ]; then
                    echo "The home directory of MinimServer could not be extracted. Please install MinimServer." 
                    exit 1
            fi
        
            if [ -f "$MINIM_CONFIG" ]; then
                    # first sed replaces '\n' by '\'
                    # second sed quotes fields separated by '\'
                    # third sed replaces '\"' by '"'
                    # workaround is required because it is not possible to match NOT \n. May be improved!
                    CONTENT_DIRS=$(cat $MINIM_CONFIG | grep contentDir | cut -d ' ' -f 3- | sed  's/\\n/\\/g' | sed 's/[^\][^\]*/"&" /g' | sed 's/\\"/"/g')
            else
                    echo "minimserver.config could not be located in ${MINIM_HOME}/data."
                    exit 1
            fi
            if [ -z "CONTENT_DIRS" ]; then
                    echo "Content directories could not be retrieved."
                    exit 1
            fi
              
            echo $(date) 
            echo "Starting MinimServer Restart service."
        
            # extract inotify properties
            INOTIFY_EVENTS="$(parse_config inotifyEvents close_write,move,delete,create)"
            INOTIFY_EXCLUDE="$(parse_config inotifyExclude '@eaDir|Thumbs\.db')"

            # initiate inotifywait monitoring
            echo "Watching the following directory(ies): $CONTENT_DIRS"
            echo "Watching for the following events: $INOTIFY_EVENTS"
            echo "Exclude from intotify events: $INOTIFY_EXCLUDE"

            echo "Invoking inotifywait..."
            /bin/sh -c "inotifywait -m -r -e $INOTIFY_EVENTS --exclude '$INOTIFY_EXCLUDE' $CONTENT_DIRS >> $RESTART_LOG 2>$ERROR_LOG &"
            sleep 1

            # initiate the infinite wtch loop
            /bin/sh -c "${RESTART_HOME}/minimautorestart.sh '$CONTENT_DIRS' &"
    fi
    exit 0
    ;;

  stop)
    [ -n "$(ps -w | grep "^ *[0-9]*.*[m]inimautorestart\.sh")" ] && ps -w | grep "^ *[0-9]*.*[m]inimautorestart\.sh" | awk '{ print $1}' | xargs kill > /dev/null 2>&1
    [ -n "$(ps -w | grep "^ *[0-9]* [a]dmin.*inotifywait -m -r -e")" ] && ps -w | grep "^ *[0-9]* [a]dmin.*inotifywait -m -r -e" | awk '{ print $1}' | xargs kill > /dev/null 2>&1
    sleep 4
    exit 0 
    ;;

  restart)
    $0 stop
    $0 start
    ;;

  *)
    echo "Usage: $0 {start|stop|restart}"
    exit 1
esac

exit 0
