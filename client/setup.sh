#! /bin/bash

# FIXME: Add verbose mode in which all commands are logged ...
# FIXME: Check for ntp on the test nodes and the client

HERE=${0%/*}
. $HERE/param.sh
. $HERE/client.sh
set -e

instantiate_template() {
    local I=("${INSTANTIATE[@]}") option n

    for ((n = 0; n < ${#NODES[n]}; n++)); do
	node=${NODES[n]}
	I[${#I[@]}]=--node=${FULL_HOSTNAMES[n]}
	for param in ${!DEVICE*} ${!DISK*} ${!META*} ${!NODE_ID*} ${!ADDRESS*}; do
	    eval "[ -n "\${$param[\$node]+x}" ]" || continue
	    option=${param//[0-9]}; option=${option//_/-}; option=${option,,}
	    eval "I[\${#I[@]}]=--\$option=\${$param[\$node]}"
	done
    done
    I[${#I[@]}]=$opt_template
    do_debug $HERE/instantiate-template "${I[@]}"
}

listen_to_events() {
    for node in "$@"; do
	mkdir -p $DRBD_TEST_JOB
	ssh -q root@$node drbdsetup events all --statistics > $DRBD_TEST_JOB/events-$node &
	echo $! > run/events-$node.pid
    done

    cleanup_events() {
	local pids

	shopt -s nullglob
	set -- run/events-*.pid
	if [ $# -gt 0 ]; then
	    pids=( $(cat "$@") )
	    kill "${pids[@]}"
	    wait "${pids[@]}"
	    rm -f "$@""$@"
	fi
    }
    register_cleanup cleanup_events
}

setup_usage() {
    [ $1 -eq 0 ] || exec >&2
    cat <<EOF
USAGE: ${0##*/} [options] ...
EOF
    exit $1
}

