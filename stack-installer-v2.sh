#!/bin/bash
#
# Simple script to deploy single/multi node Elasticsearch Cluster 
# with optional Vectra Stream content. 
# Main goal is to simplify dev/test deployment with all the necessary
# configuration.

### variables ###
STREAM_INPUT_PORT=9009                  # Port to set in Stream 
ES_VERSION="9.2.0"                      # Elasticsearch+Kibana container version
ES_BOOTSTRAP_PASSWORD="Elastic123!"     # Bootstrap password for initialization / can be changed later from Kibana
CLUSTER_NAME="stream"                   # Elasticsearch cluster name
DOCKER=""
MODE=""
MASTER_COUNT=0
HOT_COUNT=0
WARM_COUNT=0
COLD_COUNT=0
SHARD_SIZE="50"                         # Default shard size of ERlasticsearch ILM

# config backup retention
CONFIG_BACKUP_LIMIT=5

# Initialize arrays/variables
CONT_MEM=()
JVM_MEM=()

# Main arrays
declare -A DATA
declare -A NODE_LABEL

# get current script's working dir
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# get system hostname / fqdn
HOST_IP=$(hostname -I | awk '{print $1}')
HOST_NAME=$(hostname)
HOST_FQDN=$(hostname -f || echo "$(hostname).$(awk '/^search/ {print $2}' /etc/resolv.conf | head -1)")
NET_IF=$(ip -o addr show | awk -v ip="$HOST_IP" '$4 ~ ip {print $2}')

# error/output handler
q() { "$@" >/dev/null 2>&1; }   # silence all
qe() { "$@" 2>/dev/null; }   # silence errors only
qo() { "$@" >/dev/null; }    # silence stdout only

# Get stored variables if exists else create
if [[ -f "$SCRIPT_DIR/.vars" ]]; then q source "$SCRIPT_DIR/.vars"; else touch "$SCRIPT_DIR/.vars"; fi

# function to set variable in .vars for persistency
setvar() {
    local var="$1"
    local input="$2"
    local mode="${3:-auto}"  # default to 'var'
    local value

    # value resolution
    if [[ "$mode" == "val" ]]; then
        value="$input"
    elif [[ "$mode" == "var" ]]; then
        [[ -v $input ]] && value="${!input}" || value=""
    elif [[ "$mode" == "auto" ]]; then
        if [[ -v $input ]]; then
            value="${!input}"
        else
            value="$input"
        fi
    else
        return 1
    fi

    # escape brackets for regex
    local escaped_var
    escaped_var=$(printf "%s" "$var" | sed 's/\[/\\[/g; s/\]/\\]/g')

    if [[ -z "$value" ]]; then
        sed -i "/^${escaped_var}=/d" "$SCRIPT_DIR/.vars" 2>/dev/null
    else
        if grep -q "^${escaped_var}=" "$SCRIPT_DIR/.vars" 2>/dev/null; then
            sed -i "s|^${escaped_var}=.*|$var=\"$value\"|" "$SCRIPT_DIR/.vars"
        else
            echo "$var=\"$value\"" >> "$SCRIPT_DIR/.vars"
        fi
    fi
}

# Colors for formatting
if [[ -t 1 ]]; then
    if qe command -v tput; then
        R=$(tput bold; tput setaf 1)   # Bright/Bold Red
        G=$(tput bold; tput setaf 2)   # Bright/Bold Green
        Y=$(tput bold; tput setaf 3)   # Bright/Bold Yellow
        B=$(tput bold; tput setaf 4)   # Bright/Bold Blue
        M=$(tput bold; tput setaf 5)   # Bright/Bold Magenta
        C=$(tput bold; tput setaf 6)   # Bright/Bold Cyan
        N=$(tput bold; tput setaf 7)   # Bright/Bold White
    else
        R='\033[0;31m'; BR=$R # Red
        G='\033[0;32m'; BG=$G # Green
        Y='\033[1;33m'; BY=$Y # Yellow
        B='\033[1;34m'; BB=$B # Blue
        M='\033[1;35m'; BM=$M # Magenta
        C='\033[0;36m'; BC=$c # Cyan
        W='\033[0;37m'; BW=$c # Cyan
        N='\033[0m'   # Reset
    fi
else
    # fallback to standart if not tty
    R=''; G=''; Y=''; C=''; N=''
fi

# detect OS and package manager
detect_os() {
    # initialize
    OS_ID=""
    PKG_MANAGER="unknown"

    # Prefer the canonical os-release if present
    if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        OS_ID=${ID,,}            # lowercase id, e.g. ubuntu, debian
    fi

    # Fallback mapping if /etc/os-release wasn't available or empty
    if [[ -z "$OS_ID" ]]; then
        declare -A _file_map=(
            [/etc/alpine-release]=alpine
            [/etc/debian_version]=debian
            [/etc/lsb-release]=ubuntu
            [/etc/centos-release]=centos
            [/etc/redhat-release]=rhel
            [/etc/fedora-release]=fedora
        )
        for f in "${!_file_map[@]}"; do
            if [[ -f "$f" ]]; then
                OS_ID=${_file_map[$f]}
                break
            fi
        done
    fi

    # Decide package manager by OS_ID or ID_LIKE
    case "$OS_ID" in
        ubuntu|debian|linuxmint)
            PKG_MANAGER="apt-get" ;;
        alpine)
            PKG_MANAGER="apk" ;;
        fedora|centos|rhel|rocky|ol)
            # modern RedHat-family prefer dnf; fallback to yum if not present
            if command -v dnf >/dev/null 2>&1; then
                PKG_MANAGER="dnf"
            else
                PKG_MANAGER="yum"
            fi
            ;;
    esac

    # Final guard: if still unknown, try binary presence
    if [[ "$PKG_MANAGER" == "unknown" ]]; then
        if command -v apt-get >/dev/null 2>&1; then PKG_MANAGER="apt-get"; fi
        if command -v dnf >/dev/null 2>&1; then PKG_MANAGER="dnf"; fi
        if command -v yum >/dev/null 2>&1; then PKG_MANAGER="yum"; fi
        if command -v apk >/dev/null 2>&1; then PKG_MANAGER="apk"; fi
    fi

    # Export for other functions to read (optional)
    export OS_ID PKG_MANAGER
}

# detect OS and package manager
#declare -A oss=(
#    [/etc/alpine-release]="apk"
#    [/etc/debian_version]="apt-get"
#    [/etc/lsb-release]="apt-get"
#    [/etc/centos-release]="dnf"
#    [/etc/redhat-release]="dnf"
#    [/etc/fedora-release]="dnf"
#)
#
#pkgmanager() {
#    for f in "${!oss[@]}"; do
#        if [[ -f "$f" ]]; then
#            echo "${oss[$f]}"
#            return 0
#        fi
#    done
#    echo "unknown"
#    return 1
#}


# default resource distribution
# the sum of below components are equal to RESERVED_MEM
# can be change according to host machine but these are the min requirements
DOZZLE_MEM="128m"
FB_MEM="2g"
FB_STORAGE="20G"
HA_MEM="768m"
KIBANA_MEM="4g"
PORT_MEM="128m"
RESERVED_MEM=10; setvar "RESERVED_MEM" "RESERVED_MEM"    # reserved for OS + sidecars

# resource distibution / weights
WEIGHT_HOT=9;   setvar "WEIGHT_HOT" "WEIGHT_HOT"   # hot nodes are 8x heavier
WEIGHT_WARM=2;  setvar "WEIGHT_WARM" "WEIGHT_WARM" # warm nodes baseline
WEIGHT_COLD=1;  setvar "WEIGHT_COLD" "WEIGHT_COLD" # cold nodes are lightest
MASTER_FIXED=8; setvar "MASTER_FIXED" "MASTER_FIXED"  # each master gets fixed memory

# needed for disk usage calculation
MB_PER_IP_DAY=35   # MB/day per IP (avg between 25–50 MB)
REPLICA_FACTOR=1   # 1 means no replica, 2 means every doc stored twice, etc.

