#!/bin/sh

###################################################################
# Script Name   : provision-eks-cluster.sh
# Description   : For managing EKS clusters
# Author        : Kasun Talwatta
# Email         : kasun.talwatta@solo.io
###################################################################

set -e
set -o pipefail

_filename="$(basename $BASH_SOURCE)"

DEFAULT_NODE_NUM="1"
DEFAULT_REGION="ap-southeast-1"
DEFAULT_INSTANCE_TYPE="t3.medium"
DEFAULT_CLUSTER_VERSION="1.21"

OWNER=""
NODE_NUM=""
CLUSTER_NAME_SUFFIX=""
CLUSTER_VERSION=""
ZONE=""
ZONE_OPTION=""
REGION=""

# Display usage message function
usage() {
    echo "=================="
    echo "Usage:"
    echo "=================="
    echo "$_filename -h                                                                                                          Display this usage message"
    echo ""
    echo "$_filename create -o <arg> -n <arg> [-a <arg> -m <arg> -r <arg> -v <arg> -z <arg>] ................................... Provisioning a EKS cluster"
    echo "\tRequired arguments:"
    echo "\t-n   Name of the cluster (Uses as the suffix for the name)"
    echo "\t-o   Name of the cluster owner"
    echo "\tOptional arguments:"
    echo "\t-a - Number of nodes (Default 1 if not specified)"
    echo "\t-m   Instance type (Default t3.medium if not specified)"
    echo "\t-r   Region (Default ap-southeast-1 if not specified)"
    echo "\t-v   Kubernetes version"
    echo "\t-z   Zone (If provided will be allocated to the specified zone)"
    echo ""
    echo "$_filename delete -o <arg> -n <arg> [-r <arg> -z <arg>] .............................................................. Deleting a EKS cluster"
    echo "\tRequired arguments:"
    echo "\t-n   Suffix of the cluster name (Uses a combination of owner and suffix to make up the actual name)"
    echo "\t-o   Name of the cluster owner"
    echo "\tOptional arguments:"
    echo "\t-r   Region (Default ap-southeast-1 if not specified)"
}

# Utility function to create a cluster
create_cluster() {
    echo "Creating cluster $1-$2 with $6 nodes of type $5"

    cat <<EOF | eksctl create cluster $7 -f -
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig

metadata:
  # this is the name of the cluster
  name: "${1}-${2}"
  region: "${4}"
  version: "${3}"
  tags:
    # You can customize your own tags
    Owner: "${1}"

nodeGroups:
  - name: default-pool
    instanceType: "${5}"
    desiredCapacity: ${6}
    volumeSize: 20
    tags:
      cluster: "${1}-${2}"
    ssh:
      allow: true
EOF
}

# Utility function to delete a cluster
delete_cluster() {
    echo "Deleting cluster $1-$2"
    eksctl delete cluster -n "$1-$2" -r $3
}

[ $# -eq 0 ] && usage && exit 1

while getopts ":h" opt; do # Go through the options
    case $opt in
        h ) # Help
            usage
            exit 0 # Exit correctly
        ;;
        ? ) # Invalid option
            echo "[ERROR]: Invalid option: -${OPTARG}"
            usage
            exit 1
        ;;
    esac
done
shift $((OPTIND-1))
subcommand=$1; shift
case "$subcommand" in
    create )
        unset OPTIND
        [ $# -eq 0 ] && usage && exit 1
        while getopts ":a:m:n:o:r:v:z:" opt; do
            case $opt in
                a )
                    NODE_NUM=$OPTARG
                ;;
                m )
                    INSTANCE_TYPE=$OPTARG
                ;;
                n )
                    CLUSTER_NAME_SUFFIX=$OPTARG
                ;;
                o )
                    OWNER=$OPTARG
                ;;
                r )
                    REGION=$OPTARG
                ;;
                v )
                    CLUSTER_VERSION=$OPTARG
                ;;
                z )
                    ZONE=$OPTARG
                ;;
                : ) # Catch no argument provided
                        echo "[ERROR]: option -${OPTARG} requires an argument"
                        usage
                        exit 1
                ;;
                ? ) # Invalid option
                        echo "[ERROR]: Invalid option: -${OPTARG}"
                        usage
                        exit 1
                ;;
            esac
        done

        if [ -z $OWNER ] || [ -z $CLUSTER_NAME_SUFFIX ]; then
            echo "[ERROR]: Both -o and -n are required"
            usage
            exit 1
        fi

        if [ ! -z $ZONE ]; then
            ZONE_OPTION="--zone $ZONE"
        else
            ZONE_OPTION=" "
        fi

        shift $((OPTIND-1))

        NODE_NUM=${NODE_NUM:-$DEFAULT_NODE_NUM}
        REGION=${REGION:-$DEFAULT_REGION}
        CLUSTER_VERSION=${CLUSTER_VERSION:-$DEFAULT_CLUSTER_VERSION}
        INSTANCE_TYPE=${INSTANCE_TYPE:-$DEFAULT_INSTANCE_TYPE}

        create_cluster $OWNER $CLUSTER_NAME_SUFFIX $CLUSTER_VERSION $REGION $INSTANCE_TYPE $NODE_NUM $ZONE_OPTION
    ;;
    delete )
        unset OPTIND
        [ $# -eq 0 ] && usage && exit 1
        while getopts ":n:o:r:" opt; do
            case $opt in
                n )
                    CLUSTER_NAME_SUFFIX=$OPTARG
                ;;
                o )
                    OWNER=$OPTARG
                ;;
                r )
                    REGION=$OPTARG
                ;;
                : ) # Catch no argument provided
                        echo "[ERROR]: option -${OPTARG} requires an argument"
                        usage
                        exit 1
                ;;
                ? ) # Invalid option
                        echo "[ERROR]: Invalid option: -${OPTARG}"
                        usage
                        exit 1
                ;;
            esac
        done

        if [ -z $OWNER ] || [ -z $CLUSTER_NAME_SUFFIX ]; then
            echo "[ERROR]: Both -o and -n are required"
            usage
            exit 1
        fi

        shift $((OPTIND-1))

        REGION=${REGION:-$DEFAULT_REGION}

        delete_cluster $OWNER $CLUSTER_NAME_SUFFIX $REGION
    ;;
    * ) # Invalid subcommand
        if [ ! -z $subcommand ]; then
            echo "Invalid subcommand: $subcommand"
        fi
        usage
        exit 1
    ;;
esac