#!/bin/sh
export VMID=8100 
export VMNAME="node01"
export ISCSI_STORE="truenas-node01" 
export IPADDR="192.168.100.11/24" 
export GATEWAY="192.168.100.1" 
export DNS="192.168.100.1" 
export CIUSER="cesar" 
export CIPASSWORD="supersecret"
./create_instances.sh

export VMID=8200 
export VMNAME="node02"
export ISCSI_STORE="truenas-node02" 
export IPADDR="192.168.100.12/24" 
./create_instances.sh

export VMID=8300
export VMNAME="node03"
export ISCSI_STORE="truenas-node03"
export IPADDR="192.168.100.13/24"
./create_instances.sh