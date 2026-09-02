#!/bin/sh

# ---------- 初始化（只执行一次） ----------
init_once() {
    # 等待 eth0 队列出现（最多300秒）
    i=0
    while [ ! -f /sys/class/net/eth0/queues/rx-0/rps_cpus ] && [ $i -lt 300 ]; do
        sleep 1
        i=$((i+1))
    done

    # 停止 irqbalance
    if [ -x /etc/init.d/irqbalance ]; then
        /etc/init.d/irqbalance stop 2>/dev/null
        /etc/init.d/irqbalance disable 2>/dev/null
    fi
    killall irqbalance 2>/dev/null

    # 计算掩码
    cores=$(grep -c ^processor /proc/cpuinfo)
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
        # eth1 LAN 1:1
        [ -f "/sys/class/net/eth1/queues/rx-$q/rps_cpus" ] && echo "$mask" > "/sys/class/net/eth1/queues/rx-$q/rps_cpus"
        [ -f "/sys/class/net/eth1/queues/tx-$q/xps_cpus" ] && echo "$mask" > "/sys/class/net/eth1/queues/tx-$q/xps_cpus"
        # eth0 WAN XPS 1:1, RPS 排除 CPU0
        [ -f "/sys/class/net/eth0/queues/tx-$q/xps_cpus" ] && echo "$mask" > "/sys/class/net/eth0/queues/tx-$q/xps_cpus"
        [ -f "/sys/class/net/eth0/queues/rx-$q/rps_cpus" ] && echo "$rps_mask_no_cpu0" > "/sys/class/net/eth0/queues/rx-$q/rps_cpus"
        q=$((q + 1))
    done

    # RFS 全局流表 + eth1
    echo 32768 > /proc/sys/net/core/rps_sock_flow_entries 2>/dev/null
    for q in /sys/class/net/eth1/queues/rx-*; do
        echo 4096 > "$q/rps_flow_cnt" 2>/dev/null
    done

    # ethtool 优化
    for iface in eth0 eth1; do
        ethtool -G $iface rx 1024 tx 1024 2>/dev/null
        ethtool -C $iface rx-usecs 16 tx-usecs 16 2>/dev/null
    done

    # 保存目标 RPS 值，供监控循环使用
    echo "$rps_mask_no_cpu0" > /tmp/.target_rps
}

# ---------- 监控循环（永远运行） ----------
monitor_loop() {
    while true; do
        [ -f /tmp/.target_rps ] || { sleep 3; continue; }
        TARGET_RPS=$(cat /tmp/.target_rps)        # 排除 CPU0 的 RPS 掩码，例如 e
        changed=0

        # ---- 修复 eth0 ----
        if [ -d /sys/class/net/eth0 ]; then
            q=0
            while [ -d "/sys/class/net/eth0/queues/rx-$q" ]; do
                # 修复 RPS（排除 CPU0）
                rps_file="/sys/class/net/eth0/queues/rx-$q/rps_cpus"
                if [ -f "$rps_file" ]; then
                    cur=$(cat "$rps_file")
                    [ "$cur" != "$TARGET_RPS" ] && echo "$TARGET_RPS" > "$rps_file" && changed=1
                fi
                # 修复 XPS（单核掩码）
                xps_file="/sys/class/net/eth0/queues/tx-$q/xps_cpus"
                if [ -f "$xps_file" ]; then
                    target_xps=$(printf "%x" $((1 << q)))      # 队列 q 对应 CPU q
                    cur=$(cat "$xps_file")
                    [ "$cur" != "$target_xps" ] && echo "$target_xps" > "$xps_file" && changed=1
                fi
                q=$((q+1))
            done
        fi

        # ---- 修复 eth1 ----
        if [ -d /sys/class/net/eth1 ]; then
            q=0
            while [ -d "/sys/class/net/eth1/queues/rx-$q" ]; do
                target_mask=$(printf "%x" $((1 << q)))        # 1:1 绑定，队列 q 对应 CPU q
                rps_file="/sys/class/net/eth1/queues/rx-$q/rps_cpus"
                [ -f "$rps_file" ] && [ "$(cat "$rps_file")" != "$target_mask" ] && echo "$target_mask" > "$rps_file" && changed=1
                xps_file="/sys/class/net/eth1/queues/tx-$q/xps_cpus"
                [ -f "$xps_file" ] && [ "$(cat "$xps_file")" != "$target_mask" ] && echo "$target_mask" > "$xps_file" && changed=1
                q=$((q+1))
            done
        fi

        # ---- 修复 pppoe-wan ----
        ppp_rps="/sys/class/net/pppoe-wan/queues/rx-0/rps_cpus"
        if [ -f "$ppp_rps" ]; then
            cur=$(cat "$ppp_rps")
            [ "$cur" != "$TARGET_RPS" ] && echo "$TARGET_RPS" > "$ppp_rps" && changed=1
        fi

        [ $changed -eq 1 ] && logger -t irq_guard "RPS/XPS corrected"
        sleep 3
    done
}

# 先初始化，然后进入守护循环
init_once
monitor_loop