# check function for various options
check() {
    local type="$1"

    # check if cert and its dir exist else generate self signed cert
    if [[ "$type" == "cert" ]]; then
        if [[ ! -f "${DATA[base]}/certs/stack.pem" ]]; then
            check "configpath"
            printf "⚠️  ${G}Stack certificate does not exist...generating\n"
            generate "cert"
        fi
    fi
    # check if config dir exists
    if [[ "$type" == "configpath" ]]; then
        if [[ ! -d "${DATA[base]}/config"  ]]; then
            check "datapath"
            printf "📂 ${Y}Creating config path..."
            sudo mkdir -p ${DATA[base]}/config
            sudo chown -R "$USER:docker" ${DATA[base]}/config
            printf "\r📂 ${G}Creating config path...✅\n"
        fi
    fi
    # check if data paths exist
    if [[ "$type" == "datapath" ]]; then
        if [[ ! -d "${DATA[base]:-}"  ]]; then
            printf "⚠️  ${Y}Default data path does not exist...requesting\n\n"
            get "storage"
        fi
    fi
    # check if docker exists
    if [[ "$type" == "docker" ]]; then
        if ! q command -v docker; then
            echo "❌ ${R}Docker installation does not exist, returning."
            key
            return 1
        fi
    fi
    # check if elastic search cinfig exists
    if [[ "$type" == "esconfig" ]]; then
        if [[ ! -f "${DATA[base]}/config/master1.yml"  ]]; then
            printf "⚠️  ${Y}Elastic config files not found...requesting\n\n"
            generate "elastic"
        fi
    fi
    # check if master1 is up and running
    if [[ "$type" == "elastic" ]]; then
        # check if master1 is up
        local MASTER_IP=$(qe sudo docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' master1)
        if [[ -z "$MASTER_IP" ]]; then 
            printf "❌${N} Container ${Y}master1 ${N}not running or does not exists"
            s 1
            return 1
        else
            printf "⏲️  ${Y}Waiting for Elasticsearch to be ready..."
            until [[ $(curl -s "http://$MASTER_IP:9200/_cluster/health" | jq -r '.status') == "green" ]]; do
                sleep 30
            done
            printf "\r⏲️  ${G}Waiting for Elasticsearch to be ready...✅\n"
        fi
    fi
    # check if elasticsearch node path exists then remove and re-create
    if [[ "$type" == "espath" ]]; then
        if [[ "$2" == "remove" ]]; then
            if [[ -d "$3" ]]; then
                printf "🗑️  ${Y}Cleaning data dir of ${C}$5${Y}: $3"
                q sudo rm -rf "$3"
                printf "\r🗑️  ${G}Cleaning data dir of ${C}$5${G}: $3${G}...✅\n"
            fi
            if [[ -d "$4" ]]; then
                printf "🗑️  ${Y}Cleaning logs dir of ${C}$5${Y}: $4"
                q sudo rm -rf "$4"
                printf "\r🗑️  ${G}Cleaning logs dir of ${C}$5${G}: $4${G}...✅\n"
            fi
        fi
        
        if [[ ! -d "$3" ]]; then
            check "datapath"
            printf "📂  ${Y}Creating data and log dirs of ${C}$5"
            q sudo mkdir -p "$3"; q sudo mkdir -p "$4"
            q sudo chown -R $USER:docker "$3" "$4"
            printf "\r📂  ${G}Creating data and log dirs of ${C}$5...✅\n"
        fi
    fi
    # check if fluent-bit storage dir exists
    if [[ "$type" == "fbpath" ]]; then
        if [[ ! -d "${DATA[base]}/fluent-bit/storage"  ]]; then
            check "datapath"
            printf "📂  ${Y}Creating Fluent-Bit data folder"
            sudo mkdir -p "${DATA[base]}/fluent-bit/storage"
            sudo chown -R $USER:docker "${DATA[base]}/fluent-bit"
            printf "\r📂  ${G}Creating Fluent-Bit data folder...✅\n"
        fi
    fi
    # check if kibana is up and running
    if [[ "$type" == "kibana" ]]; then
        # check if kibana is up
        local KIBANA_IP=$(qe sudo docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' kibana)
        if [[ -z "$KIBANA_IP" ]]; then 
            printf "❌${N} Container ${Y}kibana ${N}not running or does not exists"
            return 1
        else
            printf "⏲️  ${Y}Waiting for Kibana to be ready"
            until [[ $(curl -s "http://$KIBANA_IP:5601/api/status" | jq -r '.status.overall.level') ==  "available" ]]; do
                sleep 30
            done
            printf "\r⏲️  ${G}Waiting for Kibana to be ready...✅\n"
        fi
    fi
    # check if kibana data/log paths exist
    if [[ "$type" == "kibanapath" ]]; then
        if [[ "$2" == "clean" ]]; then
            if [[ -d "${DATA[base]}/kibana/data" ]]; then
                printf "🗑️ ${Y}Cleaning data dir of ${C}Kibana"
                sudo rm -rf ${DATA[base]}/kibana/data
                printf "\r🗑️ ${G}Cleaning data dir of ${C}Kibana${G}...✅\n"
            fi
            if [[ -d "${DATA[base]}/kibana/logs" ]]; then
                printf "📂 ${Y}Cleaning logs dir of ${C}Kibana"
                sudo rm -rf ${DATA[base]}/kibana/logs
                printf "\r📂 ${G}Cleaning logs dir of ${C}Kibana${G}...✅\n"
            fi
        fi
        
        if [[ ! -d "${DATA[base]}/kibana/data" ]]; then
            check "datapath"
            printf "📂 ${Y}Creating data and log dirs of ${C}Kibana"
            sudo mkdir -p ${DATA[base]}/kibana/{data,logs}
            sudo chown -R $USER:docker ${DATA[base]}/kibana/{data,logs}
            printf "\r📂 ${G}Creating data and log dirs of ${C}Kibana...✅\n"
        fi
    fi
    # check if package exists as input $2
    if [[ "$type" == "package" ]]; then
        local pkg="$2"
        local installer
        installer=$(detect_os)
        
        if command -v dpkg >/dev/null 2>&1; then dpkg -s "$pkg" &>/dev/null && return 0 || return 1
        elif command -v rpm >/dev/null 2>&1; then rpm -q "$pkg" &>/dev/null && return 0 || return 1
        elif command -v apk >/dev/null 2>&1; then apk info -e "$pkg" &>/dev/null && return 0 || return 1
        else return 1; fi
    fi
    # check if elasticsearch deployment plan exists
    if [[ "$type" == "plan" ]]; then
        if [[ ! -n "${MODE:-}" ]]; then
            printf "❌ Deployment plan not found...requesting\n\n" 
            get "elastic"
        fi
    fi
    # check if elasticsearch node paths exists for each tier (hot, warm and cold)
    if [[ "$type" == "storage" ]]; then
        local total_data_gb="$2"

        ## Tier keep days

        #if [[ -z "${KEEP_WARM}" || "${KEEP_WARM}" -eq 0 ]]; then keep_hot=$RETENTION_DAYS
        #else keep_hot=$KEEP_WARM; fi

        local keep_hot=${KEEP_HOT:-RETENTION_DAYS}
        #local keep_warm=$(( ${KEEP_COLD:-0} - ${KEEP_WARM:-0} ))
        local keep_warm=$(( RETENTION_DAYS - $keep_hot ))
        local keep_cold=$(( RETENTION_DAYS - $keep_warm ))
        
        #echo "$keep_hot $keep_warm"; sleep 10
        
        (( keep_hot < 0 )) && keep_hot=0
        (( keep_warm < 0 )) && keep_warm=0
        (( keep_cold < 0 )) && keep_cold=0
        
        # daily ingest in GB
        if [[ -z "$RETENTION_DAYS" ]]; then RETENTION_DAYS=1; fi
        local daily_ingest_gb=$(( total_data_gb / RETENTION_DAYS ))

        # per-tier needs
        local hot_need=$(( daily_ingest_gb * KEEP_HOT ))
        local warm_need=$(( daily_ingest_gb * KEEP_WARM ))
        local cold_need=$(( daily_ingest_gb * KEEP_COLD ))
        
        if [[ "$MODE" == "MULTI"  ]]; then
            printf "${G}| ${C}%-50s      ${G}|\n" "Estimated Storage Cur/Req values(GB) per each node"
            echo "${G}|---------------------------------------------------------|"
            # hot
            if (( HOT_COUNT > 0 && hot_need > 0 )); then
                local per_hot=$(echo "scale=1; $hot_need / $HOT_COUNT" | bc)
                for i in $(seq 1 $TOTAL_COUNT); do
                    [[ ${NODE_TYPE[$i]} == "hot" ]] || continue
                    local l=${NODE_LABEL[$i]}
                    local avail=${SUM_SPACE[$l]}
                    if [[ "$avail" != "N/A" ]]; then
                        if (( $(echo "$avail < $per_hot" | bc -l) )); then
                            printf "|⚠️  ${R}%-7s %-14s ${Y}%-31s${G}|\n" "$l" "(INSUFFICIENT)" "Cur:$avail < Req:$per_hot"
                        else
                            printf "|✅ ${G}%-7s %-14s ${N}%-31s${G}|\n" "$l" "(SUFFICIENT)" "Cur:$avail > Req:$per_hot"
                        fi
                    fi
                done
            fi

            # warm
            if (( WARM_COUNT > 0 && warm_need > 0 )); then
                local per_warm=$(echo "scale=1; $warm_need / $WARM_COUNT" | bc)
                for i in $(seq 1 $TOTAL_COUNT); do
                    [[ ${NODE_TYPE[$i]} == "warm" ]] || continue
                    local l=${NODE_LABEL[$i]}
                    local avail=${SUM_SPACE[$l]}
                    if [[ "$avail" != "N/A" ]]; then
                        if (( $(echo "$avail < $per_warm" | bc -l) )); then
                            printf "|⚠️  ${R}%-7s %-14s ${Y}%-31s${G}|\n" "$l" "(INSUFFICIENT)" "Cur:$avail < Req:$per_warm"
                        else
                            printf "|✅ ${G}%-7s %-14s ${N}%-31s${G}|\n" "$l" "(SUFFICIENT)" "Cur:$avail > Req:$per_warm"
                        fi
                    fi
                done
            fi

            # cold
            if (( COLD_COUNT > 0 && cold_need > 0 )); then
                local per_cold=$(echo "scale=1; $cold_need / $COLD_COUNT" | bc)
                for i in $(seq 1 $TOTAL_COUNT); do
                    [[ ${NODE_TYPE[$i]} == "cold" ]] || continue
                    local l=${NODE_LABEL[$i]}
                    local avail=${SUM_SPACE[$l]}
                    if [[ "$avail" != "N/A" ]]; then
                        if (( $(echo "$avail < $per_cold" | bc -l) )); then
                            printf "|⚠️  ${R}%-7s %-14s ${Y}%-31s${G}|\n" "$l" "(INSUFFICIENT)" "Cur:$avail < Req:$per_cold"
                        else
                            printf "|✅ ${G}%-7s %-14s ${N}%-31s${G}|\n" "$l" "(SUFFICIENT)" "Cur:$avail > Req:$per_cold"
                        fi
                    fi
                done
            fi
            echo "+---------------------------------------------------------+"
        fi
    fi
    # check if sudo exists
    if [[ "$type" == "sudo" ]]; then
        if ! command -v sudo >/dev/null 2>&1; then install "sudo"; s 1; fi
    fi
    # check if system params, mandatory packages, docker and self signed cert exist
    if [[ "$type" == "system" ]]; then
        if [[ ! -f "/etc/sysctl.d/99-stack-sysctl.conf"  ]]; then set "sysparams"; s 1; fi
        if ! check "package" "openssl"; then install "package"; s 1; fi
        if ! q command -v docker; then install "docker"; fi
        check "cert"
    fi
    # check if vectra content exists else download and import index templates and saved objects
    if [[ "$type" == "vectra" ]]; then
        if [ ! -n "$(ls -A ${DATA[base]}/vectra 2>/dev/null)" ]; then vectra "get"; fi
        vectra "elastic"; s 1
        vectra "initialize"; s 1
        vectra "kibana"; s 1
    fi
}

# compare user created vs auto created deploymnent plans
compare() {
    echo
    echo "${Y}SIDE-BY-SIDE COMPARISON: AUTO vs MANUAL${N}"
    
    # auto calculation
    local auto_master auto_hot auto_warm auto_cold

    {
        # masters
        if (( TOTAL_IPS < 25000 )); then
            auto_master=1
        else
            auto_master=3
        fi

        # defaults for ILM keep values
        local keep_hot=${KEEP_HOT:-1}
        local keep_warm
        local keep_cold
        
        if [[ -n "${KEEP_WARM:-}" ]]; then
            keep_warm=$KEEP_WARM
        else
            keep_warm=$(( RETENTION_DAYS - keep_hot - ${KEEP_COLD:-0} ))
        fi

        if [[ -n "${KEEP_COLD:-}" ]]; then
            keep_cold=$KEEP_COLD
        else
            keep_cold=$(( RETENTION_DAYS - keep_hot - keep_warm ))
        fi

        (( keep_hot < 0 )) && keep_hot=0
        (( keep_warm < 0 )) && keep_warm=0
        (( keep_cold < 0 )) && keep_cold=0
        
        # daily ingest in GB
        local daily_ingest_gb=$DAILY_INGEST

        # hOT nodes (ingest heavy, keep only keep_hot days)
        if (( daily_ingest_gb <= 250 )); then
            auto_hot=1
        else
            auto_hot=$(( (daily_ingest_gb + 249) / 250 ))  # ceil division: 1 hot per ~250 GB/day
        fi
        # ensure at least 1 hot node if hot tier retention exists
        (( keep_hot > 0 && auto_hot < 1 )) && auto_hot=1

        # warm nodes (longer retention, query but lower ingest)
        if (( keep_warm > 0 )); then
            if (( auto_hot <= 2 )); then
                auto_warm=1
            elif (( auto_hot >= 3 && auto_hot <= 4 )); then
                auto_warm=2
            else
                auto_warm=$(( (auto_hot + 1) / 2 ))  # roughly half of hot
            fi
        else
            auto_warm=0
        fi

        # cold nodes (archival, mostly search only, cheap storage)
        if (( keep_cold > 0 )); then
            if (( RETENTION_DAYS > 180 )); then
                auto_cold=2
            else
                auto_cold=1
            fi
        else
            auto_cold=0
        fi
    }


    ## manual from globals (default to 0 if unset)
    local man_master=${MASTER_COUNT:-0}
    local man_hot=${HOT_COUNT:-0}
    local man_warm=${WARM_COUNT:-0}
    local man_cold=${COLD_COUNT:-0}

    # print table with summary
    printf "\n${G}+------------------+-------+-------+\n"
    printf "| ${C}%-16s ${G}| ${C}AUTO  ${G}| ${C}MANUAL${G}|\n" "Type"
    printf "|----------------------------------|\n"
    printf "| ${G}%-16s ${G}| ${N}%-5s ${G}| ${N}%-5s ${G}|\n" "Master node(s)" "$auto_master" "$man_master"
    printf "| ${G}%-16s ${G}| ${N}%-5s ${G}| ${N}%-5s ${G}|\n" "Hot node(s)"    "$auto_hot"    "$man_hot"
    printf "| ${G}%-16s ${G}| ${N}%-5s ${G}| ${N}%-5s ${G}|\n" "Warm node(s)"   "$auto_warm"   "$man_warm"
    printf "| ${G}%-16s ${G}| ${N}%-5s ${G}| ${N}%-5s ${G}|\n" "Cold node(s)"   "$auto_cold"   "$man_cold"
    printf "+------------------+-------+-------+\n"

    echo
    printf "📊 Daily ingest: ${Y}${DAILY_INGEST} GB${N}, Retention: ${Y}${RETENTION_DAYS} days${N}, Hosts: ${Y}${TOTAL_IPS}${N}\n"
    echo

    # ask user which to apply
    read -rp "👉 Apply which plan? (auto/manual/skip): " choice
    case "$choice" in
        auto|AUTO)
            echo "✅ Applying AUTO plan..."
            MASTER_COUNT=$auto_master; setvar "MASTER_COUNT" "auto_master"
            HOT_COUNT=$auto_hot;       setvar "HOT_COUNT" "auto_hot"
            WARM_COUNT=$auto_warm;     setvar "WARM_COUNT" "auto_warm"
            COLD_COUNT=$auto_cold;     setvar "COLD_COUNT" "auto_cold"
            TOTAL_COUNT=$((MASTER_COUNT + HOT_COUNT + WARM_COUNT + COLD_COUNT))
            setvar "TOTAL_COUNT" "TOTAL_COUNT"
            setvar "TOTAL_IPS" "TOTAL_IPS"
            setvar "RETENTION_DAYS" "RETENTION_DAYS"
            ;;
        manual|MANUAL)
            echo "✅ Keeping MANUAL plan (no changes)."
            ;;
        skip|SKIP|"")
            echo "⚠️ Skipped applying changes."
            ;;
        *)
            echo "❌ Invalid choice, skipping."
            ;;
    esac
}

# generic confirm / return 0 or 1
confirm() {
    local message="${1:-Are you sure you want to continue?}"
    local ans ok

    read -rp "⚠️  $message (y/N): " ans
    if [[ "$ans" =~ ^[Yy]$ ]]; then ok=0; else ok=1; fi; s 1; return $ok
}

# container functions
container() {
    # check base installation
    check "docker" || return 1

    local action="$1"
    local name="$2"
    # if container exists
    if [[ "$action" == "ifexists" ]]; then
        if sudo docker ps -a --format '{{.Names}}' | grep -q "^${name}$"; then
            printf "📦  ${G}Container: ${C}$name ${G}exists (running or stopped)\n"
            return 0
        else
            printf "❌  ${G}Container: ${C}$name ${G}does not exist...proceeding\n"
            return 1
        fi
    fi
    # if contaienr is running
    if [[ "$action" == "ifrunning" ]]; then
        if sudo docker ps --format '{{.Names}}' | grep -q "^${name}$"; then
            printf "▶️  ${G}Container: ${C}$name ${G}is running\n"
            return 0
        fi
    fi
    # remove container
    if [[ "$action" == "remove" ]]; then
        if sudo docker ps -a --format '{{.Names}}' | grep -q "^$name\$"; then
            printf "⚙️  ${Y}Removing container: ${C}$name"
            q sudo docker stop $name
            q sudo docker rm -v $name
            printf "\r🗑️  ${G}Removing container: ${C}$name${G}...done\n"
        fi
    fi
    # restart container
    if [[ "$action" == "restart" ]]; then
        if sudo docker ps -a --format '{{.Names}}' | grep -q "^$name\$"; then
            printf "⚙️   ${Y}Restarting container: ${C}$name"
            q sudo docker restart $name
            printf "\r🔄  ${G}Restarting container: ${C}$name${G}...done\n"
        else
            printf "⚠️  ${Y}Container ${C}$name ${Y}not found...proceeding\n"
        fi
    fi
    # start container
    if [[ "$action" == "start" ]]; then
        if sudo docker ps -a --format '{{.Names}}' | grep -q "^$name\$"; then
            printf "⚙️  ${Y}Starting container: ${C}$name"
            q sudo docker start $name
            printf "\r▶️  ${G}Starting container: ${C}$name${G}...done\n"
        else
            printf "⚠️  ${Y}Container ${C}$name ${Y}not found...proceeding\n"
        fi
    fi
    # stop container
    if [[ "$action" == "stop" ]]; then
        if sudo docker ps -a --format '{{.Names}}' | grep -q "^$name\$"; then
            printf "⚙️  ${Y}Stopping container: ${C}$name"
            q sudo docker stop $name
            printf "\r🛑 ${G}Stopping container: ${C}$name${G}...done\n"
        fi
    fi
}

# general deploy function for containers
deploy() {
    # check base installation
    check "docker" || return 1

    # deploy dozzle (docker log helper app)
    if [[ "$1" == "dozzle" ]]; then
        # Remove old one
        container "remove" "dozzle"

        # install dozzle
        printf "📦 ${Y}Deploying docker logger: ${C}dozzle"
        q sudo docker run -d \
            --name dozzle \
            --restart=always \
            --network esnet \
            --memory=$DOZZLE_MEM \
            --memory-swap=$DOZZLE_MEM \
            --memory-swappiness=0 \
            --oom-kill-disable \
            -e DOZZLE_BASE=/dozzle \
            -v /var/run/docker.sock:/var/run/docker.sock \
        amir20/dozzle:latest
        printf "\r✅ ${G}Deploying docker logger: ${C}dozzle${G}...done\n"
        container "ifrunning" "dozzle"
    fi

    # elasticsearch full stack deployment
    if [[ "$1" == "elastic" ]]; then
        # backup old config before proceeding
        generate "backup"

        # create config files from deployment plan
        check "esconfig"
        
        local cfgdir="${DATA[base]}/config"
        declare -A max_count
        max_count=( ["master"]=$MASTER_COUNT ["hot"]=$HOT_COUNT ["warm"]=$WARM_COUNT ["cold"]=$COLD_COUNT )

        # stopping Fluent-bit to avoid creating false indexes
        container "stop" "fluent-bit"

        # cleanup: remove containers not in current config
        echo "🛠️  Checking for excess containers..."
        desired=("${NODE_LABEL[@]}")

        # get all ES containers by image name
        for c in $(sudo docker ps -a --filter "ancestor=docker.elastic.co/elasticsearch/elasticsearch:$ES_VERSION" --format '{{.Names}} '); do
            if [[ ! " ${desired[*]} " =~ " $c " ]]; then
                container "remove" "$c"
            fi
        done
        s 1
        # default config check, if not break the flow
        if ! q ls "$cfgdir"/master1.yml; then
            printf "❌ No config files found in $cfgdir\n"
            printf "⚠️  Run option #1 to create configs first\n\n"
            return 1
        fi

        # deploy desired nodes
        for i in $(seq 1 "$TOTAL_COUNT"); do
            local name="${NODE_LABEL[$i]}"
            local type="${NODE_TYPE[$i]}"
            if [[ $type == "master" ]]; then
                local datadir="${DATA[master]}/$name/data"
                local logdir="${DATA[master]}/$name/logs"
            elif [[ $type == "hot" ]]; then
                local datadir="${DATA[hot]}/$name/data"
                local logdir="${DATA[hot]}/$name/logs"
            elif [[  $type == "warm" ]]; then
                local datadir="${DATA[warm]}/$name/data"
                local logdir="${DATA[warm]}/$name/logs"
            elif [[  $type == "cold" ]]; then
                local datadir="${DATA[cold]}/$name/data"
                local logdir="${DATA[cold]}/$name/logs"
            fi
            local cfg="$cfgdir/$name.yml"
            local jvm="$cfgdir/$name.jvm"

            # remove old container and its data if exists
            container "remove" "$name"
            check "espath" "remove" "$datadir" "$logdir" "$name"

            # deploy es node container
            printf "📦  ${Y}Deploying Elasticsearch node: ${C}$name ${N}(type: ${C}$type${N})"
            q sudo docker run -d \
                --name $name \
                --net esnet \
                --restart=always \
                --memory=${CONT_MEM[$i]}g \
                --memory-swap=${CONT_MEM[$i]}g \
                --memory-swappiness=0 \
                --oom-kill-disable \
                -v "$cfg":/usr/share/elasticsearch/config/elasticsearch.yml:ro \
                -v "$jvm":/usr/share/elasticsearch/config/jvm.options.d/$name.options:ro \
                -v "$datadir":/usr/share/elasticsearch/data \
                -v "$logdir":/usr/share/elasticsearch/logs \
                -e ELASTIC_PASSWORD=$ES_BOOTSTRAP_PASSWORD \
                "docker.elastic.co/elasticsearch/elasticsearch:$ES_VERSION"
            printf "\r📦  ${G}Deploying Elasticsearch node: ${C}$name ${N}(type: ${C}$type${N})...✅\n"
            container "ifrunning" "$name"
            ((CONT_MEM++))
            s 1
        done

        # remove old kibana if exists
        container "ifexists" "kibana" && container "remove" "kibana"
        # update kibana config
        generate "kibana"
        # re/deploy kibana
        deploy "kibana"; s 1
        # update haproxy config and reload
        generate "haproxy"; container "restart" "haproxy"; s 1
    fi

    if [[ "$1" == "fluent-bit" ]]; then
         # check if config dir exists
        check "configpath"

        # Check if fluent-bit storage folder exists
        check "fbpath"

        # remove old fluent-bit container if exists
        container "remove" "fluent-bit"

        # check fluent-bit conf file if exists
        if [[ ! -f "${DATA[base]}/config/fluent-bit.cfg" ]]; then generate "fluent-bit"; fi
        # deploy fluent-bit
        printf "📦 ${Y}Deploying Fluent-Bit"
        q sudo docker run -d \
            --name fluent-bit \
            --net esnet \
            --restart always \
            --memory=$FB_MEM \
            --memory-swap=$FB_MEM \
            --memory-swappiness=0 \
            --oom-kill-disable \
            -p ${STREAM_INPUT_PORT}:9999 \
            -v ${DATA[base]}/config/fluent-bit.cfg:/fluent-bit/etc/fluent-bit.conf \
            -v ${DATA[base]}/fluent-bit/storage:/storage \
            cr.fluentbit.io/fluent/fluent-bit:latest-debug
        printf "\r📦 ${G}Deploying Fluent-Bit...✅\n"
        container "ifrunning" "fluent-bit"
    fi

    if [[ "$1" == "haproxy" ]]; then
        # check if config dir exists
        check "configpath"; s 1

        # Remove old container if running
        container "ifexists" "haproxy" && container "remove" "haproxy"

        # check if conf file exists
        if [[ ! -f "${DATA[base]}/config/haproxy.cfg" ]]; then generate "haproxy"; fi; s 1

        # check certificate
        check "cert"; s 1
        printf "📦 ${Y}Deploying LB + reverse proxy: ${C}haproxy"
        # deploy haproxy
        q sudo docker run -d \
            --name haproxy \
            --restart=always \
            --network esnet \
            --memory=$HA_MEM \
            --memory-swap=$HA_MEM \
            --memory-swappiness=0 \
            --oom-kill-disable \
            --sysctl net.ipv4.ip_unprivileged_port_start=0 \
            -p 443:443 \
            -p 1443:1443 \
            -v ${DATA[base]}/config/haproxy.cfg:/usr/local/etc/haproxy/haproxy.cfg:ro \
            -v ${DATA[base]}/certs/stack.pem:/usr/local/etc/haproxy/certs/stack.pem:ro \
        haproxy:latest
        printf "\r📦 ${G}Deploying LB+Reverse Proxy: ${C}haproxy${G}...✅\n"
        container "ifrunning" "haproxy"
    fi

    if [[ "$1" == "kibana" ]]; then
        local cfgfile="${DATA[base]}/config/kibana.yml"
        local datadir="${DATA[base]}/kibana/data"
        local logdir="${DATA[base]}/kibana/logs"

        # check if config dir exists
        check "configpath"

        # check if config dir exists
        check "datapath"

        # check if conf file exists
        if [[ ! -f "$cfgfile" ]]; then generate "kibana"; fi

        # remove old container if exists
        container "remove" "kibana"

        # dir clean/check
        check "kibanapath"

        # wait for master1 to be up and healthy
        check "elastic"
        # deploy kibana
        printf "📦  ${Y}Deploying Kibana"
        q sudo docker run -d \
            --name kibana \
            --net esnet \
            --restart=always \
            --memory=$KIBANA_MEM \
            --memory-swap=$KIBANA_MEM \
            --memory-swappiness=0 \
            --oom-kill-disable \
            -v "$cfgfile":/usr/share/kibana/config/kibana.yml:ro \
            -v "$datadir":/usr/share/kibana/data \
            -v "$logdir":/usr/share/kibana/logs \
            "docker.elastic.co/kibana/kibana:$ES_VERSION"
        printf "\r📦  ${G}Deploying Kibana...✅\n"
        container "ifrunning" "kibana"
    fi

    if [[ "$1" == "portainer" ]]; then
        # remove old one
        container "remove" "portainer"

        # set portainer default admin user password **** not working / must be inspected *****
        #local portainer_pass=$(htpasswd -nb -B admin "${ES_BOOTSTRAP_PASSWORD}" | cut -d ":" -f 2)
        printf "📦 ${Y}Deploying docker manager: ${C}portainer"
        # deploy portainer (docker manager)
        q sudo docker run -d \
            --name portainer \
            --restart=always \
            --network esnet \
            --memory=$PORT_MEM \
            --memory-swap=$PORT_MEM \
            --memory-swappiness=0 \
            --oom-kill-disable \
            -e http-enabled \
            -v /var/run/docker.sock:/var/run/docker.sock \
        portainer/portainer-ce:latest
        printf "\r📦 ${G}Deploying docker manager: ${C}portainer${G}...✅\n"
        container "ifrunning" "portainer"
    fi
}

