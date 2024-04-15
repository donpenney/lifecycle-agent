#!/bin/bash
#
# This utility is installed by the lifecycle-agent during an upgrade to handle
# the scenario where control plane certificates are expired on the original stateroot
# when rolling back. It is setup as a service-unit in the original stateroot during
# the LCA pre-pivot upgrade handler so that it only runs on a rollback, and is removed
# by the LCA rollback completion handler.
#
# From the original stateroot point of view, a rollback effectively just a recovery from
# having the node out-of-service for a possibly extended period of time. Especially when
# running an IBU within the first 24 hours of deploying a cluster, this means the control
# plane certificates for the original release may be expired when the rollback is triggered.
#
# Once launched, this utility will poll for Pending CSRs and approve them. This will ensure
# the control plane will be able to recover and schedule pods, allowing LCA to then complete
# the rollback. The LCA rollback completion handler will then shutdown, disable, and delete
# this service-unit and script.
#
# For reference on approving pending CSRs, see:
# https://access.redhat.com/documentation/en-us/openshift_container_platform/4.15/html/machine_management/adding-rhel-compute#installation-approve-csrs_adding-rhel-compute
#
# Reference on recovering from expired control plane certificates:
# https://docs.openshift.com/container-platform/4.15/backup_and_restore/control_plane_backup_and_restore/disaster_recovery/scenario-3-expired-certs.html

declare PROG=
PROG=$(basename "$0")

# shellcheck source=/dev/null
source /etc/kubernetes/static-pod-resources/etcd-certs/configmaps/etcd-scripts/etcd-common-tools

function log {
    echo "${PROG}: $*" >&2
}

#
# Get the node name from node CR metadata
#
function get_node_name {
    local nodename=
    while :; do
        nodename=$(oc get node -o jsonpath='{.items[].metadata.name}' 2>/dev/null)
        if [ -n "${nodename}" ]; then
            echo "${nodename}"
            return 0
        fi
        sleep 20
    done
}

#
# Get the node IP from node CR status
#
function get_node_ip {
    local nodeip=
    while :; do
        nodeip=$(oc get node -o json 2>/dev/null | jq -r '.items[] | .status.addresses[] | select(.type=="InternalIP") | .address')
        if [ -n "${nodeip}" ] && [ "${nodeip}" != "null" ]; then
            echo "${nodeip}"
            return 0
        fi
        sleep 20
    done
}

#
# Transform an IPv6 to an expanded format, in uppercase, without leading zeroes
# For example
# - abcd:e::43:2 becomes ABCD:E:0:0:0:0:0:2
# - 1:2:3:: becomes 1:2:3:0:0:0:0:0
#
function expanded_ipv6 {
    #
    # The IPv6 format allows for a compressed format, where:
    # - Starting or ending with : indicates the first or last value is 0
    # - Consecutive 0s can be compressed with :: (but only once)
    #
    # Using : as the field-separator in awk, then, we can look for empty fields and replace with 0.
    # For midpoint replacement, we pad out to 8 fields if needed
    #
    echo "$1" | awk ' {
        missing=8-NF
        for (i=1;i<=NF;i++) {
            if ($i == "") {
                $i="0"
                if (i != 1 && i != NF) {
                    for (j=1;j<=missing;j++) {
                        $i = $i ":0"
                    }
                }
            }
        }
        print toupper($0)
    } ' FS=: OFS=:
}

#
# get_system_node_csr_expected_san returns the expected SAN for system node CSR
#
function get_system_node_csr_expected_san {
    local nodename="$1"; shift
    local nodeip=
    nodeip=$(get_node_ip)

    if [[ "${nodeip}" =~ /:/ ]]; then
        # The SAN uses an expanded IPv6 format
        nodeip=$(expanded_ipv6 "${nodeip}")
    fi

    echo "DNS:${nodename}, IP Address:${nodeip}"
}

#
# Get the full list of pending CSRs, filtered by specific values
#
function get_pending_csrs {
    local signerName="$1"; shift
    local username="$1"; shift
    local expected_groups="$1"; shift
    local expected_usages="$1"; shift

    oc get csr -o json 2>/dev/null \
        | jq -c --arg signerName "${signerName}" --arg username "${username}" \
            --argjson expected_groups "${expected_groups}" --argjson expected_usages "${expected_usages}" \
                '.items[]
                    | select(.status=={}
                        and .spec.signerName==$signerName
                        and .spec.username==$username
                        and .spec.groups==$expected_groups
                        and .spec.usages==$expected_usages
                    )'
}

