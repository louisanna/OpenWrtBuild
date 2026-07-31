#!/bin/sh /etc/rc.common
START=99
USE_PROCD=1

start_service() {
    # 停止 irqbalance
    if [ -x /etc/init.d/irqbalance ]; then
        /etc/init.d/irqbalance stop 2>/dev/null
        /etc/init.d/irqbalance disable 2>/dev/null
    fi
    killall irqbalance 2>/dev/null

    cores=$(grep -c ^processor /proc/cpuinfo)
    all_mask=$(printf "%x" $(( (1 << cores) - 1 )))
    rps_mask_no_cpu0=$(printf "%x" $(( ((1 << cores) - 1) & ~1 )))

    # 硬件中断 1:1 绑定
    for iface in eth0 eth1; do
        cpu=0
        for irq in $(grep -E "${iface}-TxRx" /proc/interrupts | awk -F: '{print $1}' | tr -d ' '); do
            printf "%x" $((1 << cpu)) > "/proc/irq/$irq/smp_affinity" 2>/dev/null
            cpu=$(( (cpu + 1) % cores ))
        done
    done

    # 队列 RPS / XPS
    q=0
    while [ $q -lt $cores ]; do
        mask=$(printf "%x" $((1 << q)))
        # eth1 LAN: 1:1
        [ -f "/sys/class/net/eth1/queues/rx-$q/rps_cpus" ] && echo "$mask" > "/sys/class/net/eth1/queues/rx-$q/rps_cpus"
        [ -f "/sys/class/net/eth1/queues/tx-$q/xps_cpus" ] && echo "$mask" > "/sys/class/net/eth1/queues/tx-$q/xps_cpus"
        # eth0 WAN: XPS 1:1, RPS 排除 CPU0
        [ -f "/sys/class/net/eth0/queues/tx-$q/xps_cpus" ] && echo "$mask" > "/sys/class/net/eth0/queues/tx-$q/xps_cpus"
        [ -f "/sys/class/net/eth0/queues/rx-$q/rps_cpus" ] && echo "$rps_mask_no_cpu0" > "/sys/class/net/eth0/queues/rx-$q/rps_cpus"
        q=$((q + 1))
    done

    # RFS 全局流表 + eth1 队列
    echo 32768 > /proc/sys/net/core/rps_sock_flow_entries 2>/dev/null
    for q in /sys/class/net/eth1/queues/rx-*; do
        echo 4096 > "$q/rps_flow_cnt" 2>/dev/null
    done

    # ethtool 优化
    for iface in eth0 eth1; do
        ethtool -G $iface rx 1024 tx 1024 2>/dev/null
        ethtool -C $iface rx-usecs 16 tx-usecs 16 2>/dev/null
    done
}