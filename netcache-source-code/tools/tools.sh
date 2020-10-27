#!/bin/bash

# update parameters
PCI_PATH="05:00.1"
WORKDIR=/media/sf_in-network-service/kvsrc/netcache

# fixed parameters
Pages=2048
HUGEPGSZ=`cat /proc/meminfo  | grep Hugepagesize | cut -d : -f 2 | tr -d ' '`

#
# Unloads igb_uio.ko.
#
remove_igb_uio_module()
{
    echo "Unloading any existing DPDK UIO module"
    /sbin/lsmod | grep -s igb_uio > /dev/null
    if [ $? -eq 0 ] ; then
        sudo /sbin/rmmod igb_uio
    fi
}

#
# Loads new igb_uio.ko (and uio module if needed).
#
load_igb_uio_module()
{
    if [ ! -f $RTE_SDK/$RTE_TARGET/kmod/igb_uio.ko ];then
        echo "## ERROR: Target does not have the DPDK UIO Kernel Module."
        echo "       To fix, please try to rebuild target."
        return
    fi

    remove_igb_uio_module

    /sbin/lsmod | grep -s uio > /dev/null
    if [ $? -ne 0 ] ; then
        modinfo uio > /dev/null
        if [ $? -eq 0 ]; then
            echo "Loading uio module"
            sudo /sbin/modprobe uio
        fi
    fi

    # UIO may be compiled into kernel, so it may not be an error if it can't
    # be loaded.

    echo "Loading DPDK UIO module"
    sudo /sbin/insmod $RTE_SDK/$RTE_TARGET/kmod/igb_uio.ko
    if [ $? -ne 0 ] ; then
        echo "## ERROR: Could not load kmod/igb_uio.ko."
        quit
    fi
}

#
# Creates hugepage filesystem.
#
create_mnt_huge()
{
    echo "Creating /mnt/huge and mounting as hugetlbfs"
    sudo mkdir -p /mnt/huge

    grep -s '/mnt/huge' /proc/mounts > /dev/null
    if [ $? -ne 0 ] ; then
        sudo mount -t hugetlbfs nodev /mnt/huge
    fi
}

#
# Removes hugepage filesystem.
#
remove_mnt_huge()
{
    echo "Unmounting /mnt/huge and removing directory"
    grep -s '/mnt/huge' /proc/mounts > /dev/null
    if [ $? -eq 0 ] ; then
        sudo umount /mnt/huge
    fi

    if [ -d /mnt/huge ] ; then
        sudo rm -R /mnt/huge
    fi
}

#
# Removes all reserved hugepages.
#
clear_huge_pages()
{
    echo > .echo_tmp
    for d in /sys/devices/system/node/node? ; do
        echo "echo 0 > $d/hugepages/hugepages-${HUGEPGSZ}/nr_hugepages" >> .echo_tmp
    done
    echo "Removing currently reserved hugepages"
    sudo sh .echo_tmp
    rm -f .echo_tmp

    remove_mnt_huge
}

#
# Creates hugepages on specific NUMA nodes.
#
set_numa_pages()
{
    clear_huge_pages

    echo > .echo_tmp
    for d in /sys/devices/system/node/node? ; do
        node=$(basename $d)
        echo "echo $Pages > $d/hugepages/hugepages-${HUGEPGSZ}/nr_hugepages" >> .echo_tmp
    done
    echo "Reserving hugepages"
    sudo sh .echo_tmp
    rm -f .echo_tmp

    create_mnt_huge
}

#
# Uses dpdk-devbind.py to move devices to work with igb_uio
#
bind_devices_to_igb_uio()
{
    if [ -d /sys/module/igb_uio ]; then
        echo "Bind device to DPDK"
        sudo $RTE_SDK/tools/dpdk-devbind.py -b igb_uio $PCI_PATH
        #${RTE_SDK}/tools/dpdk-devbind.py --status
    else
        echo "# Please load the 'igb_uio' kernel module before querying or "
        echo "# adjusting device bindings"
    fi
}

