#!/bin/bash

if [ "$TRACE" = "1" ]; then
	set -x
fi

# if command starts with an option, prepend mysqld
if [ "${1:0:1}" = '-' ]; then
	set -- mysqld "$@"
fi

# skip setup if they want an option that stops mysqld
wantHelp=
for arg; do
	case "$arg" in
		-'?'|--help|--print-defaults|-V|--version)
			wantHelp=1
			break
			;;
	esac
done

# usage: file_env VAR [DEFAULT]
#	ie: file_env 'XYZ_DB_PASSWORD' 'example'
# (will allow for "$XYZ_DB_PASSWORD_FILE" to fill in the value of
#  "$XYZ_DB_PASSWORD" from a file, especially for Docker's secrets feature)
file_env() {
	local var="$1"
	local fileVar="${var}_FILE"
	local def="${2:-}"
	if [ "${!var:-}" ] && [ "${!fileVar:-}" ]; then
		echo >&2 "error: both $var and $fileVar are set (but are exclusive)"
		exit 1
	fi
	local val="$def"
	if [ "${!var:-}" ]; then
		val="${!var}"
	elif [ "${!fileVar:-}" ]; then
		val="$(< "${!fileVar}")"
	fi
	export "$var"="$val"
	unset "$fileVar"
}

_check_config() {
	toRun=( "$@" --verbose --help --log-bin-index="$(mktemp -u)" )
	if ! errors="$("${toRun[@]}" 2>&1 >/dev/null)"; then
		cat >&2 <<-EOM
			ERROR: mysqld failed while attempting to check config
			command was: "${toRun[*]}"
			$errors
		EOM
		exit 1
	fi
}

_datadir() {
	"$@" --verbose --help --log-bin-index="$(mktemp -u)" 2>/dev/null | awk '$1 == "datadir" { print $2; exit }'
}

