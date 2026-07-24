#!/bin/sh /etc/rc.common
# 清理旧目录，重建权限完整目录
/overlay/AdGuardHome/AdGuardHome -s stop
rm -rf /tmp/AdGuardHome
mkdir -p -m 755 /tmp/AdGuardHome
/overlay/AdGuardHome/AdGuardHome -s restart