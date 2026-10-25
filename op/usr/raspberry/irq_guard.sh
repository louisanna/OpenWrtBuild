#!/bin/sh
# irq_guard.sh - NIC queue/IRQ affinity and ring tuning for OpenWrt
#
# Design (4-core x86 router, igc NICs with 4 combined queues each):
#   * one hardware queue per CPU when queue count >= core count
#   * every NIC starts its round-robin at CPU1; CPU0 is only used when
#     all cores are needed (queue count >= cores), otherwise it is skipped
#   * RPS/RFS are disabled: with one queue per core they only add
#     cross-CPU IPIs and RFS tables get over-committed
#   * ring buffers raised to the hardware maximum (capped at 4096)
#   * affinity is reconciled every 30s because driver reload / ethtool -L
#     resets it silently
#
# Usage: irq_guard.sh [--status]

TAG="irq_guard"
INTERVAL=30
RING_TARGET=4096

log() { logger -t "$TAG" "$*" 2>/dev/null; }
uci_get() { uci -q get "$1" 2>/dev/null | head -n1; }

cores=$(grep -c '^processor' /proc/cpuinfo 2>/dev/null)
if [ -z "$cores" ] || [ "$cores" -lt 1 ]; then
	cores=1
fi
FAILED=""

write_if_changed() {
	file="$1"
	val="$2"
	[ -e "$file" ] || return 0
	cur=$(cat "$file" 2>/dev/null)
	[ "$cur" = "$val" ] && return 0
	printf '%s\n' "$val" > "$file" 2>/dev/null
}

hexmask() {
	printf '%x' $((1 << $1))
}

resolve_ifaces() {
	WAN_IF=$(uci_get network.wan.device)
	LAN_IF=$(uci_get network.lan.device)
	[ -n "$WAN_IF" ] || WAN_IF=eth0
	[ -n "$LAN_IF" ] || LAN_IF=eth1
}

# a LAN device may be a bridge; tune its physical ports instead
list_ports() {
	if [ -d "/sys/class/net/$1/brif" ]; then
		ls /sys/class/net/"$1"/brif 2>/dev/null
	else
		echo "$1"
	fi
}

wait_iface() {
	n=0
	while [ ! -d "/sys/class/net/$1" ]; do
		n=$((n + 1))
		[ "$n" -ge 300 ] && return 1
		sleep 1
	done
	return 0
}

# print "<queue-index> <irq>" for every queue interrupt of an interface
queue_irqs() {
	awk -v ifc="$1" '
		match($0, ifc "-(TxRx|rx|tx)-[0-9]+") {
			irq = $1
			sub(/:$/, "", irq)
			s = substr($0, RSTART, RLENGTH)
			sub(/.*-/, "", s)
			print s, irq
		}' /proc/interrupts
}

# map every RX queue of $1 onto a distinct CPU, starting at $2
bind_iface() {
	iface="$1"
	start="$2"
	[ -d "/sys/class/net/$iface/queues" ] || return 0

	nq=$(ls -d /sys/class/net/"$iface"/queues/rx-* 2>/dev/null | wc -l)
	[ "$nq" -eq 0 ] && return 0
	map=$(queue_irqs "$iface")

	for qd in /sys/class/net/"$iface"/queues/rx-*; do
		q=${qd##*-}
		if [ "$cores" -gt "$nq" ] && [ "$start" -eq 1 ] && [ "$cores" -gt 1 ]; then
			cpu=$((1 + (q % (cores - 1))))
		else
			cpu=$(((start + q) % cores))
		fi

		irq=$(echo "$map" | awk -v q="$q" '$1 == q { print $2; exit }')
		if [ -n "$irq" ]; then
			if ! write_if_changed "/proc/irq/$irq/smp_affinity_list" "$cpu"; then
				# transient EBUSY right after boot / driver reload
				sleep 1
				if ! write_if_changed "/proc/irq/$irq/smp_affinity_list" "$cpu"; then
					case " $FAILED " in
					*" $irq "*) ;;
					*) log "failed to set affinity irq=$irq cpu=$cpu iface=$iface"; FAILED="$FAILED $irq" ;;
					esac
				fi
			fi
		fi

		tx="/sys/class/net/$iface/queues/tx-$q"
		[ -d "$tx" ] && write_if_changed "$tx/xps_cpus" "$(hexmask "$cpu")"
	done
}