# allow the container to be started with `--user`
if [ "$1" = 'mysqld' -a -z "$wantHelp" -a "$(id -u)" = '0' ]; then
	_check_config "$@"
	export DATADIR="$(_datadir "$@")"
	mkdir -p "$DATADIR"
	
	mkdir -p /etc/mysql/conf.d

	cp /etc/mysqlconfiguration/* /etc/mysql/conf.d

	GALERA_CONF="${GALERA_CONF:-"/etc/mysql/conf.d/galera.cnf"}"
	
	if ! [ -f "${GALERA_CONF}" ]; then 
	    cp /opt/galera/galera.cnf "${GALERA_CONF}"
	fi
	
	function join {
	    local IFS="$1"; shift; echo "$*";
	}

	HOSTNAME=$(hostname)
	# Parse out cluster name, formatted as: petset_name-index
	IFS='-' read -ra ADDR <<< "$(hostname)"
	CLUSTER_NAME="${ADDR[0]}"
	
	counter=0
	i=0
	while (( "$counter" != "3" )); do
	    LINE=`nslookup $APPLICATION_NAME-$i.$APPLICATION_NAME-endpoints | grep Name | awk '{print $2}'`
	    if [[ "${LINE}" == *"${HOSTNAME}"* ]]; then
	        MY_NAME=$LINE
	    elif [[ "${LINE}" == "" ]]; then
		counter=$((counter + 1))
	    else	
	        PEERS=("${PEERS[@]}" $LINE)
	    fi

	    i=$((i + 1))
	done
	
	echo $PEERS
	echo $MY_NAME
	
	if [ "${#PEERS[@]}" = 0 ]; then
	    export WSREP_CLUSTER_ADDRESS=""
	else
	    export WSREP_CLUSTER_ADDRESS=$(join , "${PEERS[@]}")
	fi
	sed -i -e "s|^wsrep_node_address[[:space:]]*=.*$|wsrep_node_address=${MY_NAME}|" "${GALERA_CONF}"
	sed -i -e "s|^wsrep_cluster_name[[:space:]]*=.*$|wsrep_cluster_name=${CLUSTER_NAME}|" "${GALERA_CONF}"
	sed -i -e "s|^wsrep_cluster_address[[:space:]]*=.*$|wsrep_cluster_address=gcomm://${WSREP_CLUSTER_ADDRESS}|" "${GALERA_CONF}"
	
	# don't need a restart, we're just writing the conf in case there's an
	# unexpected restart on the node.
	
	if [ -n "$WSREP_CLUSTER_ADDRESS" ]; then
	    mkdir -p "$DATADIR/mysql"
	    echo "*** [Galera] Joining cluster: $WSREP_CLUSTER_ADDRESS"     
	else
	    echo "*** [Galera] Starting new cluster!"
	fi
	
	chown -R mysql:mysql "$DATADIR"
	exec gosu mysql "$BASH_SOURCE" "$@"
fi

if [ "$1" = 'mysqld' -a -z "$wantHelp" ]; then
	# still need to check config, container may have started with --user
	_check_config "$@"

	# Run Galera auto-recovery
	if [ -f /var/lib/mysql/ibdata1 ]; then
		echo "Galera - Determining recovery position..."
		set +e
		start_pos_opt=$(/opt/galera/galera-recovery.sh "${@:2}")
		set -e
		if [ $? -eq 0 ]; then
			echo "Galera recovery position: $start_pos_opt"
			set -- "$@" $start_pos_opt
		else
			echo "FATAL - Galera recovery failed!"
			exit 1
		fi
	fi

	# Get config
	DATADIR="$(_datadir "$@")"

	if [ ! -d "$DATADIR/mysql" ]; then
		file_env 'MYSQL_ROOT_PASSWORD'
		if [ -z "$MYSQL_ROOT_PASSWORD" -a -z "$MYSQL_ALLOW_EMPTY_PASSWORD" -a -z "$MYSQL_RANDOM_ROOT_PASSWORD" ]; then
			echo >&2 'error: database is uninitialized and password option is not specified '
			echo >&2 '  You need to specify one of MYSQL_ROOT_PASSWORD, MYSQL_ALLOW_EMPTY_PASSWORD and MYSQL_RANDOM_ROOT_PASSWORD'
			exit 1
		fi

		mkdir -p "$DATADIR"

		echo 'Initializing database'
		mysql_install_db --datadir="$DATADIR" --rpm
		echo 'Database initialized'

		"$@" --skip-networking --socket=/var/run/mysqld/mysqld.sock &
		pid="$!"

		mysql=( mysql --protocol=socket -uroot -hlocalhost --socket=/var/run/mysqld/mysqld.sock )

		for i in {30..0}; do
			if echo 'SELECT 1' | "${mysql[@]}" &> /dev/null; then
				break
			fi
			echo 'MySQL init process in progress...'
			sleep 1
		done
		if [ "$i" = 0 ]; then
			echo >&2 'MySQL init process failed.'
			exit 1
		fi

		if [ ! -z "$MYSQL_RANDOM_ROOT_PASSWORD" ]; then
			export MYSQL_ROOT_PASSWORD="$(pwgen -1 32)"
			echo "GENERATED ROOT PASSWORD: $MYSQL_ROOT_PASSWORD"
		fi

		"${mysql[@]}" <<-EOSQL
			-- What's done in this file shouldn't be replicated
			--  or products like mysql-fabric won't work
			SET @@SESSION.SQL_LOG_BIN=0;

			DELETE FROM mysql.user ;
			CREATE USER 'root'@'%' IDENTIFIED BY '${MYSQL_ROOT_PASSWORD}' ;
			GRANT ALL ON *.* TO 'root'@'%' WITH GRANT OPTION ;
			DROP DATABASE IF EXISTS test ;
			FLUSH PRIVILEGES ;
		EOSQL

                echo "${mysql[@]}"

		if [ ! -z "$MYSQL_ROOT_PASSWORD" ]; then
			mysql+=( -p"${MYSQL_ROOT_PASSWORD}" )
		fi
		
		file_env 'MYSQL_DATABASE'
		if [ "$MYSQL_DATABASE" ]; then
			echo "CREATE DATABASE IF NOT EXISTS \`$MYSQL_DATABASE\` ;" | "${mysql[@]}"
			mysql+=( "$MYSQL_DATABASE" )
		fi

		file_env 'MYSQL_USER'
		file_env 'MYSQL_PASSWORD'
		if [ "$MYSQL_USER" -a "$MYSQL_PASSWORD" ]; then
			echo "CREATE USER '$MYSQL_USER'@'%' IDENTIFIED BY '$MYSQL_PASSWORD' ;" | "${mysql[@]}"

			if [ "$MYSQL_DATABASE" ]; then
				echo "GRANT ALL ON \`$MYSQL_DATABASE\`.* TO '$MYSQL_USER'@'%' ;" | "${mysql[@]}"
			fi

			echo 'FLUSH PRIVILEGES ;' | "${mysql[@]}"
		fi

		echo
		for f in /docker-entrypoint-initdb.d/*; do
			case "$f" in
				*.sh)	 echo "$0: running $f"; . "$f" ;;
				*.sql)	echo "$0: running $f"; "${mysql[@]}" < "$f"; echo ;;
				*.sql.gz) echo "$0: running $f"; gunzip -c "$f" | "${mysql[@]}"; echo ;;
				*)		echo "$0: ignoring $f" ;;
			esac
			echo
		done

		if ! kill -s TERM "$pid" || ! wait "$pid"; then
			echo >&2 'MySQL init process failed.'
			exit 1
		fi


		echo

		echo 'MySQL init process done. Ready for start up.'
		echo
	fi
fi

exec "$@"
