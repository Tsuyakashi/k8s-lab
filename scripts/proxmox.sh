#!/bin/bash

set -e

if ! pveum role list | grep -q "TerraformProv"; then
    pveum role add TerraformProv -privs \
    "VM.Allocate \
    VM.Clone \
    VM.Config.Disk \
    VM.Config.CPU \
    VM.Config.Memory \
    VM.Config.Network \
    VM.Config.Options \
    VM.Config.CDROM \
    VM.Config.Cloudinit \
    VM.Config.HWType \
    VM.Migrate \
    VM.PowerMgmt \
    VM.Audit \
    VM.Console \
    VM.GuestAgent.Audit \
    Datastore.AllocateSpace \
    Datastore.Allocate \
    Datastore.AllocateTemplate \
    Datastore.Audit \
    SDN.Use \
    SDN.Allocate" 
else
    pveum role modify TerraformProv -privs \
    "VM.Allocate \
    VM.Clone \
    VM.Config.Disk \
    VM.Config.CPU \
    VM.Config.Memory \
    VM.Config.Network \
    VM.Config.Options \
    VM.Config.CDROM \
    VM.Config.Cloudinit \
    VM.Config.HWType \
    VM.Migrate \
    VM.PowerMgmt \
    VM.Audit \
    VM.Console \
    VM.GuestAgent.Audit \
    Datastore.AllocateSpace \
    Datastore.Allocate \
    Datastore.AllocateTemplate \
    Datastore.Audit \
    SDN.Use \
    SDN.Allocate"
fi