setup() {
    local options=`getopt -o vh --long job:,volume-group:,resource:,node:,device:,disk:,meta:,node-id:,address:,no-create-md,debug,port:,template:,cleanup:,help,verbose -- "$@"` || setup_usage 1
    eval set -- "$options"

    declare -g opt_debug= opt_verbose= opt_cleanup=always
    declare opt_resource= opt_create_md=1 opt_job= opt_volume_group=scratch
    declare opt_template=m4/template.conf.m4
    declare -a INSTANTIATE
    local logfile

    while :; do
	case "$1" in
	--port)
	    INSTANTIATE=("${INSTANTIATE[@]}" "$1=$2")
	    ;;
	esac

	case "$1" in
	-h|--help)
	    setup_usage 0
	    ;;
	--debug)
	    opt_debug=1
	    ;;
	-v|--verbose)
	    opt_verbose=1
	    ;;
	--job)
	    opt_job=$2
	    shift
	    ;;
	--volume-group)
	    opt_volume_group=$2
	    shift
	    ;;
	--resource)
	    opt_resource=$2
	    shift
	    ;;
	--template)
	    opt_template=$2
	    ;;
	--node)
	    new_node "$2" ${!DEVICE*} ${!DISK_SIZE*} ${!META_SIZE*}
	    shift
	    ;;
	--disk|--meta)
	    add_node_param "$1-size" "$node" "$2"
	    shift
	    ;;
	--node-id|--address|--device|--volume-group)
	    add_node_param "$1" "$node" "$2"
	    shift
	    ;;
	--port)
	    shift
	    ;;
	--no-create-md)
	    opt_create_md=
	    ;;
	--cleanup)
	    case "$2" in
	    always|never|success)
		opt_cleanup=$2
		;;
	    *)
		setup_usage 1
		;;
	    esac
	    shift
	    ;;
	--)
	    shift
	    break
	    ;;
	esac
	shift
    done

    # Treat the remaining arguments as node names
    while [ $# -gt 0 ]; do
	new_node "$1" ${!DEVICE*} ${!DISK_SIZE*} ${!META_SIZE*}
	shift
    done

    [ -n "$opt_job" -a ${#NODES} -gt 0 ] || setup_usage 1
    if [ -z "$opt_resource" ]; then
	opt_resource=$opt_job
    fi
    INSTANTIATE=("${INSTANTIATE[@]}" "--resource=$opt_resource")
    export DRBD_TEST_JOB=$opt_job

    connect_to_nodes "${NODES[@]}"
    declare -g ALL_NODES=( $(seq -f NODE%g 0 $((${#NODES[@]} - 1))) )

    if [ "$opt_cleanup" = "always" ]; then
	on -n "${ALL_NODES[@]}" onexit cleanup
    fi

    mkdir -p run

    listen_to_events "${NODES[@]}"

    for ((n = 0; n < ${#NODES[n]}; n++)); do
	node=${NODES[n]}
	logfile=$DRBD_TEST_JOB/$node.log
	rm -f $logfile
    done

    local hostname=$(hostname -f)

    sed -e "s:@PORT@:$RSYSLOGD_PORT:g" \
	-e "s:@SYSLOG_DIR@:$PWD/$DRBD_TEST_JOB:g" \
	-e "s:@SERVER@:${hostname%%.*}:g" \
	rsyslog.conf.in \
	> run/rsyslog.conf
    rsyslogd -c5 -i $PWD/run/rsyslogd.pid -f $PWD/run/rsyslog.conf
    register_cleanup kill $(cat run/rsyslogd.pid)

    for ((n = 0; n < ${#NODES[n]}; n++)); do
	node=${NODES[n]}

	on -n NODE$n rsyslogd $hostname $RSYSLOGD_PORT $node
	on -n NODE$n logger "Setting up test job $DRBD_TEST_JOB"
    done

    for ((n = 0; n < ${#NODES[n]}; n++)); do
	node=${NODES[n]}
	# FIXME: If the hostname on the remote host does not match
	# the name used here, we will loop here forever.  Fix this
	# by configuring rsyslog on the node to use the right name?
	logfile=$DRBD_TEST_JOB/$node.log
	i=0
	while :; do
	    (( ++i != 10 )) || echo "Waiting for $logfile to appear ..."
	    [ -e $logfile ] && break
	    sleep 0.2
	done
    done

    exec < /dev/null

    # Replace the node names we were passed with the names under which the nodes
    # know themselves: drbd depends on this in its config files.
    local FULL_HOSTNAMES=( "${NODES[@]}" ) 
    for ((n = 0; n < ${#NODES[n]}; n++)); do
	node=${NODES[n]}
	hostname=$(on NODE$n hostname -f)
	if [ "$hostname" != "$node" ]; then
	    echo "$node: full hostname = $hostname"
	    FULL_HOSTNAMES[$n]=$hostname
	fi
    done

    # FIXME: The disks could be created in parallel ...
    local disk device
    for ((n = 0; n < ${#NODES[n]}; n++)); do
	node=${NODES[n]}

	for disk_size in ${!DISK_SIZE*} ${!META_SIZE*}; do
	    eval "size=\${$disk_size[\$node]}"
	    [ -n "$size" ] || continue
	    disk=${disk_size/_SIZE}
	    device=$(on NODE$n create-disk \
		--job=$opt_job \
		--volume-group=$opt_volume_group \
		--size=$size $DRBD_TEST_JOB-${disk,,})
	    verbose "$node: disk $device created ($size)"
	    eval "$disk[\$node]=\"$device\""
	done
    done
    unset ${!DISK_SIZE*} ${!META_SIZE*}

    mkdir -p "$DRBD_TEST_JOB"
    instantiate_template > $DRBD_TEST_JOB/drbd.conf

    for ((n = 0; n < ${#NODES[n]}; n++)); do
	on NODE$n install-config < $DRBD_TEST_JOB/drbd.conf
	# FIXME: To clean up, shut the resource down if it is up:
	# on NODE$n register-cleanup ...
    done

    if [ -n "$opt_create_md" ]; then
	for ((n = 0; n < ${#NODES[n]}; n++)); do
	    msg=$(on NODE$n drbdadm -- --force create-md "$opt_resource" 2>&1) || status=$?
	    if [ -n "$status" ]; then
		echo "$msg" >&2
		exit $status
	    fi
	done
    fi

    if [ "$opt_cleanup" = "success" ]; then
	on "${ALL_NODES[@]}" cleanup
    fi
}