#
# Approve pending CSRs that match specified criteria
#
function approve_csrs {
    local signerName="$1"; shift
    local username="$1"; shift
    local expected_groups="$1"; shift
    local expected_usages="$1"; shift
    local expected_subject="$1"; shift
    local expected_san="$1"; shift

    local approved_count=0
    local csr=
    local csrtimestamp=
    local csrtimestampsecs=
    local csrname=
    local csrjson=
    local csrsubject=
    local csrsan=

    local init_timestamp=
    init_timestamp=$(stat -c %Z /proc)

    while :; do
        approved_count=0
        while read -r csrjson; do
            csrname=$(echo "${csrjson}" | jq -r '.metadata.name')

            # Get the CSR creation timestamp
            csrtimestamp=$(echo "${csrjson}" | jq -r '.metadata.creationTimestamp //0')
            if [ -z "${csrtimestamp}" ] || [ "${csrtimestamp}" = "0" ]; then
                # Timestamp was invalid or missing, so ignore the CSR
                continue
            fi

            # If CSR was created during previous boot, skip it
            csrtimestampsecs=$(date +%s --date="${csrtimestamp}" 2>/dev/null)
            if [ -z "${csrtimestampsecs}" ] || [ "${csrtimestampsecs}" -lt "${init_timestamp}" ]; then
                continue
            fi

            # Validate the Subject and SAN values from the request
            csr=$(echo "${csrjson}" | jq -r '.spec.request' | base64 -d)
            csrsubject=$(echo "${csr}" | openssl req -noout -subject)
            csrsan=$(echo "${csr}" | openssl req -noout -text | sed --quiet '/X509v3 Subject Alternative Name/{n;s/^ *//;p;}')

            if [ "${csrsubject}" != "${expected_subject}" ] \
                || [ "${csrsan}" != "${expected_san}" ]; then
                # Not a match. Skip it
                continue
            fi

            log "Approving CSR: ${csrname}"
            if oc adm certificate approve "${csrname}"; then
                approved_count=$((approved_count+1))
            else
                log "Failed to approve CSR: ${csrname}"
            fi
        done < <( get_pending_csrs "${signerName}" "${username}" "${expected_groups}" "${expected_usages}" )

        if [ ${approved_count} -gt 0 ]; then
            return 0
        else
            sleep 20
        fi
    done
}

#
# Approve pending node-bootstrapper CSR(s)
#
function approve_node_bootstrapper_csr {
    local nodename="$1"; shift

    local signerName="kubernetes.io/kube-apiserver-client-kubelet"
    local username="system:serviceaccount:openshift-machine-config-operator:node-bootstrapper"

    local expected_groups='["system:serviceaccounts","system:serviceaccounts:openshift-machine-config-operator","system:authenticated"]'
    local expected_usages='["digital signature","client auth"]'
    local expected_subject="subject=O = system:nodes, CN = system:node:${nodename}"
    local expected_san=''

    approve_csrs "${signerName}" "${username}" "${expected_groups}" "${expected_usages}" "${expected_subject}" "${expected_san}"
}

#
# Approve pending system node CSR(s)
#
function approve_system_node_csr {
    local nodename="$1"

    local signerName="kubernetes.io/kubelet-serving"
    local username="system:node:${nodename}"

    local expected_groups='["system:nodes","system:authenticated"]'
    local expected_usages='["digital signature","server auth"]'
    local expected_subject="subject=O = system:nodes, CN = system:node:${nodename}"

    local expected_san=
    expected_san=$(get_system_node_csr_expected_san "${nodename}")

    approve_csrs "${signerName}" "${username}" "${expected_groups}" "${expected_usages}" "${expected_subject}" "${expected_san}"
}

#
# Main procedure
#

# Get the cluster node name
nodename=$(get_node_name)

#
# Check the expiry time of the control plane certificates. If they have expired (or soon will),
# watch for and approve the corresponding CSRs that will be created by kubelet.
#
kube_client_cert=/var/lib/kubelet/pki/kubelet-client-current.pem
if ! openssl x509 -in ${kube_client_cert} -noout -enddate -checkend 1200 &>/dev/null ; then
    # The kubelet-client certificate has expired, so we should see a node-bootstrapper CSR.
    # Approving this CSR allows scheduling of pods.
    log "kubelet-client certificate expiry: $(openssl x509 -in ${kube_client_cert} -noout -enddate)"
    approve_node_bootstrapper_csr "${nodename}"
else
    log "kubelet-client certificate is valid"
fi

kube_server_cert=/var/lib/kubelet/pki/kubelet-server-current.pem
if ! openssl x509 -in ${kube_server_cert} -noout -enddate -checkend 1200 &>/dev/null ; then
    # The kubelet-server certificate has expired, so we should see a system node CSR.
    log "kubelet-server certificate expiry: $(openssl x509 -in ${kube_server_cert} -noout -enddate)"
    approve_system_node_csr "${nodename}"
else
    log "kubelet-server certificate is valid"
fi

exit 0