generate() {
    # check base installation
    check "docker" || return 1
    # config backup
    if [[ "$1" == "backup" ]]; then
        local configdir="${DATA[base]}/config"
        local backupdir="${DATA[base]}/backup"
        local timestamp
        timestamp=$(date +"%d%m%Y-%H%M")

        # copy yml files if exist
        if q ls "$configdir"/*.yml; then
            sudo mkdir -p "$backupdir/$timestamp"
            sudo chown -R $USER:docker "$backupdir/$timestamp"
            sudo mv "$configdir"/*.{yml,jvm} "$backupdir/$timestamp/"
            printf "💾 ${G}Previous config file(s) saved into ${Y}$backupdir/backup-$timestamp"
        else
            printf "ℹ️  ${G}No existing config files to back up"
        fi

        # get all backup folders sorted by newest first
        backups=( "$backupdir"/* )
        backups=( $(qe ls -dt "$backupdir"/*) )

        # count number of backups
        backup_count=${#backups[@]}

        # delete older backups if more then defined CONFIG_BACKUP_LIMIT
        if (( backup_count > $CONFIG_BACKUP_LIMIT )); then
            old_backups=( "${backups[@]:$CONFIG_BACKUP_LIMIT}" )
            for b in "${old_backups[@]}"; do
                sudo rm -rf "$b"
            done
            printf "🧹 ${G}Deleted ${Y}${#old_backups[@]} ${G}old backup(s)"
        fi
        s 2
    fi

    if [[ "$1" == "cert" ]]; then
        local CERT_DIR="${DATA[base]}/certs"
        local STACK_CERT_DEFAULT="$CERT_DIR/stack.pem"

        # check cert dir
        if [ ! -e "$CERT_DIR" ]; then
            sudo mkdir -p "$CERT_DIR"
            sudo chown -R "$USER:docker" "$CERT_DIR"
        fi

        # create self signed cert+key
        if [ ! -f "$STACK_CERT_DEFAULT" ]; then
            printf "🔐 ${Y}Generating self-signed certificate for Stack..."
            qe openssl req -x509 -nodes -days 3650 \
                -newkey rsa:2048 \
                -subj "/CN=${HOST_FQDN}" \
                -addext "subjectAltName=DNS.1:${HOST_FQDN},DNS.2:$HOST_NAME,IP:${HOST_IP}" \
                -outform PEM \
                -keyout /dev/stdout \
                -out /dev/stdout >"${STACK_CERT_DEFAULT}"
            printf "\r🔐 ${G}Generating self-signed certificate for Stack...✅\n"
            printf "👉 ${G}Certificate file generated as ${C}$STACK_CERT_DEFAULT\n"
        fi
        # set cert file permission
        sudo chmod -R 664 $CERT_DIR/*
    fi
    # create CSR for external signing
    if [[ "$1" == "csr" ]]; then
        local CERT_DIR="${DATA[base]}/certs"
        local CSR_KEY="$CERT_DIR/csr.key"
        local CSR_REQ="/tmp/csr.req"

        printf "🔐 ${Y}Generating CSR file for Stack"

        # create temporary CSR config with sans
        TMP_CONF=$(mktemp)
        cat > "$TMP_CONF" <<EOF
[ req ]
default_bits       = 2048
prompt             = no
default_md         = sha256
distinguished_name = dn
req_extensions     = req_ext

[ dn ]
CN = $HOST_FQDN

[ req_ext ]
subjectAltName = @alt_names

[ alt_names ]
DNS.1 = $HOST_FQDN
DNS.2 = $HOST_NAME
IP.1  = $HOST_IP
EOF
        printf "\r🔐 ${G}Generating CSR file for Stack...✅\n\n"
        # generate key
        openssl genrsa -out "$CSR_KEY" 2048
        # generate CSR using the temp config
        openssl req -new -key "$CSR_KEY" -out "$CSR_REQ" -config "$TMP_CONF"

        # clean up
        rm "$TMP_CONF"

        printf "💾 ${G}CSR REQ generated: ${N}$CSR_REQ\n"
        printf "💾 ${G}CSR KEY generated: ${N}$CSR_KEY\n"
    fi

    if [[ "$1" == "elastic" ]]; then
        check "configpath"
        local configdir="${4:-${DATA[base]}/config}"

        printf "⚙️  ${Y}Auto calculate and distribute resources"
        plan "manual"
        printf "\r⚙️  ${G}Auto calculate and distribute resources...✅\n"
        
        if [[ ( -z "$MASTER_COUNT" || "$MASTER_COUNT" -le 0 ) && $MODE == "MULTI" ]]; then
            echo "🚫 Error: Master count must be greater than 0"
            return 1
        fi

        # prepare master node names
        local masters=()
        for ((i=1;i<=MASTER_COUNT;i++)); do masters+=("master${i}"); jvms+=("jvm${i}"); done

        local index=1
        # generate master configs
        for master in "${masters[@]}"; do
            local file1="$configdir/$master.yml"
            local file2="$configdir/$master.jvm"
            {
                echo "node.name: $master"
                # discovery settings
                if [[ ($MASTER_COUNT -eq 1  && $MODE == "SINGLE") || 
                      ($MASTER_COUNT -eq 1  && $MODE == "MULTI" && $HOT_COUNT -eq 0) ]] ; then
                    echo "discovery.type: single-node"
                else
                    echo "node.roles: [master,data_content,remote_cluster_client]"
                    echo "discovery.type: multi-node"

                    local seeds=()
                    for m in "${masters[@]}"; do
                        if [[ $m != "$master" ]]; then
                            seeds+=("$m")
                        fi
                    done
                    echo "discovery.seed_hosts: [$(IFS=,; echo "${seeds[*]}")]"
                    echo "cluster.initial_master_nodes: ["master1"]"
                fi
                echo "cluster.name: $CLUSTER_NAME"
                echo "network.host: 0.0.0.0"
                echo "xpack.security.enabled: false"
                echo "xpack.security.http.ssl.enabled: false"
                echo "xpack.monitoring.collection.enabled: true"
            } > "$file1"
            # set JVM heap size for master nodes
            {
                echo "-Xms${JVM_MEM[$index]}g"
                echo "-Xmx${JVM_MEM[$index]}g"
            } > "$file2"
            ((index++))
            printf "📝  ${G}Config file generated for: ${C}$master\n"
        done

        # generate hot node configs
        for ((i=1;i<=HOT_COUNT;i++)); do
            local node="hot${i}"
            local file1="$configdir/$node.yml"
            local file2="$configdir/$node.jvm"
            {
                echo "node.name: $node"
                echo "node.roles: [data_hot,ingest]"
                echo "discovery.type: multi-node"
                echo "discovery.seed_hosts: [$(IFS=,; echo "${masters[*]}")]"
                echo "cluster.name: $CLUSTER_NAME"
                echo "network.host: 0.0.0.0"
                echo "xpack.security.enabled: false"
                echo "xpack.security.http.ssl.enabled: false"
                echo "xpack.monitoring.collection.enabled: true"
            } > "$file1"
            # set JVM heap size for hot nodes
            {
                echo "-Xms${JVM_MEM[$index]}g"
                echo "-Xmx${JVM_MEM[$index]}g"
            } > "$file2"
            ((index++))
            printf "📝 ${G}Config file generated for: ${C}$node\n"
        done

        # generate warm node configs
        for ((i=1;i<=WARM_COUNT;i++)); do
            local node="warm${i}"
            local file1="$configdir/$node.yml"
            local file2="$configdir/$node.jvm"
            {
                echo "node.name: $node"
                echo "node.roles: [data_warm]"
                echo "discovery.type: multi-node"
                echo "discovery.seed_hosts: [$(IFS=,; echo "${masters[*]}")]"
                echo "cluster.name: $CLUSTER_NAME"
                echo "network.host: 0.0.0.0"
                echo "xpack.security.enabled: false"
                echo "xpack.security.http.ssl.enabled: false"
                echo "xpack.monitoring.collection.enabled: true"
            } > "$file1"
            # set JVM heap size for warm nodes
            {
                echo "-Xms${JVM_MEM[$index]}g"
                echo "-Xmx${JVM_MEM[$index]}g"
            } > "$file2"
            ((index++))
            printf "📝 ${G}Config file generated for: ${C}$node\n"
        done

        # generate cold node configs
        for ((i=1;i<=COLD_COUNT;i++)); do
            local node="cold${i}"
            local file1="$configdir/$node.yml"
            local file2="$configdir/$node.jvm"
            {
                echo "node.name: $node"
                echo "node.roles: [data_cold]"
                echo "discovery.type: multi-node"
                echo "discovery.seed_hosts: [$(IFS=,; echo "${masters[*]}")]"
                echo "cluster.name: $CLUSTER_NAME"
                echo "network.host: 0.0.0.0"
                echo "xpack.security.enabled: false"
                echo "xpack.security.http.ssl.enabled: false"
                echo "xpack.monitoring.collection.enabled: true"
            } > "$file1"
            # set JVM heap size for cold nodes
            {
                echo "-Xms${JVM_MEM[$index]}g"
                echo "-Xmx${JVM_MEM[$index]}g"
            } > "$file2"
            ((index++))
            printf "📝 ${G}Config file generated for: ${C}$node\n"
        done
        s 1
    fi

    if [[ "$1" == "fluent-bit" ]]; then
        check "configpath"

        printf "📝  ${Y}Fluent-Bit conf file generation..."
        # fluent-bit config variables
        local cfgfile="${DATA[base]}/config/fluent-bit.cfg"
        local buffersize="10M"
        local tls="off"
        local compress="none"
        local keepalive="on"
        local retrylimit="3"
        local storagelimit="$FB_STORAGE"

        # per-metadata workers
        declare -A workers=(
          [beacon]=1
          [dcerpc]=1
          [dhcp]=1
          [dns]=4
          [httpsessioninfo]=1
          [isession]=6
          [kerberos_txn]=1
          [ldap]=1
          [match]=1
          [ntlm]=1
          [radius]=1
          [rdp]=1
          [smbfiles]=1
          [smbmapping]=1
          [smtp]=1
          [ssh]=1
          [ssl]=2
          [x509]=2
        )

        # put fluent-bit config into file
        {
            cat <<EOF
[SERVICE]
    flush                       1
    daemon                      off
    log_level                   warn
    parsers_file                /fluent-bit/etc/parsers.conf
    plugins_file                /fluent-bit/etc/plugins.conf
    http_server                 on
    http_listen                 0.0.0.0
    http_port                   2020
    health_check                on
    hc_errors_count             5
    hc_retry_failure_count      5
    hc_period                   5
    hot_reload                  on
    grace                       5
    scheduler.base              3
    scheduler.cap               15
    storage.backlog.mem_limit   8G
    storage.total_limit_size    32G
    storage.delete_irrecoverable_chunks on
    storage.checksum            off
    storage.max_chunks_up       512
    storage.metrics             on
    storage.path                /storage
    storage.sync                normal
    storage.type                filesystem

[INPUT]
    name            tcp
    listen          0.0.0.0
    port            9999
    chunk_size      9000
    format          json
    tag             stream
    alias           stream
    mem_buf_limit   1024MB
    storage.type    filesystem
    threaded        true

[FILTER]
    name            rewrite_tag
    match           stream
    emitter_name    metadata.writer
    rule            \$metadata_type  ^(.*)$  \$1   false
    emitter_storage.type    filesystem
    emitter_mem_buf_limit   6G

@SET buffersize=20M
@SET dns=async
@SET keepalive=on
@SET retrylimit=3
@SET storagelimit=1G
@SET trace=off

EOF
            local type
            for type in beacon dcerpc dhcp dns httpsessioninfo isession kerberos_txn \
                    ldap match ntlm radius rdp smbfiles smbmapping smtp ssh ssl x509
            do
                cat <<EOF
# metadata_${type}
[OUTPUT]
    name                es
    match               metadata_${type}
    host                haproxy
    port                9200
    buffer_size         \${buffersize}
    index               metadata_${type}
    suppress_type_name  on
    write_operation     index
    storage.total_limit_size    \${storagelimit}
    trace_error         \${trace}
    net.dns.resolver    \${dns}
    net.keepalive       \${keepalive}
    retry_limit         \${retrylimit}
    workers             ${workers[$type]}
    alias               es.${type}

EOF
            done
        } >"$cfgfile"
        printf "\r📝  ${G}Fluent-Bit conf file generation...✅\n"
        printf "👉  ${G}Conf file has been saved as => ${C}${DATA[base]}/config/fluent-bit.cfg\n"
    fi

    # haproxy Conf
    if [[ "$1" == "haproxy" ]]; then
        check "configpath"

        printf "📝  ${Y}HAproxy conf file generation"
        local cfgfile="${DATA[base]}/config/haproxy.cfg"
        local HOT_COUNT="${HOT_COUNT}"

        shift
        {
            cat <<'EOF'
global
    log stdout format raw local0 info
    maxconn 4096
    tune.ssl.default-dh-param 2048

defaults
    log     global
    mode    http
    timeout connect 5s
    timeout client  50s
    timeout server  50s
    option  redispatch
    option  httplog
    retries 3

resolvers docker_dns
  nameserver dns1 127.0.0.11:53
  resolve_retries 3
  timeout retry 1s
  hold valid 10s

userlist haproxy_users
    user admin password $5$maUlKp7iRcIzxru.$X3oqDPtjRCBoO3YIk9Wnq/zjKHpZqniyA4uImJJy7M7

frontend Kibana
    bind *:443 ssl crt /usr/local/etc/haproxy/certs/stack.pem
    mode http
    option forwardfor
    option http-keep-alive
    
    acl auth_ok http_auth(haproxy_users)
    http-request auth realm authRealm if !auth_ok

    use_backend Dozzle_be    if { path_beg /dozzle }
    use_backend Stats     if { path_beg /stats }
    default_backend Kibana_be

backend Kibana_be
    mode http
    option httpchk GET /api/status
    http-check expect status 200
    option forwardfor
    server kibana kibana:5601 check resolvers docker_dns resolve-prefer ipv4

frontend Portainer
    bind *:1443 ssl crt /usr/local/etc/haproxy/certs/stack.pem
    option forwardfor
    default_backend Portainer_be

backend Portainer_be
    mode http
    option forwardfor
    option http-keep-alive

    http-request set-header X-Forwarded-Proto https
    http-request set-header X-Forwarded-Port 1443
    http-request set-header Host %[req.hdr(Host)]

    server portainer portainer:9000 check resolvers docker_dns resolve-prefer ipv4

backend Dozzle_be
    option http-keep-alive
    server dozzle dozzle:8080 check resolvers docker_dns resolve-prefer ipv4

backend Stats
    mode http
    option http-keep-alive
    stats enable
    stats uri /stats
    stats refresh 10s

backend default
    mode http
    http-request deny

frontend Elastic_fe
    bind *:9200
    mode tcp
    option clitcpka
    option tcplog
    default_backend Elastic_be

backend Elastic_be
    mode tcp
    option srvtcpka
    option tcp-check
    balance roundrobin
    default-server inter 5s fall 3 rise 2 on-marked-down shutdown-sessions
EOF
            if [[ "$MODE" == "SINGLE" ]]; then
                echo "    server master1 master1:9200 check resolvers docker_dns resolve-prefer ipv4"
            else
                for ((i=1;i<=HOT_COUNT;i++)); do
                    echo "    server hot${i} hot${i}:9200 check resolvers docker_dns resolve-prefer ipv4"
                done
                printf "\n"
            fi
        } >"$cfgfile"
        printf "\r📝  ${G}HAproxy conf file generation...✅\n"
        printf "👉  ${G}Conf file has been saved as => ${C}$cfgfile\n"
    fi

    # haproxy Authentication
    if [[ "$1" == "ha_users" ]]; then
        local action="$2"
        local cfgfile="${DATA[base]}/config/haproxy.cfg"

        # ensure userlist section exists in haproxy.cfg
        if ! grep -q "userlist haproxy_users" "$cfgfile" 2>/dev/null; then
            echo "🧑‍💻 Creating HAProxy userlist in $cfgfile"
            cat <<EOF | sudo tee -a "$cfgfile" >/dev/null

# HAProxy user authentication
userlist haproxy_users
    user admin password $(mkpasswd -m sha-256 "$ES_BOOTSTRAP_PASSWORD")
EOF
        elif ! grep -q "user admin " "$cfgfile"; then
            echo "✅ Adding missing default admin user"
            sudo sed -i "/userlist haproxy_users/a\    user admin password $(mkpasswd -m sha-256 "$ES_BOOTSTRAP_PASSWORD")" "$cfgfile"
        fi

        if [[ "$action" == "create" ]]; then
            read -rp "👤 Enter new username: " newuser
            read -srp "🔑 Enter password for $newuser: " newpass
            echo
            local hash
            hash=$(mkpasswd -m sha-256 "$newpass")
            sudo sed -i "/userlist haproxy_users/a\    user $newuser password $hash" "$cfgfile"
            echo "✅ User '$newuser' added with hashed password."
        fi

        if [[ "$action" == "manage" ]]; then
            echo "👉 Select a user to manage:"
            mapfile -t users < <(grep -E "^\s*user " "$cfgfile" | awk '{print $2}')
            select selected_user in "${users[@]}" "Cancel"; do
                if [[ "$selected_user" == "Cancel" || -z "$selected_user" ]]; then
                    echo "❌ Cancelled."
                    return
                fi

                echo "⚙️  Managing user: $selected_user"
                echo "1) Delete"
                echo "2) Update password"
                echo "3) Cancel"
                read -rp "Choose an action [1-3]: " choice
                case "$choice" in
                    1)
                        if [[ "$selected_user" == "admin" ]]; then
                            echo "⚠️ Default admin user cannot be deleted."
                        else
                            sudo sed -i "/user $selected_user /d" "$cfgfile"
                            echo "🗑️  User '$selected_user' deleted."
                        fi
                        ;;
                    2)
                        read -srp "🔑 Enter new password for $selected_user: " newpass
                        echo
                        local hash
                        hash=$(mkpasswd -m sha-256 "$newpass")
                        sudo sed -i "s|user $selected_user .*|    user $selected_user password $hash|" "$cfgfile"
                        echo "✅ Password updated for '$selected_user'."
                        ;;
                    3)
                        echo "❌ Cancelled."
                        ;;
                    *)
                        echo "⚠️ Invalid choice."
                        ;;
                esac
                break
            done
        fi
    fi

    if [[ "$1" == "ilm" ]]; then
        printf "📝 ${Y}ILM conf file generation"
        local cfgdir="${DATA[base]}/vectra/elastic"
        #local templatefile="$cfgdir/component_templates/metadata.jsonc"
        local cfgfile="$cfgdir/ilm/vectra-metadata-policy.jsonc"
        local retention="${RETENTION_DAYS}d"
        local shardsize="${SHARD_SIZE}gb"
        local hottier="${DAY_HOT}d"
        local warmtier="${DAY_WARM}d"
        local coldtier="${DAY_COLD}d"
        
        # create custom ilm policy based on user retention input
        cat > "$cfgfile" <<EOF
{
  "policy": {
    "phases": {
      "hot": {
        "min_age": "0ms",
        "actions": {
          "set_priority": {
            "priority": 100
          },
          "rollover": {
            "max_age": "$hottier",
            "max_primary_shard_size": "$shardsize"
          }
        }
      },
      "warm": {
        "min_age": "$warmtier",
        "actions": {
          "set_priority": {
            "priority": 50
          }
        }
      },
      "cold": {
        "min_age": "$coldtier",
        "actions": {
          "set_priority": {
            "priority": 0
          }
        }
      },
      "delete": {
        "min_age": "$retention",
        "actions": {
          "delete": {
            "delete_searchable_snapshot": true
          }
        }
      }
    }
  }
}
EOF
        printf "\r📝  ${G}ILM conf file generation...✅ => ${C}$cfgfile\n"
    fi

    if [[ "$1" == "kibana" ]]; then
        printf "📝  ${Y}Kibana conf file generation"
        local cfgdir="${DATA[base]}/config"
        local cfgfile="$cfgdir/kibana.yml"
        # check if config dir exists
        if [ ! -e "$cfgdir" ]; then
            sudo mkdir -p "$cfgdir"
            sudo chown -R "$USER:docker" "$cfgdir"
        fi

        # build elasticsearch.hosts parameter from masters
        ES_HOSTS=""
        for i in $(seq 1 $MASTER_COUNT); do
            HOST="http://master${i}:9200"
            if [ -z "$ES_HOSTS" ]; then
                ES_HOSTS="\"$HOST\""
            else
                ES_HOSTS="$ES_HOSTS, \"$HOST\""
            fi
        done

        # create a minimal kibana.yml if missing
        cat > "$cfgfile" <<EOF
server.name: kibana
server.host: "0.0.0.0"
server.port: 5601
server.publicBaseUrl: "https://$HOST_IP"
elasticsearch.hosts: [ $ES_HOSTS ]
server.ssl.enabled: false
monitoring.ui.container.elasticsearch.enabled: true
xpack.encryptedSavedObjects.encryptionKey: "b8823f98f9d415edcf309b35b094e7d1"
xpack.reporting.encryptionKey: "fc75c6da7e1e7d7c7f44d1e3caa7c15f"
xpack.security.encryptionKey: "511dd8fe0b61738323a9c46809bb02a5"
telemetry.optIn: false
EOF
        printf "\r📝 ${G}Kibana conf file generation...✅ => ${C}$cfgfile\n"
    fi
}

get() {
    # getting elasticsearch deployment plan
    if [[ "$1" == "elastic" ]]; then
        # check if paths exist
        check "datapath"

        NODE_TYPE=()
        NODE_LABEL=()
        local nodeselect_arg="$2"
        # check single mode deployment
        if [[ "$nodeselect_arg" != "s" && "$nodeselect_arg" != "m" ]]; then
            printf "🔧 ${G}Please enter ES mode type: ${Y}"
            while true; do
                read -rp "Single(s) / Multi(m): " nodeselect
                nodeselect=${nodeselect:-"m"}
                case "$nodeselect" in
                    [sS]) nodeselect="s"; break ;;
                    [mM]) nodeselect="m"; break ;;
                    *) echo "❌ Invalid input. Please enter 's' or 'm'." ;;
                esac
            done
        else
            nodeselect="s"
        fi

        if [[ ${nodeselect} == "s" ]]; then 
            printf "✅ ${G}SINGLE MODE selected.\n"
            printf "    👉 ${N}Only one instance will be created with a name of ${Y}'master1'\n"
            MODE="SINGLE"
            MASTER_COUNT=1; HOT_COUNT=0; WARM_COUNT=0; COLD_COUNT=0
            NODE_TYPE[1]="master"
            NODE_LABEL[1]="master1"
            setvar "NODE_TYPE[1]" "master"
            setvar "NODE_LABEL[1]" "master1"
        else
            printf "✅ ${G}MULTI MODE selected. ${Y}Enter node counts for each type${N}\n"
            MODE="MULTI"

            while true; do
                read -p "    ❯ How many MASTER nodes do you want (default 1): " MASTER_COUNT
                MASTER_COUNT=${MASTER_COUNT:-1}

                # check if number is even
                if (( MASTER_COUNT % 2 == 0 )); then
                    printf "      🚫 Number is even, please enter an ${Y}odd${N} number!\n"
                    continue
                fi
                break
            done
             # multi mode selected / define node count per tier 
            read -r -p "    ❯ How many HOT nodes do you want (default 1): " HOT_COUNT
            HOT_COUNT=${HOT_COUNT:-1}

            read -r -p "    ❯ How many WARM nodes do you want (default 0): " WARM_COUNT
            WARM_COUNT=${WARM_COUNT:-0}

            read -r -p "    ❯ How many COLD nodes do you want (default 0): " COLD_COUNT
            COLD_COUNT=${COLD_COUNT:-0}

            # set node names in global arrays and persistent .vars file
            for ((i=1; i<=MASTER_COUNT; i++)); do
                NODE_TYPE[$((i))]="master"
                NODE_LABEL[$((i))]="master${i}"
                setvar "NODE_TYPE[$((i))]" "master"
                setvar "NODE_LABEL[$((i))]" "master${i}"
            done

            for ((i=1; i<=HOT_COUNT; i++)); do
                NODE_TYPE[$((MASTER_COUNT + i))]="hot"
                NODE_LABEL[$((MASTER_COUNT + i))]="hot${i}"
                setvar "NODE_TYPE[$((MASTER_COUNT + i))]" "hot"
                setvar "NODE_LABEL[$((MASTER_COUNT + i))]" "hot${i}"
            done

            for ((i=1; i<=WARM_COUNT; i++)); do
                NODE_TYPE[$((MASTER_COUNT + HOT_COUNT + i))]="warm"
                NODE_LABEL[$((MASTER_COUNT + HOT_COUNT + i))]="warm${i}"
                setvar "NODE_TYPE[$((MASTER_COUNT + HOT_COUNT + i))]" "warm"
                setvar "NODE_LABEL[$((MASTER_COUNT + HOT_COUNT + i))]" "warm${i}"
            done

            for ((i=1; i<=COLD_COUNT; i++)); do
                NODE_TYPE[$((MASTER_COUNT + HOT_COUNT + WARM_COUNT + i))]="cold"
                NODE_LABEL[$((MASTER_COUNT + HOT_COUNT + WARM_COUNT + i))]="cold${i}"
                setvar "NODE_TYPE[$((MASTER_COUNT + HOT_COUNT + WARM_COUNT + i))]" "cold"
                setvar "NODE_LABEL[$((MASTER_COUNT + HOT_COUNT + WARM_COUNT + i))]" "cold${i}"
            done
        fi
        # total nodes including master
        TOTAL_COUNT=$((MASTER_COUNT + HOT_COUNT + WARM_COUNT + COLD_COUNT))
        setvar "MODE" "MODE"
        setvar "MASTER_COUNT" "MASTER_COUNT"
        setvar "HOT_COUNT" "HOT_COUNT"
        setvar "WARM_COUNT" "WARM_COUNT"
        setvar "COLD_COUNT" "COLD_COUNT"
        setvar "TOTAL_COUNT" "TOTAL_COUNT"
        s 1
        get "ingest"
    fi

    # get ingest prediction for rough calculation
    if [[ "$1" == "ingest" ]]; then
        echo "${Y}📊 Provide data ingestion parameters:${N}"

        # number of hosts to be expected
        read -rp "👉 Number of monitored IPs [default: ${TOTAL_IPS:-1000}]: " input
        TOTAL_IPS="${input:-${TOTAL_IPS:-1000}}"

        # retention days
        read -rp "👉 Retention days [default: ${RETENTION_DAYS:-7}]: " input
        RETENTION_DAYS="${input:-${RETENTION_DAYS:-7}}"

        # hot tier days
        local input
        if [[ $HOT_COUNT -gt 0 ]] && [[ $WARM_COUNT -gt 0 || $COLD_COUNT -gt 0 ]]; then
            while true; do
                read -rp "👉 Day(s) to keep in hot tier 🔥 [default: 1]: " input
                input="${input:-1}"
                if (( input > RETENTION_DAYS )); then printf "  ❌ Cannot exceed ${Y}$RETENTION_DAYS ${N}days.\n"; continue; fi
                DAY_HOT=$input
                KEEP_HOT=$input
                break
            done
        else DAY_HOT=$RETENTION_DAYS; KEEP_HOT=$RETENTION_DAYS
        fi

        # warm tier days
        if [[ $WARM_COUNT -gt 0 ]]; then
            while true; do
                read -rp "👉 Move data into warm tier after 🌡️ [default: $((DAY_HOT + 1))]: " input
                input="${input:-$((DAY_HOT + 1))}"
                if [[ $input -lt $DAY_HOT || $input -eq $DAY_HOT ]]; then printf "  ❌ Cannot be equal or less than ${Y}$DAY_HOT ${N}day(s).\n"; continue; fi
                DAY_WARM=$input
                break
            done
        else DAY_WARM=0; KEEP_WARM=0
        fi
        
        # cold tier days
        if [[ $COLD_COUNT -gt 0 ]]; then
            local COLD_DEFAULT=$(( WARM_MOVE + 1 ))
            while true; do
                read -rp "👉 Move data into cold tier after ❄️ [default: ${COLD_DEFAULT}]: " input
                input="${input:-$COLD_DEFAULT}"
                if [[ $input -lt $(( WARM_MOVE + 1 )) ]]; then printf "  ❌ Cannot be less than ${Y}$(( WARM_MOVE + 1 )) ${N}day(s).\n"; continue; fi
                DAY_COLD=$input
                break
            done
            KEEP_WARM=$((DAY_COLD - DAY_WARM))
            KEEP_COLD=$((RETENTION_DAYS - DAY_COLD))
        else DAY_COLD=0; KEEP_COLD=0; KEEP_WARM=$((RETENTION_DAYS - DAY_HOT))
        fi

        # set warm as final if cold tier exists
        

        # calculating rough daily ingest value 
        DAILY_INGEST=$(( TOTAL_IPS * MB_PER_IP_DAY / 1024 ))

        s 1
        echo "${G}✅ Parameters set"
        echo "${N}   ❯ Monitored Hosts      : ${Y}$TOTAL_IPS"
        echo "${N}   ❯ Retention days       : ${Y}$RETENTION_DAYS"
        echo "${N}   ❯ Daily volume         : ${Y}$DAILY_INGEST GB"
        if [[ $HOT_COUNT -gt 0 ]]; then echo "${N}   Keep in HOT Tier for : ${Y}$DAY_HOT day(s)"; fi
        if [[ $WARM_COUNT -gt 0 ]]; then echo "${N}   Move to WARM tier on : ${Y}$(($DAY_HOT + 1)).day"; fi
        if [[ $COLD_COUNT -gt 0 ]]; then echo "${N}   Move to COLD tier on : ${Y}$DAY_COLD.day"; fi
        
        setvar "TOTAL_IPS" "TOTAL_IPS"
        setvar "RETENTION_DAYS" "RETENTION_DAYS"
        setvar "DAILY_INGEST" "DAILY_INGEST"
        setvar "DAY_HOT" "DAY_HOT"
        setvar "DAY_WARM" "DAY_WARM"
        setvar "DAY_COLD" "DAY_COLD"
        setvar "KEEP_HOT" "KEEP_HOT"
        setvar "KEEP_WARM" "KEEP_WARM"
        setvar "KEEP_COLD" "KEEP_COLD"
    fi
    # getting container IP address of master1 
    if [[ "$1" == "master" ]]; then
        local MASTER_IP=$(qe sudo docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' master1)
        echo $MASTER_IP
    fi
    # check data tier mounts' available raw space
    if [[ "$1" == "mount_space" ]]; then
        local path="$2"
        local mount_root raw_space

        # if path doesn't exist → return N/A
        if [[ ! -e "$path" ]]; then
            echo "N/A"
            return
        fi
        if [[ -d "$path" ]]; then
            mount_root="$path"
        else
            mount_root=$(dirname "$path")
        fi
        raw_space=$(df -BG --output=avail "$mount_root" 2>/dev/null | tail -1 | tr -d 'G ' || echo "N/A")
        echo "$raw_space"
    fi

    # get storage paths per data tier/nodes
    if [[ "$1" == "storage" ]]; then
        # check base installation
        check "docker" || return 1

        while :; do
            printf "👉 ${G}Enter storage paths for ${Y}base(master* + config) ${G}and ${Y}nodes:${N}\n"
    
            if [[ -n "${DATA[base]}" ]]; then prompt="current: ${DATA[base]}"; default="${DATA[base]}"
            else prompt="default: ${Y}/data${N}"; default="/data"; fi
            printf "   ${N}Enter ${C}BASE${N} data path ($prompt): "; read -r data_path
            data_path="${data_path:-$default}"

            if [[ -n "${DATA[hot]}" ]]; then prompt="current: ${DATA[hot]}"; default="${DATA[hot]}"
            else prompt="default: ${Y}$data_path/hot${N}"; default="$data_path/hot"; fi
            printf "   ${N}Enter ${C}HOT${N}  data path ($prompt): "; read -r hot_path
            hot_path="${hot_path:-$default}"

            if [[ -n "${DATA[warm]}" ]]; then prompt="current: ${DATA[warm]}"; default="${DATA[warm]}"
            else prompt="default: ${Y}$data_path/warm${N}"; default="$data_path/warm"; fi
            printf "   ${N}Enter ${C}WARM${N} data path ($prompt): "; read -r warm_path
            warm_path="${warm_path:-$default}"

            if [[ -n "${DATA[cold]}" ]]; then prompt="current: ${DATA[cold]}"; default="${DATA[cold]}"
            else prompt="default: ${Y}$data_path/cold${N}"; default="$data_path/cold"; fi
            printf "   ${N}Enter ${C}COLD${N} data path ($prompt): "; read -r cold_path
            cold_path="${cold_path:-$default}"

            printf "\n📂 ${G}Storage paths have been set as\n"
            printf "   📦  ${N}Base data     : ${C}$data_path\n"
            printf "   👑  ${N}Master node(s): ${C}$data_path/master\n"
            printf "   🔥  ${N}Hot node(s)   : ${C}$hot_path\n"
            printf "   🌡️   ${N}Warm node(s)  : ${C}$warm_path\n"
            printf "   ❄️   ${N}Cold node(s)  : ${C}$cold_path\n\n"
            read -rp "👉 ${Y}Proceed with these paths? (y/n) " confirm

            if [[ "$confirm" =~ ^[Yy]$ ]]; then
                # save into array + persist
                DATA[base]="$data_path";  setvar "DATA[base]"  "data_path"
                DATA[master]="$data_path/master"; setvar "DATA[master]" "DATA[master]"
                DATA[hot]="$hot_path";    setvar "DATA[hot]"   "hot_path"
                DATA[warm]="$warm_path";  setvar "DATA[warm]"  "warm_path"
                DATA[cold]="$cold_path";  setvar "DATA[cold]"  "cold_path"
            
                for path in "$data_path/master" "$hot_path" "$warm_path" "$cold_path"; do
                    sudo mkdir -p "$path" && sudo chown -R "$USER:docker" "$path"
                done
                break
            elif [[ "$confirm" =~ ^[Nn]$ ]]; then
                clear
                sleep 1
                printf "🔄 ${G}Restarting storage path process..."
            fi
        done
    fi
}

install() {
    # get os + package manager
    detect_os

    # docker installation
    if [[ "$1" == "docker" ]]; then
        # Install Docker using official script
        printf "📦  ${Y}Installing Docker..."
        
        # packages to be removed before docker installation
        local toberemoved=( "containerd" "docker" "docker-client" "docker-client-latest" "docker.io" "docker-doc" "docker-compose" "podman-docker" "runc" "docker-common" "docker-latest" "docker-latest-logrotate" "docker-logrotate" "docker-engine" )
        for pkg in "${toberemoved[@]}"; do q sudo $PKG_MANAGER remove $pkg; done
        
        # debian based distros        
        if [[ "$OS_ID" == "debian" ]]; then
            qe sudo install -m 0755 -d /etc/apt/keyrings
            qe sudo curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
            qe sudo chmod a+r /etc/apt/keyrings/docker.asc
            echo \
              "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian \
              $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
              sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
            q sudo apt-get update -y
            q sudo apt-get install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin -y
        # ubuntu based distros        
        elif [[ "$OS_ID" == "ubuntu" ]]; then
            qe sudo install -m 0755 -d /etc/apt/keyrings
            qe sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
            qe sudo chmod a+r /etc/apt/keyrings/docker.asc
            echo \
              "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
              $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}") stable" | \
              sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
            q sudo apt-get update -y
            q sudo apt-get install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin     -y
        # centos/rhel/fedora distro
        elif [[ "$OS_ID" =~ (centos|redhat) ]]; then
            q sudo $PKG_MANAGER -y install dnf-plugins-core
            q sudo $PKG_MANAGER config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
            q sudo $PKG_MANAGER -y install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
        # alpine distro
        elif [[ "$PKG_MANAGER" == "apk" ]]; then
            echo "apk"
        fi 
        printf "\r📦  ${G}Installing docker...✅\n"

        printf "▶️  ${Y}Starting Docker Service..."
        q sudo systemctl enable --now docker
        printf "\r▶️  ${G}Starting Docker Service...✅\n"

        # add current user to docker group
        printf "📝  ${Y}Adding user:${C}'$USER' ${G}into Docker Group"; sudo usermod -aG docker $USER
        printf "\r📝  ${G}Adding user:${C}'$USER' ${G}into Docker Group...✅\n\n"

        # verify installation
        if q sudo docker run --rm hello-world; then
            printf "✅  ${G}Docker Verification Done...proceeding\n"
    
            # creating default net
            printf "🛠️  ${Y}Creating Default Docker Network"; q sudo docker network create -d bridge esnet
            printf "\r🛠️  ${G}Creating Default Docker Network...✅\n"
            printf "   🌐  ${N}Created Docker network: ${C}esnet\n\n"

            # pulling necessary images for using later
            printf "🐳 ${G}Pulling Necessary Docker Images...\n"
            printf "   📥  ${Y}Pulling Elasticsearch:${ES_VERSION}..."
            q sudo docker pull docker.elastic.co/elasticsearch/elasticsearch:${ES_VERSION}
            printf "\r   📥  ${G}Pulling Elasticsearch:${ES_VERSION}...✅\n"
            printf "   📥  ${Y}Pulling Kibana:${ES_VERSION}..."
            q sudo docker pull docker.elastic.co/kibana/kibana:${ES_VERSION}
            printf "\r   📥  ${G}Pulling Kibana:${ES_VERSION}...${G}✅\n"
            printf "   📥  ${Y}Pulling HAProxy:latest..."
            q sudo docker pull haproxy:latest
            printf "\r   📥  ${G}Pulling HAProxy:latest...${G}✅\n"
            printf "   📥  ${Y}Pulling Fluent-Bit:latest..."
            q sudo docker pull cr.fluentbit.io/fluent/fluent-bit:latest
            printf "\r   📥  ${G}Pulling Fluent-Bit:latest...${G}✅\n"

            # haproxy Deployment
            deploy "haproxy"
            s 1

            # portainer deployment
            deploy "portainer"
            s 1

            # dozzle deployment
            deploy "dozzle"
            s 1
        else
            printf "❌ ${R}Docker installation failed\n"
            return "1"
        fi
    fi

    if [[ "$1" == "package" ]]; then
        # sudo check
        if ! q command -v sudo || [[ ! -f "/etc/sudoers.d/stack" ]]; then install "sudo"; fi; s 1
        
        # use $2 otherwise default list
        local packages=()
        if [[ -n "$2" ]]; then
            packages=("$2")
            printf "🧩  ${Y}Installing requested package: $2${N}\n"
        else
            packages=( "bc" "ca-certificates" "curl" "git" "jq" "nano" "ncat" "openssl" )
            apt_packages=()
            dnf_packages=()

            if [[ "$PKG_MANAGER" == "apt-get" ]]; then packages+=("${apt_packages[@]}"); fi
            if [[ "$PKG_MANAGER" == "dnf" ]]; then packages+=("${dnf_packages[@]}"); fi
            
            printf "🧩  ${Y}Installing mandatory packages...${N}\n"
        fi

        if [[ "$PKG_MANAGER" == "apt-get" ]]; then
            q sudo apt-get update -y
            for str in "${packages[@]}"; do
                printf "   📦 ${Y}Installing: $str"
                if q sudo apt-get install -y "$str"; then
                    printf "\r   📦  ${G}Installed : $str ✅\n"
                else
                    printf "\r   📦  ${R}Failed    : $str ❌\n"
                fi
                sleep 1
            done
        elif [[ "$PKG_MANAGER" == "dnf" ]]; then
            q sudo dnf update -y
            for str in "${packages[@]}"; do
                printf "   📦 ${Y}Installing: $str"
                if q sudo dnf install -y "$str"; then
                    printf "\r   📦 ${G}Installed : $str ✅\n"
                else
                    printf "\r   📦 ${R}Failed    : $str ❌\n"
                fi
                sleep 1
            done
        fi
    fi

    if [[ "$1" == "sudo" ]]; then
        if ! q command -v sudo || [[ ! -f "/etc/sudoers.d/stack" ]]; then
            local tmp
            tmp=$(mktemp /tmp/enable-sudo.XXXXXX) || { echo "❌ Failed to create temp file"; return 1; }

            if [[ "$PKG_MANAGER" == "unknown" ]]; then
                echo "❌ Unsupported OS — cannot determine package manager."
                rm -f "$tmp"
                return 1
            fi

            cat > "$tmp" <<EOF
#!/usr/bin/env bash
set -euo pipefail
echo "📦  Installing sudo package..."
$PKG_MANAGER install -y sudo >/dev/null 2>&1 || {
    echo "❌ Failed to install sudo using $PKG_MANAGER"
    exit 1
}
cat > /etc/sudoers.d/stack <<EOO
$USER ALL=(ALL) NOPASSWD:ALL
EOO
chmod 440 /etc/sudoers.d/stack
echo "✅  User '$USER' added to /etc/sudoers.d/stack"
EOF
            chmod 700 "$tmp"

            echo "🌟  ${G}Enabling sudo... elevated privileges required.${N}"
            echo "👉  You may be prompted for your password."

            # Prefer su on RHEL/CentOS; sudo on Ubuntu/Debian
            if [[ "$PKG_MANAGER" =~ ^(dnf|yum)$ ]]; then
                su -c "bash '$tmp'"
            else
                sudo bash "$tmp" 2>/dev/null || su -c "bash '$tmp'"
            fi

            local rc=$?
            rm -f "$tmp"

            if (( rc != 0 )); then
                echo "🚫 ${R}Failed to enable sudo.${N}"
                exit 1
            fi

            echo "✅  ${G}Sudo installed and configured successfully.${N}"
        else
            echo "✅  ${C}sudo${N} is already installed... skipping."
        fi
    fi
}

## press key to proceed
key() { 
    printf "\n⚠️  ${Y}Press ENTER to continue${N}\n"
    read 
}

# menu categories
menu() {
    # container menu
    if [[ $1 == "containers" ]]; then
        # check base installation
        check "docker" || return 1

        while :; do
            clear
            show "banner" "CONTAINER MENU" 9
            show "containers"; s 1
            cat <<EOF
${Y}$(show "border" "*" 34 "h")
${G}(1)${N} (Re)deploy Dozzle
  ${G}(1a)${N} Restart Dozzle
${G}(2)${N} (Re)deploy Fluent-Bit
  ${G}(2a)${N} Restart Fluent-Bit
  ${G}(2b)${N} Modify Fluent-Bit Conf
  ${G}(2c)${N} Generate Fluent-Bit Conf
${G}(3)${N} (Re)deploy HAProxy
  ${G}(3a)${N} Restart HAProxy
  ${G}(3b)${N} Modify HAProxy Conf
  ${G}(3c)${N} Generate HAProxy Conf
  ${G}(3d)${N} Add HAProxy Auth User
  ${G}(3e)${N} Modify HAProxy Auth User(s)
${G}(4)${N} (Re)deploy Kibana
  ${G}(4a)${N} Generate Kibana Conf
  ${G}(4b)${N} Modify Kibana Conf
  ${G}(4c)${N} Restart Kibana
${G}(5)${N} (Re)deploy Portainer
  ${G}(5a)${N} Restart Portainer

${Y}(e)${N} Main Menu
${Y}$(show "border" "*" 34)${N}

EOF
            read -rp "Select option: " REPLY
            s 1
            case "$REPLY" in
                1)   deploy "dozzle"; key ;;
                1a)  container "restart" "dozzle"; key ;;

                2)   deploy "fluent-bit"; key ;;
                2a)  container "restart" "fluent-bit"; key ;;
                2b)  modify "fluent-bit"; key ;;
                2c)  generate "fluent-bit"; key ;;

                3)   deploy "haproxy"; key ;;
                3a)  container "restart" "haproxy"; key ;;
                3b)  modify "haproxy"; key ;;
                3c)  generate "haproxy"; container "restart" "haproxy"; key ;;
                3d)  generate "ha_users" "create" ; key ;;
                3e)  generate "ha_users" "manage"; key ;;

                4)   deploy "kibana"; key ;;
                4a)  generate "kibana"; key ;;
                4b)  modify "kibana"; key ;;
                4c)  container "restart" "kibana"; key ;;

                5)   deploy "portainer"; key ;;
                5a)  container "restart" "portainer"; key ;;

                e)   break ;;
            esac
        done
    fi

    # elasticsearch menu
    if [[ $1 == "elastic" ]]; then
        # check base paths
        check "datapath" || return 1
        # check docker installation
        check "docker" || return 1
        
        while :; do
            clear
            show "banner" "ELASTICSEARCH MENU" 9; s 1
            show "plan"
            show "resources"
            s 1
            cat <<EOF
${C}👉 Check the deployment plan above. If not exists, then select
${C}   ${Y}OPTION (1) ${C}to create or ${Y}OPTION (34) ${C}will ask for.

${C}👉 You can see the estimated resource distribution per node from 
${C}   the table. MB/day can vary from 25 to 50 (Current:${Y}${MB_PER_IP_DAY}${C} MB/day).

${Y}$(show "border" "*" 38 "h")
${G}(1)${N} Deployment Plan: ${C}Add / Modify 
${G}(2)${N} Deployment Plan: ${C}Automatic

${G}(3) ${Y}⚠️  Deploy Elasticsearch ⚠️
${G}(4) ${Y}⚠️  Deploy Elasticsearch with ${G}Vectra Stream ⚠️

${G}(9)${N} Modify Elasticsearch Config of Nodes

${Y}(e)${N} Main Menu
${Y}$(show "border" "*" 38)${N}

EOF
            read -rp "Select option: " REPLY
            s 1
            case "$REPLY" in
                1)  clear; get "elastic"; key ;;
                2)  clear; get "ingest"; compare ;;
                3)  clear
                    check "system"  
                    check "plan"; s 1
                    show "plan"; s 1
                    printf "${R}⚠️  IF YOU PROCEED, ALL STORED DATA WILL BE DELETED !!!  ⚠️\n"
                    printf "\n☝️  ${Y}Check the current deployment plan above before proceeding! ☝️${N}\n\n"
                    if confirm; then
                        deploy "elastic"
                        container "ifexists" "fluent-bit" && container "start" "fluent-bit" || deploy "fluent-bit"
                        key
                    else
                        echo "❌ Cancelled"
                    fi
                    ;;
                4)  clear
                    check "system"  
                    check "plan"; s 1
                    show "plan"; s 1
                    printf "${R}⚠️  IF YOU PROCEED, ALL STORED DATA WILL BE DELETED !!!  ⚠️\n"
                    printf "\n☝️  ${Y}Check the current deployment plan above before proceeding! ☝️${N}\n\n"
                    if confirm; then
                        deploy "elastic"
                        check "vectra"
                        container "ifexists" "fluent-bit" && container "start" "fluent-bit" || deploy "fluent-bit"
                        key
                    else
                        echo "❌ Cancelled"
                    fi
                    ;;
                
                9)  modify "nodes" ;;
                e)  break ;;
                *)  echo "${R}Invalid option${N}" ;;
            esac
        done
    fi
    # main menu
    if [[ $1 == "main" ]]; then
        while :; do
            clear
            show "banner" "MAIN MENU" 9
            cat <<EOF

$(show "border" "*" 32 "h")
${Y}(A)${N} Deploy Single Node Instance
${Y}(B)${N} Deploy with Automatic Sizing

${G}(1)${N} OS / System
${G}(2)${N} Containers
${G}(3)${N} Elasticsearch
${G}(4)${N} VECTRA

${G}(5)${R} !REMOVE EVERYTHING!

${Y}(e)${N} EXIT
${Y}$(show "border" "*" 32)${N}

EOF
            read -rp "Select option: " REPLY
            s 1
            case "$REPLY" in
                A)  confirm
                    clear
                    install "package"; s 1
                    set "sysparams"; s 1
                    install "docker"; s 1
                    get "elastic" "s"; s 1
                    deploy "elastic"; s 1
                    key ;;

                B)  key ;;

                1)  menu "system" ;;
                2)  menu "containers" ;;
                3)  menu "elastic" ;;
                4)  menu "vectra" ;;
                5)  clear; reset_system; key ;;
                
                e)  clear; exit ;;
                *)  echo "${R}Invalid option${N}"; key ;;
            esac
        done
    fi

    # os/system menu
    if [[ $1 == "system" ]]; then
        while :; do
            clear
            show "banner" "OS / SYSTEM MENU" 9
            cat <<EOF

$(show "border" "*" 38 "h")
${Y}(A)${N} SET ALL AT ONCE

${G}(1)${N} Enable ${Y}'$USER'${N} as sudoer
${G}(2)${N} Install Mandatory Packages
${G}(3)${N} Setting SYS Params (sysctl+limits)
${G}(4)${N} Set Proxy
${G}(5)${N} Set Storage Paths
${G}(6)${N} Install/Update Docker
${G}(7)${N} Generate CSR
  ${G}(7a)${N} Import certificate
  ${G}(7b)${N} (Re)generate certificate
  
${Y}(e)${N} Main Menu
${Y}$(show "border" "*" 38)${N}

EOF
            read -rp "Select option: " REPLY
            s 1
            case "$REPLY" in
                A)  install "package"; s 1
                    set "sysparams"; s 1
                    install "docker"; key ;;
                1)  install "sudo"; key ;;
                2)  install "package"; key ;;
                3)  set "sysparams"; key ;;
                4)  set "proxy"; key ;;
                5)  get "storage" ;;
                6)  install "docker"; key ;;
                7)  generate "csr"; key ;;
                7a) set "cert"; key ;;
                7b) generate "cert"
                    container "restart" "haproxy"
                    key ;;
  
                e)  break ;;
            esac
        done
    fi


    # vectra menu
    if [[ $1 == "vectra" ]]; then
        # check base installation
        check "docker" || return 1

        while :; do
            clear
            show "banner" "VECTRA MENU" 9
            cat <<EOF

$(show "border" "*" 38 "h")
${G}(A)${N} Process All Vectra Operations

${G}(1)${N} Get Vectra Content
${G}(2)${N} Install Elastic Templates
  ${G}(2a)${N} Import/Update Templates
  ${G}(2b)${N} Create/Rollover Initial Indices
${G}(3)${N} Install Kibana Objects

${Y}(e)${N} Return to main menu
${Y}$(show "border" "*" 38)${N}

EOF
            read -rp "Select option: " REPLY
            case "$REPLY" in
                A)  vectra get; vectra elastic; vectra initialize; vectra kibana ;;
                1)  vectra get; key ;;
                2)  vectra elastic; vectra initialize; key ;;
                2a) vectra elastic; key ;;
                2b) vectra initialize; key ;;
                3)  vectra kibana; key ;;
                e)  break ;;
                *)  echo "Invalid option";;
            esac
        done
    fi
}

modify() {
    # check if docker exists
    check "docker" || return 1

    # modify fluent-bit conf
    if [[ "$1" == "fluent-bit" ]]; then
        if [[ -f "${DATA[base]}/config/fluent-bit.cfg" ]]; then
            nano ${DATA[base]}/config/fluent-bit.cfg
            read -rp "⚠️  Do you want to restart Fluent-bit to enable changes? (y/n): " restart_choice
            if [[ "$restart_choice" =~ ^[Yy]$ ]]; then container "restart" "fluent-bit"; fi
        else
            echo "❌ Fluent-bit conf does not exist"
            read -rp "⚠️  Do you want to generate? (y/n): " generate_choice
            if [[ "$generate_choice" =~ ^[Yy]$ ]]; then generate "fluent-bit"; fi
        fi
    fi
    
    # modify haproxy conf
    if [[ "$1" == "haproxy" ]]; then
        if [[ -f ${DATA[base]}/config/haproxy.cfg ]]; then
            nano ${DATA[base]}/config/haproxy.cfg
            read -rp "⚠️  Do you want to restart HAProxy to enable changes? (y/n): " restart_choice
            if [[ "$restart_choice" =~ ^[Yy]$ ]]; then container "restart" "haproxy"; fi
        else
            echo "❌ Haproxy conf does not exist"
            read -rp "⚠️  Do you want to generate? (y/n): " generate_choice
            if [[ "$generate_choice" =~ ^[Yy]$ ]]; then generate "haproxy"; fi
        fi
    fi

    # modify kibana conf
    if [[ "$1" == "kibana" ]]; then
        if [[ -f "${DATA[base]}/config/kibana.yml" ]]; then
            nano ${DATA[base]}/config/kibana.yml
            read -rp "⚠️  Do you want to restart Kibana to enable changes? (y/n): " restart_choice
            if [[ "$restart_choice" =~ ^[Yy]$ ]]; then container "restart" "kibana"; fi
        else
            echo "❌ Kibana conf does not exist"
            read -rp "⚠️  Do you want to generate? (y/n): " generate_choice
            if [[ "$generate_choice" =~ ^[Yy]$ ]]; then generate "kibana"; fi
        fi
    fi

    # modify elasticsearhc nodes' conf
    if [[ "$1" == "nodes" ]]; then
        local cfgdir="${DATA[base]}/config"
        local nodes=()

        # verify directory exists
        if [[ ! -d "$cfgdir" ]]; then
            echo "❌ Config directory not found: $cfgdir"
            return 1
        fi

        # collect node names from .yml and .jvm files
        shopt -s nullglob
        local files=("$cfgdir"/*.{yml,jvm})
        shopt -u nullglob

        # if no files found
        if [[ ${#files[@]} -eq 0 ]]; then
            echo "❌ No node config or JVM files found in $cfgdir"
            return 1
        fi

        # extract unique node names
        for f in "${files[@]}"; do
            local filename=$(basename "$f")
            local nodename="${filename%%.*}"
            [[ " ${nodes[*]} " =~ " $nodename " ]] || nodes+=("$nodename")
        done

        # node selection
        local node
        while true; do
            printf "👉 ${G}Select node to edit:${N}\n"
            select node_option in "${nodes[@]}" "Cancel"; do
                case "$node_option" in
                    "Cancel"|"") echo "❌ Cancelled."; return ;;
                    *) node="$node_option"; break 2 ;;
                esac
            done
        done
        s 1

        # file type selection
        local file_type
        while true; do
            printf "👉 ${G}Select file type to edit:${N}\n"
            select type_option in "Config (.yml)" "JVM (.jvm)" "Cancel"; do
                case "$type_option" in
                    "Config (.yml)") file_type="yml"; break 2 ;;
                    "JVM (.jvm)") file_type="jvm"; break 2 ;;
                    "Cancel"|"") echo "❌ Cancelled."; return ;;
                    *) echo "⚠️ Invalid option, try again." ;;
                esac
            done
        done

        local file_to_edit="$cfgdir/$node.$file_type"

        # check if file exists
        if [[ ! -f "$file_to_edit" ]]; then
            echo "❌ File $file_to_edit does not exist"
            return 1
        fi

        # edit file
        nano "$file_to_edit"

        # ask if user wants to restart container
        if q container "ifexists" "$node"; then
            while true; do
                read -rp "🔄 ${Y}Restart container ${C}$node? ${Y}(y/n): " restart_choice
                case "$restart_choice" in
                    [Yy]* ) container "restart" "$node"; break ;;
                    [Nn]* ) printf "💡 Skipping restart\n"; break ;;
                    * ) echo "⚠️ Please answer y or n." ;;
                esac
            done
            container "ifrunning" "$node"
        fi
    fi
}

# deployment planning
# calculation of number of ndoes per tier / auto or manual
plan() {
    if [[ "$1" == "auto" ]]; then
        # defaults
        local auto_master=1 auto_hot=0 auto_warm=0 auto_cold=0

        # master nodes
        if (( TOTAL_IPS < 25000 )); then auto_master=1
        elif (( TOTAL_IPS >= 25000 )); then auto_master=3; fi

        # hot nodes / rules: ~250 GB/day per hot node
        if (( DAILY_INGEST <= 250 )); then auto_hot=1
        else auto_hot=$(( (DAILY_INGEST + 249) / 250 )); fi

        # warm nodes / rules: warm per 2 hot + wamr for every 60 days
        if (( RETENTION_DAYS > 7 && RETENTION_DAYS <= 60 )); then
            if (( auto_hot <= 2 )); then
                auto_warm=1
            elif (( auto_hot >= 3 && auto_hot <= 4 )); then
                auto_warm=2
            else
                auto_warm=$(( (auto_hot + 1) / 2 ))  # ceil(auto_hot / 2)
            fi
        fi

        # cold nodes / rules: after 90 days and + every 90 days
        if (( RETENTION_DAYS > 90 && RETENTION_DAYS <= 360 )); then
            auto_cold=1
        elif (( RETENTION_DAYS > 180 )); then
            auto_cold=2
        fi

        # print proposal
        printf "\n${Y}PROPOSED AUTO-SIZED DEPLOYMENT PLAN${N}\n"
        printf "+------------------+-------+\n"
        printf "| ${C}%-16s ${G}| ${C}%-5s ${G}|\n" "Type" "Count"
        printf "+------------------+-------+\n"
        printf "| ${G}%-16s ${G}| ${N}%-5s ${G}|\n" "Master node(s)" "$auto_master"
        printf "| ${G}%-16s ${G}| ${N}%-5s ${G}|\n" "Hot node(s)" "$auto_hot"
        printf "| ${G}%-16s ${G}| ${N}%-5s ${G}|\n" "Warm node(s)" "$auto_warm"
        printf "| ${G}%-16s ${G}| ${N}%-5s ${G}|\n" "Cold node(s)" "$auto_cold"
        printf "+------------------+-------+\n"

        # optional: highlight ingest/retention context
        printf "📊 Daily ingest: ${Y}${DAILY_INGEST} GB${N}, Retention: ${Y}${RETENTION_DAYS} days${N}, Hosts: ${Y}${TOTAL_IPS}${N}\n"
    fi

    if [[ "$1" == "manual" ]]; then
        # calculate jvm heap size
        calc_heap() {
            local node_mem=$1
            local heap=$(( node_mem / 2 ))
            (( heap > 32 )) && heap=32
            echo "$heap"
        }
        # calculate node container memory
        allocate_node_mem() {
            local type="$1"
            local per_weight="$2"
            case "$MODE" in
                SINGLE) echo "$usable_mem_gb" ;;
                MULTI)
                    case "$type" in
                        master) echo "$MASTER_FIXED" ;;
                        hot)    echo "$(printf "%.0f" "$(echo "$WEIGHT_HOT * $per_weight" | bc)")" ;;
                        warm)   echo "$(printf "%.0f" "$(echo "$WEIGHT_WARM * $per_weight" | bc)")" ;;
                        cold)   echo "$(printf "%.0f" "$(echo "$WEIGHT_COLD * $per_weight" | bc)")" ;;
                        *)      echo "$(printf "%.0f" "$(echo "$pool / $TOTAL_COUNT" | bc)")" ;;
                    esac ;;
            esac
        }

        declare -gA SUM_MEM SUM_HEAP SUM_SPACE SUM_HEAP_RATIO
        TOTAL_MEM_SUM=0
        TOTAL_HEAP_SUM=0
        TOTAL_SPACE_SUM=0

        # calculation of cpu usage, memory
        total_cpu=$(nproc --all)
        total_mem_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
        total_mem_gb=$(( total_mem_kb / 1024 / 1024 ))
        usable_mem_gb=$(( total_mem_gb - RESERVED_MEM ))
        (( usable_mem_gb < 1 )) && usable_mem_gb=1

        pool=$usable_mem_gb
        alloc_master=$(( MASTER_COUNT * MASTER_FIXED ))
        pool=$(( pool - alloc_master ))
        (( pool < 0 )) && pool=0

        local total_weight=$(( HOT_COUNT*WEIGHT_HOT + WARM_COUNT*WEIGHT_WARM + COLD_COUNT*WEIGHT_COLD ))
        (( total_weight == 0 )) && total_weight=1
        local per_weight=$(echo "scale=2; $pool / $total_weight" | bc)

        # clean old vars from .vars
        sed -i '/^CONT_MEM\[/d;/^JVM_MEM\[/d' "$SCRIPT_DIR/.vars"

        for i in $(seq 1 $TOTAL_COUNT); do
            local type="${NODE_TYPE[$i]:-}"
            local label="${NODE_LABEL[$i]:-}"

            # skip if type or label not defined
            [[ -z "$type" || -z "$label" ]] && continue

            local path="${DATA[$type]:-${DATA[base]}}"

            local mem=$(allocate_node_mem "$type" "$per_weight")
            local heap=$(calc_heap "$mem")

            local raw_space=$(get "mount_space" "$path")
            local space_gb="N/A"
            if [[ "$raw_space" != "N/A" ]]; then
                case "$type" in
                    master) count=$MASTER_COUNT ;;
                    hot)    count=$HOT_COUNT ;;
                    warm)   count=$WARM_COUNT ;;
                    cold)   count=$COLD_COUNT ;;
                    *)      count=1 ;;
                esac
                space_gb=$(echo "scale=1; $raw_space / $count" | bc)
            fi

            CONT_MEM[$i]=$mem
            JVM_MEM[$i]=$heap
            setvar "CONT_MEM[$i]" "mem"
            setvar "JVM_MEM[$i]" "heap"

            # assign only if label is valid
            SUM_MEM["$label"]="$mem"
            SUM_HEAP["$label"]="$heap"
            SUM_SPACE["$label"]="$space_gb"

            if (( mem > 0 )); then
                SUM_HEAP_RATIO["$label"]="$(( heap * 100 / mem ))%"
            else
                SUM_HEAP_RATIO["$label"]="N/A"
            fi

            TOTAL_MEM_SUM=$(( TOTAL_MEM_SUM + mem ))
            TOTAL_HEAP_SUM=$(( TOTAL_HEAP_SUM + heap ))

            if [[ "$space_gb" != "N/A" ]]; then
                TOTAL_SPACE_SUM=$(echo "$TOTAL_SPACE_SUM + $space_gb" | bc)
            fi
        done
    fi
}

# factory reset the system
reset_system() {
    # detect os + package manager
    detect_os

    echo
    echo "${R}⚠️  FACTORY RESET MODE INITIATED${N}"
    echo "This operation will completely remove all Docker data and packages."
    echo "It will:"
    echo "  - Stop and remove ALL containers"
    echo "  - Remove ALL volumes, images, and networks"
    echo "  - Uninstall Docker packages"
    echo "  - Clean up related directories (/var/lib/docker, /var/lib/containerd)"
    echo
    read -rp "❗ Proceed with full factory reset? (y/n): " confirm
    [[ "$confirm" != [Yy] ]] && { echo "❌ Aborted."; return 1; }

    echo
    echo "${Y}🧩 Stopping all Docker containers...${N}"
    q sudo systemctl stop docker >/dev/null 2>&1 || true
    q sudo systemctl stop docker.socket >/dev/null 2>&1 || true

    echo
    # removing docker content
    echo "${Y}📦 Removing containers, images, volumes, and networks...${N}"
    q sudo docker ps -aq | xargs -r sudo docker stop >/dev/null 2>&1
    q sudo docker ps -aq | xargs -r sudo docker rm -f >/dev/null 2>&1
    q sudo docker volume ls -q | xargs -r sudo docker volume rm >/dev/null 2>&1
    q sudo docker network ls -q | grep -v "bridge\|host\|none" | xargs -r sudo docker network rm >/dev/null 2>&1
    q sudo docker image prune -a -f >/dev/null 2>&1
    q sudo docker system prune -a --volumes -f >/dev/null 2>&1

    echo "✅ All Docker resources removed."

    echo
    # removing docker packages
    printf "${Y}Uninstalling Docker packages...⏳${N}"
    case "$PKG_MANAGER" in
        apt-get)
            q sudo apt-get remove --purge -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin >/dev/null 2>&1
            ;;
        dnf)
            q sudo "$PKG_MANAGER" remove -y ddocker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin >/dev/null 2>&1
            ;;
        apk)
            q sudo apk del docker docker-cli containerd >/dev/null 2>&1
            ;;
    esac

    q sudo rm -rf /var/lib/docker /var/lib/containerd /etc/docker /etc/systemd/system/docker.service.d >/dev/null 2>&1
    printf "\r${G}Uninstalling Docker packages...✅${N}\n"
    
    # removing custom os parameters
    printf "${Y}Removing OS custom parameters...⏳${N}"
    q sudo rm -fr /etc/sysctl.d/99-stack-sysctl.conf
    q sudo rm -fr /etc/security/limits.d/99-stack-limits.conf
    printf "\r${G}Removing OS custom parameters...✅${N}\n"

    # removing data directories
    printf "${Y}Removing data directorries...⏳${N}"
    q sudo rm -fr ${DATA[base]}
    q sudo rm -fr ${DATA[master]}
    q sudo rm -fr ${DATA[hot]}
    q sudo rm -fr ${DATA[warm]}
    q sudo rm -fr ${DATA[cold]}
    printf "\r${G}Removing data directorries...✅${N}\n"

    # removing additional packages
    printf "${Y}Uninstalling additional packages...⏳${N}"
    case "$PKG_MANAGER" in
        apt-get)
            q sudo apt-get remove --purge -y bc ca-certificates curl git jq nano ncat openssl >/dev/null 2>&1
            q sudo apt-get autoremove -y >/dev/null 2>&1
            ;;
        dnf)
            q sudo "$PKG_MANAGER" remove -y bc ca-certificates curl git jq nano ncat openssl >/dev/null 2>&1
            ;;
        apk)
            q sudo apk del bc ca-certificates curl git jq nano ncat openssl >/dev/null 2>&1
            ;;
    esac
    printf "\r${G}Uninstalling additional packages...✅${N}\n"

    # removing sudo
    printf "${Y}Removing ${C}$USER${Y} from sudo...⏳${N}"
    q sudo rm -fr /etc/sudoers.d/stack
    printf "\r${G}Removing ${C}$USER${G} from sudo...✅${N}\n"

    echo
    echo "${G}✅ Factory reset complete! Stack and its components have been fully removed.${N}"
}

## next
s() { local n="${1:-1}"; for ((i=0; i<n; i++)); do printf "\n"; done }

# general set function
set() {
    # get os + package manager
    detect_os

    # import signed certificate
    if [[ "$1" == "cert" ]]; then
        check "configpath"
        local CERT_DIR="${DATA[base]}/certs"
        local STACK_CERT="$CERT_DIR/stack.pem"
        local CSR_KEY="$CERT_DIR/csr.key"
        local CRT_EXT="/tmp/external.pem"

        local STACK_CERT_EXT="$CERT_DIR/stack_ext.pem"

        printf "👉 ${G}Place the cert as ${Y}$CRT_EXT\n\n"

        confirm "${N}Confirm if it is uploaded${N}"

        printf "🔒 ${Y}Importing certificate..."
        if [[ -f $CRT_EXT ]]; then
            sudo cp "$STACK_CERT" "$STACK_CERT.default"
            sudo rm -fr $STACK_CERT
            
            cat $CSR_KEY $CRT_EXT > $STACK_CERT
            sudo chmod -R 664 $CERT_DIR/*
        else
            printf "❌ not found...returning\n"
            return 1
        fi
        printf "\r🔐 ${G}Importing certificate...✅\n"
        container "restart" "haproxy"
    fi
    # setting proxy config
    if [[ "$1" == "proxy" ]]; then
        printf "${G}Setting proxy${N}\n\n"
        read -p "Enter proxy address(http://proxy-srv:port): " PROXYSRV
        if [[ ${PROXYSRV} != "" ]]; then 
            export HTTP_PROXY=${PROXYSRV}
            export HTTPS_PROXY=${PROXYSRV}
            printf "Proxy is set: %s\n" $HTTP_PROXY

            # set proxy for different package managers and systems
            if [[ "$PKG_MANAGER" == "apt-get" ]]; then
                # For Debian/Ubuntu
                sudo mkdir -p /etc/apt/apt.conf.d/
                echo "Acquire::http::Proxy \"${PROXYSRV}\";" | sudo tee /etc/apt/apt.conf.d/95proxy
                echo "Acquire::https::Proxy \"${PROXYSRV}\";" | sudo tee -a /etc/apt/apt.conf.d/95proxy
            elif [[ "$PKG_MANAGER" == "dnf" ]]; then
                # for rhel/centos/fedora
                echo "proxy=${PROXYSRV}" | sudo tee -a  /etc/dnf/dnf.conf
            fi

            # set for git
            git config --global http.proxy ${PROXYSRV}
            git config --global https.proxy ${PROXYSRV}

            # set for docker (if installed)
            if q command -v docker; then
                sudo mkdir -p /etc/systemd/system/docker.service.d/
                sudo bash -c "cat > /etc/systemd/system/docker.service.d/http-proxy.conf <<EOF
[Service]
Environment=\"HTTP_PROXY=${PROXYSRV}\"
Environment=\"HTTPS_PROXY=${PROXYSRV}\"
EOF"
                sudo systemctl daemon-reload
                sudo systemctl restart docker
            fi
        fi
        printf "\n"
    fi

    # set os params necessary for elasticsearch env
    if [[ "$1" == "sysparams" ]]; then
        if ! q command -v sudo || [[ ! -f "/etc/sudoers.d/stack" ]]; then install "sudo"; fi
        printf "📝  ${Y}Setting Parameters in ${C}/etc/sysctl.d/99-stack-sysctl.conf"
        qo sudo su <<EOP
        cat <<EOO > /etc/sysctl.d/99-stack-sysctl.conf
######## VM / mmap / swap ########
vm.max_map_count = 524288
vm.swappiness = 0
# Writeback: prefer bytes on big-RAM systems ( main x 1024^3 )
vm.dirty_background_bytes = 4294967296
vm.dirty_bytes = 12884901888
vm.dirty_writeback_centisecs = 100
vm.dirty_expire_centisecs = 6000
######## Files / inotify ########
fs.file-max = 2097152
fs.inotify.max_user_watches = 1048576
fs.inotify.max_user_instances = 1024
######## Networking buffers ########
net.core.rmem_default = 1048576
net.core.wmem_default = 1048576
net.core.rmem_max = 134217728
net.core.wmem_max = 134217728
net.ipv4.tcp_rmem = 4096 1048576 134217728
net.ipv4.tcp_wmem = 4096 1048576 134217728
######## Queues / backlog ########
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 250000
######## Ports / timeouts ########
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_retries2 = 12
net.ipv4.tcp_mtu_probing = 1
EOO
sysctl -p /etc/sysctl.d/99-stack-sysctl.conf
EOP
        printf "\r✅  ${G}Setting Parameters in ${C}/etc/sysctl.d/99-stack-sysctl.conf${G}...done\n"
    
        # set limits
        printf "📝  ${Y}Setting Limits in /etc/security/limits.d/99-stack-limits.conf"
        qo sudo su <<EOL
        echo "ulimit -n 65535" >> /etc/profile
        cat <<EOO > /etc/security/limits.d/99-stack-limits.conf
* soft     nproc          65535
* hard     nproc          65535
* soft     nofile         65535
* hard     nofile         65535
* soft     filesize       65535
* hard     filesize       65535
elasticsearch soft memlock unlimited
elasticsearch hard memlock unlimited
EOO
    ulimit -n 65535
    printf "\n"
EOL
        printf "\r✅  ${G}Setting Limits in ${C}/etc/security/limits.d/99-stack-limits.conf${G}...done\n"

    fi
}

# print to screen
show() {
    # menu banner
    if [[ "$1" == "banner" ]]; then
        local title="$2"
        local add=$3
        local len=${#title}
        local len=$((${#title}+$add))

        printf "${Y}%s\n" "$(printf '═%.0s' $(seq 1 $len))"
        printf "${Y}★★★ %s ★★★\n" "$title"
        printf "${Y}%s\n" "$(printf '═%.0s' $(seq 1 $len))"
    fi

    # menu border
    if [[ "$1" == "border" ]]; then
        if [[ "$4" == "h" ]]; then printf "${Y}=== OPTIONS ===\n"; fi
        printf "%.0s$2" $(seq 1 $3); s 1
    fi

    # show container list in a table
    if [[ "$1" == "containers" ]]; then
        if ! qo command -v docker && [[ -z $(docker ps -aq 2>/dev/null) ]]; then return 0; fi

        local containers=($(qe sudo docker ps -a --format '{{.Names}}' | sort))
        echo "$separator"
        local TableWidth=95   # matches content
        local seperator="${G}+-----------+-------+------------+-------------+-----------+--------+-----------------+----------+\n"

        printf "$seperator"
        printf "|%-11s|%-7s|%-12s|%-13s|%-11s|%-8s|%-17s|%-10s|\n" Name Status Service "Container ID" "IP Address" "CPU %" "MEM Usage/Limit" "Ext.Ports"
        printf "$seperator"

        local rows="${G}|${Y}%-11s${G}|${C}%-7s${G}|${M}%-12s${G}|${N}%-13s${G}|${N}%-11s${G}|${N}%-8s${G}|${N}%-17s${G}|${N}%-10s${G}|\n"
        local id ip status service cpu memusage eport

        # gather stats for all containers in one go
        declare -A CPU_STATS MEM_STATS
        while read -r name cpu mem; do
            mem=$(echo "$mem" | sed -E 's/MiB/M/; s/GiB/G/')   # normalize units
            CPU_STATS["$name"]="$cpu"
            MEM_STATS["$name"]="$mem"
        done < <(qe sudo docker stats --no-stream --format "{{.Name}} {{.CPUPerc}} {{.MemUsage}}")

        for name in "${containers[@]}"; do
            id=$(sudo docker ps -a | grep "$name" | awk '{ print $1 }' | cut -c1-12)
            ip=$(qe sudo docker inspect --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$name")

            # published ports (only port numbers, no host IP)
            eport=$(sudo docker inspect "$name" | jq -r \
                '.[0].NetworkSettings.Ports | to_entries[] | select(.value != null) |
                 .value[] | .HostPort' | sort -u | paste -sd "," -)

            # running state & health
            if [[ "$(qe sudo docker container inspect -f '{{.State.Running}}' "$name")" == "true" ]]; then
                status='UP'
                if [[ "$name" =~ ^(master.*|hot.*|warm.*|cold.*)$ ]]; then
                    temp=$(curl -XGET --max-time 2 -s "http://$ip:9200/_cluster/health" | jq -r .status)
                    if [[ $temp == "green" ]]; then service='Healthy'
                    elif [[ $temp =~ ^(yellow|red)$ ]]; then service='Unhealthy'
                    else service='Unavailable'; fi
                elif [[ "$name" == "kibana" ]]; then
                    temp=$(curl -k -s --max-time 2 -XGET "http://$ip:5601/api/status" | jq -r .status.overall.level)
                    if [[ $temp == "available" ]]; then service='Healthy'
                    elif [[ $temp =~ ^(yellow|red)$ ]]; then service='Unhealthy'
                    else service='Unavailable'; fi
                elif [[ "$name" == "fluent-bit" ]]; then
                    if timeout 3 bash -c "cat < /dev/null > /dev/tcp/$ip/9999" 2>/dev/null; then service="Healthy"
                    else service="Unhealthy"; fi
                elif [[ "$name" == "portainer" ]]; then
                    if timeout 3 bash -c "cat < /dev/null > /dev/tcp/$ip/8000" 2>/dev/null; then service="Healthy"
                    else service="Unhealthy"; fi
                elif [[ "$name" == "dozzle" ]]; then
                    if timeout 3 bash -c "cat < /dev/null > /dev/tcp/$ip/8080" 2>/dev/null; then service="Healthy"
                    else service="Unhealthy"; fi
                elif [[ "$name" == "haproxy" ]]; then
                    if timeout 3 bash -c "cat < /dev/null > /dev/tcp/$ip/443" 2>/dev/null; then service="Healthy"
                    else service="Unhealthy"; fi
                else
                    service='N/A'
                fi
            elif [[ "$(sudo docker container inspect -f '{{.State.Running}}' "$name" 2>/dev/null)" == "false" ]]; then
                status='DOWN'; service='N/A'
            else
                status="N/A"; service="N/A"
            fi

            cpu="${CPU_STATS[$name]:-N/A}"
            memusage="${MEM_STATS[$name]:-N/A}"

            printf "$rows" "$name" "$status" "$service" "$id" "$ip" "$cpu" "$memusage" "$eport"
            printf "$seperator"
        done

        printf "\n${Y}Press <ENTER> to refresh list (will take a few seconds)...${N}\n\n"
    fi

    # show deployment plan
    if [[ "$1" == "plan" ]]; then
        if [[ -n "$MODE" ]]; then
            local total_width=57

            printf "${G}CURRENT DEPLOYMENT PLAN   ===>>>   ${Y}'$MODE' ${G}MODE\n"
            printf "${G}+------------------+-------+------------------------------+\n"
            printf "| ${C}%-16s ${G}| ${C}%-5s ${G}| ${C}%-28s ${G}|\n" "Type" "Count" "Path"
            printf "+------------------+-------+------------------------------+\n"
            printf "| ${G}%-16s ${G}| ${N}%-5s ${G}| ${N}%-28s ${G}|\n" "Base Data/Config" "-" "${DATA[base]}"
            for type in master hot warm cold; do
                count_var="${type^^}_COUNT"
                count=${!count_var}
                path="${DATA[$type]}"
                if (( count > 0 )); then
                    printf "| ${G}%-16s ${G}| ${N}%-5s ${G}| ${N}%-28s ${G}|\n" "${type^} node(s)" "$count" "$path"
                fi
            done
            printf "+---------------------------------------------------------+\n"
        fi
    fi

    # show calculated resources per elasticsearch node
    if [[ "$1" == "resources" ]]; then
        plan "manual"
        printf "${G}+----------+---------+------------+----------+------------+\n"
        printf "| ${C}%-8s ${G}| ${C}%-7s ${G}| ${C}%-10s ${G}| ${C}%-8s ${G}| ${C}%-10s ${G}|\n" \
          "Node" "Type" "Memory(GB)" "Heap(GB)" "Avail(GB)"
        printf "+----------+---------+------------+----------+------------+\n"
        for i in $(seq 1 $TOTAL_COUNT); do
            local type="${NODE_TYPE[$i]:-}"
            local label="${NODE_LABEL[$i]:-}"

            # skip if label or type is missing
            [[ -z "$label" || -z "$type" ]] && continue

            printf "| ${G}%-8s ${G}| ${B}%-7s ${G}| ${N}%-10s ${G}| ${N}%-8s ${G}| ${N}%-10s ${G}|\n" \
              "$label" "$type" "${SUM_MEM["$label"]}" "${SUM_HEAP["$label"]}" \
              "${SUM_SPACE["$label"]}"
        done

        printf "|---------------------------------------------------------|\n"
        printf "| ${C}%-8s ${G}| ${N}%-7s ${G}| ${N}%-10s ${G}| ${N}%-8s ${G}| ${N}%-10s ${G}|\n" \
          "TOTAL" "-" "$TOTAL_MEM_SUM" "$TOTAL_HEAP_SUM" "$TOTAL_SPACE_SUM"
        printf "+----------+---------+------------+----------+------------+\n"

        # ingestion estimate
        local DAILY_MB=$(( TOTAL_IPS * MB_PER_IP_DAY ))
        local DAILY_GB=$(( DAILY_MB / 1024 ))
        local TOTAL_DATA=$(( DAILY_GB * RETENTION_DAYS * REPLICA_FACTOR ))

        printf "| ${C}%-55s ${G}|\n" "Data Ingestion / Size Estimations"
        echo "|---------------------------------------------------------|"
        printf "| ${C}%-18s ${N}%-37s${G}|\n" "IPs monitored    :" "$TOTAL_IPS"
        printf "| ${C}%-18s ${N}%-37s${G}|\n" "Avg per IP/day   :" "$MB_PER_IP_DAY MB"
        printf "| ${C}%-18s ${N}%-37s${G}|\n" "Daily ingest     :" "$DAILY_MB MB ($DAILY_GB GB)"
        printf "| ${C}%-18s ${N}%-37s${G}|\n" "Retention days   :" "$RETENTION_DAYS"
        if [[ "$MODE" == "MULTI" ]]; then
            printf "| ${C}%-18s ${N}%-37s${G}|\n" "Tier days (Hot)  :" "$KEEP_HOT"
            (( WARM_COUNT > 0 )) && printf "| ${C}%-18s ${N}%-37s${G}|\n" "Tier days (Warm) :" "$KEEP_WARM"
            (( COLD_COUNT > 0 )) && printf "| ${C}%-18s ${N}%-37s${G}|\n" "Tier days (Cold) :" "$KEEP_COLD"
        fi
        printf "| ${C}%-18s ${N}%-37s${G}|\n" "Replica factor   :" "$REPLICA_FACTOR"
        printf "| ${C}%-18s ${N}%-37s${G}|\n" "Total storage    :" "$TOTAL_DATA GB"
        echo "+${G}---------------------------------------------------------+"

        # ensure no negatives
        (( KEEP_HOT < 0 )) && KEEP_HOT=0
        (( KEEP_WARM < 0 )) && KEEP_WARM=0
        (( KEEP_COLD < 0 )) && KEEP_COLD=0
       
        # ILM-aware check
        check "storage" "$TOTAL_DATA"
    fi
}

# vectra content function
vectra() {
    local vectradir=${DATA[base]}/vectra
    local ELASTIC_PATH="$vectradir/elastic"
    local KIBANA_PATH="$vectradir/kibana"

    # get vectra content from github
    if [[ "$1" == "get" ]]; then
        sudo rm -fr $vectradir
        sudo mkdir -p $vectradir/{elastic,kibana}
        sudo chown -R $USER:docker $vectradir

        printf "📥 ${Y}Getting ${C}Vectra Content ${Y}from Github Repo"
        if [[ $proxysrv != "" ]]; then
            q git clone --config "http.proxy=${proxysrv}" https://github.com/vectranetworks/    vectra-content-for-elkgit $vectradir/tmp
        else 
            q git clone https://github.com/vectranetworks/vectra-content-for-elk.git $vectradir/tmp
        fi
        printf "\r📥 ${G}Getting ${C}Vectra Content ${G}from Github Repo...✅\n"

        printf "⚙️  ${Y}Extracting Vectra Content"
        mv $vectradir/tmp/elastic-index-templates/tpl_8x/* $vectradir/elastic/ 
        mv $vectradir/tmp/kibana-searches-dashboards/8.x/* $vectradir/kibana/
        rm -fr $vectradir/tmp
        printf "\r⚙️  ${G}Extracting Vectra Content...✅"
        s 2
    fi

    # import vectra indexes and their templates into elasticsearch
    if [[ "$1" == "elastic" ]]; then
        # check master1
        check "elastic"; local status=$?; if [[ $status -ne 0 ]]; then s 1; return 1; fi
        # get master1 address
        local MASTER_IP=$(sudo docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' master1)
        
        # stop fluent-bit if running to prevent false indexes
        container "ifexists" "fluent-bit" && container "stop" "fluent-bit"

        # generate new ilm config according to the plan
        generate "ilm"

        # setting generic parameters
        local REFRESH_INTERVAL="15"
        local REPLICAS=0
        local SHARDS=1

        # shard numbers
        local s_metadata_beacon=1
        local s_metadata_dcerpc=1
        local s_metadata_dhcp=1
        local s_metadata_dns=1
        local s_metadata_httpsessioninfo=1
        local s_metadata_isession=1
        local s_metadata_kerberos_txn=1
        local s_metadata_ldap=1
        local s_metadata_match=1
        local s_metadata_ntlm=1
        local s_metadata_radius=1
        local s_metadata_rdp=1
        local s_metadata_smbfiles=1
        local s_metadata_smbmapping=1
        local s_metadata_smtp=1
        local s_metadata_ssh=1
        local s_metadata_ssl=1
        local s_metadata_x509=1

        # index based replica counts
        local r_metadata_beacon=0
        local r_metadata_dcerpc=0
        local r_metadata_dhcp=0
        local r_metadata_dns=0
        local r_metadata_httpsessioninfo=0
        local r_metadata_isession=0
        local r_metadata_kerberos_txn=0
        local r_metadata_ldap=0
        local r_metadata_match=0
        local r_metadata_ntlm=0
        local r_metadata_radius=0
        local r_metadata_rdp=0
        local r_metadata_smbfiles=0
        local r_metadata_smbmapping=0
        local r_metadata_smtp=0
        local r_metadata_ssh=0
        local r_metadata_ssl=0
        local r_metadata_x509=0

        # index based refresh intervals
        local rf_metadata_beacon="60s"
        local rf_metadata_dcerpc="60s"
        local rf_metadata_dhcp="60s"
        local rf_metadata_dns="60s"
        local rf_metadata_httpsessioninfo="60s"
        local rf_metadata_isession="60s"
        local rf_metadata_kerberos_txn="60s"
        local rf_metadata_ldap="60s"
        local rf_metadata_match="60s"
        local rf_metadata_ntlm="60s"
        local rf_metadata_radius="60s"
        local rf_metadata_rdp="60s"
        local rf_metadata_smbfiles="60s"
        local rf_metadata_smbmapping="60s"
        local rf_metadata_smtp="60s"
        local rf_metadata_ssh="60s"
        local rf_metadata_ssl="60s"
        local rf_metadata_x509="60s"

        # create ILM default policy
        printf "📝  ${Y}ILM Default Policy\n${N}"
        for ILM_PATH in $(ls $ELASTIC_PATH/ilm/*.jsonc); do
            ILM_NAME=$(basename "$ILM_PATH" .jsonc)

            printf "❯ ${Y}Importing ilm policy => ${C}$ILM_NAME"
            q curl -s -XPUT "http://$MASTER_IP:9200/_ilm/policy/$ILM_NAME" -H "Content-Type:   application/json" --data-binary @$ILM_PATH
            printf "\r❯ ${G}Importing ilm policy => ${C}$ILM_NAME${G}...✅\n"
        done
        s 1
        # create template components
        printf "📝  ${Y}Template Components\n${N}"
        for COMPONENT_PATH in "$ELASTIC_PATH"/component_templates/*.jsonc; do
            COMPONENT_NAME=$(basename "$COMPONENT_PATH" .jsonc)
            PAYLOAD=$(jq . "$COMPONENT_PATH")
            printf "❯ ${Y}Importing component template => ${C}$COMPONENT_NAME"
            q curl -s -XPUT "http://$MASTER_IP:9200/_component_template/$COMPONENT_NAME" -H    "Content-Type: application/json" --data-binary "$PAYLOAD"
            printf "\r❯ ${G}Importing component template => ${C}$COMPONENT_NAME${G}...✅\n"
        done
        s 1
        # create index templates
        printf "📝  ${Y}Index Templates\n${N}"
        for TEMPLATE_PATH in "$ELASTIC_PATH"/*.jsonc; do
            TEMPLATE_NAME=$(basename "$TEMPLATE_PATH" .jsonc)
            refresh="rf_$TEMPLATE_NAME"
            shards="s_$TEMPLATE_NAME"
            replicas="r_$TEMPLATE_NAME"
            PAYLOAD=$(jq \
            --arg refresh_interval "${!refresh}" \
            --arg number_of_shards "${!shards}" \
            --arg number_of_replicas "${!replicas}" \
            '.template.settings.refresh_interval=$refresh_interval |
            .template.settings.index.number_of_shards=$number_of_shards |
            .template.settings.index.store.type="mmapfs" |
            .template.settings.index.number_of_replicas=$number_of_replicas' \
            "$TEMPLATE_PATH")
            #printf "$PAYLOAD\n\n"
            #printf "Removing old index template: *** $TEMPLATE_NAME ***\n"
            #curl -s -XDELETE "http://$MASTER_IP:9200/_index_template/$TEMPLATE_NAME"
            printf "❯ ${Y}Creating new index template => ${C}$TEMPLATE_NAME"
            q curl -s -XPUT "http://$MASTER_IP:9200/_index_template/$TEMPLATE_NAME" -H     "Content-Type: application/json" --data-binary "$PAYLOAD"
            printf "\r❯ ${G}Creating new index template => ${C}$TEMPLATE_NAME${G}...✅\n"
        done
        # start fluent-bit to start data flow into correct indexes
        container "ifexists" "fluent-bit" && container "start" "fluent-bit"
    fi

    # initialize first indexes if they do not exists / if they exist then rollover to next
    if [[ $1 == "initialize" ]]; then
        # check master1
        check "elastic"; local status=$?; if [[ $status -ne 0 ]]; then s 1; return 1; fi
        
        # get master1 address
        local MASTER_IP=$(sudo docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' master1)
        printf "✅  Elastic master1 is running.\n"

        # stop fluent-bit if running to prevent false indexes
        container "ifexists" "fluent-bit" && container "stop" "fluent-bit"
        
        # iterate through index names
        for TEMPLATE_PATH in "$ELASTIC_PATH"/*.jsonc; do
            TEMPLATE_NAME=$(basename "$TEMPLATE_PATH" .jsonc)

            printf "⚙️  ${G}Initiating index => ${C}$TEMPLATE_NAME\n"

            # check if there are any indices for this template
            idx_count=$(curl -s "http://$MASTER_IP:9200/_cat/indices/${TEMPLATE_NAME}-*" | wc -l)

            if [[ "$idx_count" -eq 0 ]]; then
                printf "⚠️  ${Y}No index found → bootstrapping first index (000001) for ${C}$TEMPLATE_NAME\n"

                # create initial index with date math (URL encoded)
                q curl -s -XPUT "http://$MASTER_IP:9200/%3C${TEMPLATE_NAME}-%7Bnow%2Fd%7D-000001%3E" \
                  -H 'Content-Type: application/json' -d "{
                    \"settings\": {
                      \"index.lifecycle.name\": \"vectra-metadata-policy\",
                      \"index.lifecycle.rollover_alias\": \"$TEMPLATE_NAME\"
                    },
                    \"aliases\": {
                      \"$TEMPLATE_NAME\": { \"is_write_index\": true }
                    }
                  }"

                # force UTC date (ES {now/d} uses UTC internally)
                today=$(date -u +%Y.%m.%d)
                expected="${TEMPLATE_NAME}-${today}-000001"

                # verify creation
                if curl -s "http://$MASTER_IP:9200/_cat/indices/${expected}" | grep -q "${expected}";   then
                    printf "✅  ${G}Bootstrapped $TEMPLATE_NAME → ${C}$expected"
                else
                    # fallback: look for any -000001 index for this template
                    created=$(q curl -s "http://$MASTER_IP:9200/_cat/indices/${TEMPLATE_NAME}-*" | awk  '{print $3}' | grep "${TEMPLATE_NAME}-.*-000001" | head -n1)
                    if [[ -n "$created" ]]; then
                        printf "✅  Bootstrapped ${Y}$TEMPLATE_NAME → ${C}$created (detected by fallback)\n"
                    else
                        printf "⚠️  Failed to verify bootstrap for ${Y}$TEMPLATE_NAME\n"
                    fi
                fi
            else
                printf "⏳ Existing index(es) found → forcing rollover for ${Y}$TEMPLATE_NAME\n"

                q curl -s -XPOST "http://$MASTER_IP:9200/$TEMPLATE_NAME/_rollover" \
                    -H 'Content-Type: application/json' -d '{
                      "conditions": {}
                    }'

                # verify rollover
                latest=$(curl -s "http://$MASTER_IP:9200/_cat/indices/${TEMPLATE_NAME}-*" | awk '   {print $3}' |  sort | tail -n1)
                if [[ -n "$latest" ]]; then
                    printf "✅ Rolled over ${Y}$TEMPLATE_NAME → ${C}$latest"
                else
                    printf "⚠️ Failed to verify rollover for ${Y}$TEMPLATE_NAME"
                fi
            fi
            printf "\n\n"
        done
        # start fluent-bit to start data flow into correct indexes
        container "ifexists" "fluent-bit" && container "start" "fluent-bit"
    fi

    if [[ $1 == "kibana" ]]; then
        # check kibana and get kibana address
        check "kibana"; local status=$?; if [[ $status -ne 0 ]]; then s 1; return 1; fi
        local KIBANA_IP=$(sudo docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' kibana)

        printf "📝  ${Y}Importing Kibana Saved Objects...⏳\n"
        for filename in $(ls -S "$KIBANA_PATH"/*.ndjson | tac); do
            printf "📝  ${Y}Importing Object: ${C}$filename${N}\n"
            # check erros in saved objects
            if [[ "$filename" == *AIO* ]]; then
                local tmp=$(mktemp --suffix=".ndjson")
                cat "$filename" > "$tmp"
                sed -i "/Cognito - TTP - SSL - Hafnium/d" "$tmp"
                filename="$tmp"
            fi
            q curl -s -XPOST http://$KIBANA_IP:5601/api/saved_objects/_import?overwrite=true -H 'kbn-xsrf: true' --form file=@$filename
        done
        rm -fr /tmp/tmp.ndjson /tmp/kibana.ndjson

        printf "📝  ${G}Importing Kibana Saved Objects...✅\n"
        printf "\n💡 ${R}You must check the imported dashboards, queries and views\n"
        printf "💡 ${R}from ${Y}Stack Management => Saved Objects (Main Menu)${R}.\n"
        printf "💡 ${R}Feel free to re-import manually if something is missing\n"
    fi

    # combination for set usage
    if [[ "$1" == "all" ]]; then
        vectra "get"
        vectra "elastic"
        vectra "initialize"
        vectra "kibana" 
    fi
}

# main execution
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    # if script is run directly, show main menu
    menu "main"
fi