#!/bin/sh

start() {
    # 停止自带 irqbalance
    if [ -x /etc/init.d/irqbalance ]; then
        /etc/init.d/irqbalance stop 2>/dev/null
        /etc/init.d/irqbalance disable 2>/dev/null
    fi
    killall irqbalance 2>/dev/null

    # 动态获取 CPU 核心数 (兼容没有 nproc 的系统)
    cores=$(grep -c ^processor /proc/cpuinfo)
    all_mask=$(printf "%x" $(( (1 << cores) - 1 )))

    # ---------- 硬件中断绑定 ----------
    # WAN (eth0) 所有中断 -> CPU0 (PPPoE RSS 无效，集中处理)
    for irq in $(grep -E "eth0-TxRx" /proc/interrupts | awk -F: '{print $1}' | tr -d ' '); do
        echo "1" > "/proc/irq/$irq/smp_affinity" 2>/dev/null
    done

    # LAN (eth1) 轮询 1:1 绑定
    cpu=0
    for irq in $(grep -E "eth1-TxRx" /proc/interrupts | awk -F: '{print $1}' | tr -d ' '); do
        printf "%x" $((1 << cpu)) > "/proc/irq/$irq/smp_affinity" 2>/dev/null
        cpu=$(( (cpu + 1) % cores ))
    done

    # ---------- 队列 RPS / XPS ----------
    q=0
    while [ $q -lt $cores ]; do
        mask=$(printf "%x" $((1 << q)))

        # LAN (eth1) 完美 1:1
        [ -f "/sys/class/net/eth1/queues/rx-$q/rps_cpus" ] && echo "$mask" > "/sys/class/net/eth1/queues/rx-$q/rps_cpus"
        [ -f "/sys/class/net/eth1/queues/tx-$q/xps_cpus" ] && echo "$mask" > "/sys/class/net/eth1/queues/tx-$q/xps_cpus"

        # WAN (eth0) XPS 1:1, RPS 全开
        [ -f "/sys/class/net/eth0/queues/tx-$q/xps_cpus" ] && echo "$mask" > "/sys/class/net/eth0/queues/tx-$q/xps_cpus"
        [ -f "/sys/class/net/eth0/queues/rx-$q/rps_cpus" ] && echo "$all_mask" > "/sys/class/net/eth0/queues/rx-$q/rps_cpus"

        q=$((q + 1))
    done

    # pppoe-wan 如果已经存在（刚启动可能还没有）
    if [ -f /sys/class/net/pppoe-wan/queues/rx-0/rps_cpus ]; then
        echo "$all_mask" > /sys/class/net/pppoe-wan/queues/rx-0/rps_cpus
    fi

    # ---------- RFS 全局设置 ----------
    echo 32768 > /proc/sys/net/core/rps_sock_flow_entries 2>/dev/null
    for iface in eth1 pppoe-wan; do
        for q in /sys/class/net/$iface/queues/rx-*; do
            echo 4096 > "$q/rps_flow_cnt" 2>/dev/null
        done
    done

    # ---------- 可选：ring buffer 与中断聚合 ----------
    ethtool -G eth0 rx 1024 tx 1024 2>/dev/null
    ethtool -G eth1 rx 1024 tx 1024 2>/dev/null
    ethtool -C eth0 rx-usecs 16 tx-usecs 16 2>/dev/null
    ethtool -C eth1 rx-usecs 16 tx-usecs 16 2>/dev/null
}

stop() {
    :
}

start