tune_sysctl() {
	write_if_changed /proc/sys/net/core/netdev_max_backlog 10000
	write_if_changed /proc/sys/net/core/netdev_budget 600
}

tune_ring() {
	iface="$1"
	[ -x /usr/sbin/ethtool ] || return 0

	max_rx=$(ethtool -g "$iface" 2>/dev/null |
		awk '/Pre-set maximums:/ { f=1; next } /Current hardware settings:/ { f=0 } f && $1 == "RX:" { print $2 }')
	max_tx=$(ethtool -g "$iface" 2>/dev/null |
		awk '/Pre-set maximums:/ { f=1; next } /Current hardware settings:/ { f=0 } f && $1 == "TX:" { print $2 }')

	if [ -n "$max_rx" ]; then
		[ "$max_rx" -lt "$RING_TARGET" ] && rx="$max_rx" || rx="$RING_TARGET"
		ethtool -G "$iface" rx "$rx" >/dev/null 2>&1
	fi
	if [ -n "$max_tx" ]; then
		[ "$max_tx" -lt "$RING_TARGET" ] && tx="$max_tx" || tx="$RING_TARGET"
		ethtool -G "$iface" tx "$tx" >/dev/null 2>&1
	fi
}

# igc rejects rx-usecs, so only touch it when the hardware accepts it
tune_coalesce() {
	iface="$1"
	ethtool -c "$iface" 2>/dev/null | grep -q 'rx-usecs' || return 0
	ethtool -C "$iface" rx-usecs 16 tx-usecs 16 >/dev/null 2>&1 ||
		log "coalescing not supported on $iface, kept driver default"
}

disable_rps() {
	write_if_changed /proc/sys/net/core/rps_sock_flow_entries 0
	for iface in "$@"; do
		for qd in /sys/class/net/"$iface"/queues/rx-*; do
			write_if_changed "$qd"/rps_flow_cnt 0
			write_if_changed "$qd"/rps_cpus 0
		done
	done
}

status() {
	resolve_ifaces
	echo "irq_guard: cores=$cores interval=${INTERVAL}s"
	echo "wan=$WAN_IF lan=$LAN_IF"
	for iface in $(list_ports "$WAN_IF") $(list_ports "$LAN_IF"); do
		[ -d "/sys/class/net/$iface/queues" ] || continue
		echo "--- $iface ---"
		map=$(queue_irqs "$iface")
		for qd in /sys/class/net/"$iface"/queues/rx-*; do
			q=${qd##*-}
			irq=$(echo "$map" | awk -v q="$q" '$1 == q { print $2; exit }')
			aff=$(cat "/proc/irq/$irq/smp_affinity_list" 2>/dev/null)
			rps=$(cat "$qd/rps_cpus" 2>/dev/null)
			printf "q%s irq=%-4s affinity=%-3s rps=%s\n" "$q" "$irq" "$aff" "$rps"
		done
	done
}

main() {
	resolve_ifaces
	log "starting: cores=$cores wan=$WAN_IF lan=$LAN_IF"

	# irqbalance must not fight us
	if [ -x /etc/init.d/irqbalance ]; then
		/etc/init.d/irqbalance stop >/dev/null 2>&1
		/etc/init.d/irqbalance disable >/dev/null 2>&1
	fi
	command -v killall >/dev/null && killall irqbalance 2>/dev/null

	wait_iface "$WAN_IF" || { log "wan $WAN_IF not ready, exit"; exit 1; }
	wait_iface "$LAN_IF" || { log "lan $LAN_IF not ready, exit"; exit 1; }

	tune_sysctl

	ports="$(list_ports "$WAN_IF") $(list_ports "$LAN_IF")"
	seen=""
	for p in $ports; do
		case " $seen " in *" $p "*) continue ;; esac
		seen="$seen $p"
		tune_ring "$p"
		tune_coalesce "$p"
	done
	disable_rps $seen

	while :; do
		for p in $(list_ports "$WAN_IF"); do bind_iface "$p" 1; done
		for p in $(list_ports "$LAN_IF"); do bind_iface "$p" 1; done
		sleep "$INTERVAL"
	done
}

case "$1" in
--status) status ;;
*) main ;;
esac