install_dpdk() {
    cd ~
    rm -rf dpdk
    mkdir dpdk
    cd dpdk
    wget http://fast.dpdk.org/rel/dpdk-16.11.1.tar.gz
    tar xf dpdk-16.11.1.tar.gz
    cd dpdk-stable-16.11.1
    make install T=x86_64-native-linuxapp-gcc DESTDIR=$HOME/dpdk/dpdk-stable-16.11.1
    echo export\ RTE_SDK=$HOME/dpdk/dpdk-stable-16.11.1 >> $HOME/.bash_profile
    echo export\ RTE_TARGET=x86_64-native-linuxapp-gcc >> $HOME/.bash_profile
    source ~/.bash_profile
}

show_device() {
    $RTE_SDK/tools/dpdk-devbind.py --status
}

setup_dpdk() {
    # insert Insert IGB UIO module
    load_igb_uio_module

    # set hugepage mapping
    set_numa_pages

    # bind device
    bind_devices_to_igb_uio
}

unbind_dpdk() {
    sudo ${RTE_SDK}/tools/dpdk-devbind.py -u $PCI_PATH
    sudo ${RTE_SDK}/tools/dpdk-devbind.py -b i40e $PCI_PATH
}

clean_netcache() {
    rm -rf $WORKDIR/build
    rm -rf $WORKDIR/*/build
    rm -rf $WORKDIR/cluster/client/build
    rm -rf $WORKDIR/cluster/client_master/build
    rm -rf $WORKDIR/cluster/client_slave/build
    rm -rf $WORKDIR/cluster/backend/build
    rm -rf $WORKDIR/*/lib
    rm -f $WORKDIR/.DS_Store
    rm -f $WORKDIR/*/.DS_Store
}

init_netcache() {
    clean_netcache

    rm -rf $WORKDIR/result
    mkdir $WORKDIR/result

    cd $WORKDIR/simulator
    make
    ./build/simulator -m 2 > hot_key_hash_100K
    mv hot_key_hash_100K $WORKDIR/result

    cd $WORKDIR/trace
    make
    ./build/trace -z 99 > trace_zipf_99_key_1M_len_10M
    mv trace_zipf_99_key_1M_len_10M $WORKDIR/result
}

run_client() {
    cd $WORKDIR/cluster/client
    make
    cd $WORKDIR/result
    sudo $WORKDIR/cluster/client/build/client -l 0,2 -- -z 99 -k 64 -m 10000
}

run_client_master() {
    cd $WORKDIR/cluster/client
    make
    cd $WORKDIR/result
    sudo $WORKDIR/cluster/client_master/build/client -l 0,2 -- -z 99 -k 64 -m 10000
}

run_client_slave() {
    cd $WORKDIR/cluster/client
    make
    cd $WORKDIR/result
    sudo $WORKDIR/cluster/client_slave/build/client -l 0,2 -- -z 99 -k 64 -m 10000
}

run_backend() {
    cd $WORKDIR/cluster/backend
    make
    cd $WORKDIR/result
    sudo $WORKDIR/cluster/backend/build/backend -l 0 -- -m 10000
}

option="${1}"
case ${option} in
    install_dpdk)
        install_dpdk
        ;;
    show_device)
        show_device
        ;;
    setup_dpdk)
        setup_dpdk
        ;;
    init_netcache)
        init_netcache
        ;;
    clean_netcache)
        clean_netcache
        ;;
    run_client)
        run_client
        ;;
    run_backend)
        run_backend
        ;;
    *)  echo "usage:"
        echo "  ./tools.sh install_dpdk: install dpdk"
        echo "  ./tools.sh show_device: show device"
        echo "  ./tools.sh setup_dpdk: setup dpdk"
        echo "  ./tools.sh init_netcache: init netcache"
        echo "  ./tools.sh clean_netcache: clean netcache"
        echo "  ./tools.sh run_client: run client"
        echo "  ./tools.sh run_backend: run backend"
esac
