#!/bin/sh /etc/rc.common

ADGUARD="/overlay/AdGuardHome/AdGuardHome"

if [ -f "$ADGUARD" ]; then
    echo "AdGuardHome found, restarting..."
    "$ADGUARD" -s stop
    rm -rf /tmp/AdGuardHome
    mkdir -p -m 755 /tmp/AdGuardHome
    "$ADGUARD" -s restart
else
    echo "AdGuardHome not found, skipping."
fi