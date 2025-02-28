#!/usr/bin/env bash

# Copyright 2021 The Rook Authors. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

KUBECTL="minikube kubectl --"
ROOK_EXAMPLES_DIR="../../deploy/examples/"

wait_for_ceph_cluster() {
    echo "Waiting for ceph cluster"
    WAIT_CEPH_CLUSTER_RUNNING=20
    while ! $KUBECTL get cephclusters.ceph.rook.io -n rook-ceph -o jsonpath='{.items[?(@.kind == "CephCluster")].status.ceph.health}' | grep -q "HEALTH_OK"; do
	echo "Waiting for Ceph cluster installed"
	sleep ${WAIT_CEPH_CLUSTER_RUNNING}
    done
    echo "Ceph cluster installed and running"
}

get_minikube_driver() {
    os=$(uname)
    architecture=$(uname -m)
    if [[ "$os" == "Darwin" ]]; then
        if [[ "$architecture" == "x86_64" ]]; then
            echo "hyperkit"
        elif [[ "$architecture" == "arm64" ]]; then
            echo "qemu"
        else
            echo "Unknown Architecture on Apple OS"
	    exit 1
        fi
    elif [[ "$os" == "Linux" ]]; then
        echo "kvm2"
    else
        echo "Unknown/Unsupported OS"
	exit 1
    fi
}

show_ceph_dashboard_info() {
    DASHBOARD_PASSWORD=$($KUBECTL -n rook-ceph get secret rook-ceph-dashboard-password -o jsonpath="{['data']['password']}" | base64 --decode && echo)
    IP_ADDR=$($KUBECTL get po --selector="app=rook-ceph-mgr" -n rook-ceph --output jsonpath='{.items[*].status.hostIP}')
    PORT="$($KUBECTL -n rook-ceph -o=jsonpath='{.spec.ports[?(@.name == "dashboard")].nodePort}' get services rook-ceph-mgr-dashboard-external-http)"
    BASE_URL="http://$IP_ADDR:$PORT"
    echo "==========================="
    echo "Ceph Dashboard: "
    echo "   IP_ADDRESS: $BASE_URL"
    echo "   PASSWORD: $DASHBOARD_PASSWORD"
    echo "==========================="
}

check_minikube_exists() {
    minikube profile list > /dev/null 2>&1
    local retcode=$?

    if [ $retcode -eq 0 ]; then
        echo "A minikube environment already exists, please use -f to force the cluster creation."
	exit 1
    fi
}

setup_minikube_env() {
    minikube_driver="$(get_minikube_driver)"
    echo "Setting up minikube env (using $minikube_driver driver)"
    minikube delete
    minikube start --disk-size=40g --extra-disks=3 --driver "$minikube_driver"
    eval "$(minikube docker-env -p minikube)"
}

create_rook_cluster() {
    echo "Creating cluster"
    $KUBECTL apply -f crds.yaml -f common.yaml -f operator.yaml
    $KUBECTL apply -f cluster-test.yaml -f toolbox.yaml
    $KUBECTL apply -f dashboard-external-http.yaml
}

check_examples_dir() {
    CRDS_FILE="crds.yaml"
    if [ ! -e ${CRDS_FILE} ]; then
	echo "File ${ROOK_EXAMPLES_DIR}/${CRDS_FILE} does not exist. Please, provide a valid rook examples directory."
	exit 1
    fi
}

wait_for_rook_operator() {
    echo "Waiting for rook operator"
    $KUBECTL rollout status deployment rook-ceph-operator -n rook-ceph --timeout=180s
    while ! $KUBECTL get cephclusters.ceph.rook.io -n rook-ceph -o jsonpath='{.items[?(@.kind == "CephCluster")].status.phase}' | grep -q "Ready"; do
	echo "Waiting for cluster to be ready..."
	sleep 20
    done
}

enable_rook_orchestrator() {
    echo "Enabling rook orchestrator"
    $KUBECTL rollout status deployment rook-ceph-tools -n rook-ceph --timeout=30s
    kubectl -n rook-ceph exec -it deploy/rook-ceph-tools -- ceph mgr module enable rook
    kubectl -n rook-ceph exec -it deploy/rook-ceph-tools -- ceph orch set backend rook
    kubectl -n rook-ceph exec -it deploy/rook-ceph-tools -- ceph orch status
}

show_usage() {
    echo ""
    echo " Usage: $(basename "$0") [-r] [-d /path/to/rook-examples/dir]"
    echo "  -r        Enable rook orchestrator"
    echo "  -d value  Path to Rook examples directory (i.e github.com/rook/rook/deploy/examples)"
}

####################################################################
################# MAIN #############################################

while getopts ":hrfd:" opt; do
    case $opt in
	h)
	    show_usage
	    exit 0
	    ;;
	r)
	    enable_rook=true
	    ;;
	f)
	    force_minikube=true
	    ;;
	d)
	    ROOK_EXAMPLES_DIR="$OPTARG"
	    ;;
	\?)
	    echo  "Invalid option: -$OPTARG" >&2
	    show_usage
	    exit 1
	    ;;
	:)
	    echo "Option -$OPTARG requires an argument." >&2
	    exit 1
	    ;;
    esac
done

echo "Using '$ROOK_EXAMPLES_DIR' as examples directory.."

cd "$ROOK_EXAMPLES_DIR" || exit
check_examples_dir

if [ -z "$force_minikube" ]; then
    check_minikube_exists
fi

setup_minikube_env
create_rook_cluster
wait_for_rook_operator
wait_for_ceph_cluster

if [ "$enable_rook" = true ]; then
    enable_rook_orchestrator
fi

show_ceph_dashboard_info

####################################################################
####################################################################
