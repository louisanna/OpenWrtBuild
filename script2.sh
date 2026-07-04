#!/bin/bash
# Copyright (c) 2022-2023 Curious <https://www.curious.host>
#
# This is free software, licensed under the MIT License.
# See /LICENSE for more information.
# 
# https://github.com/Curious-r/OpenWrtBuildWorkflows
# Description: Automatically check OpenWrt source code update and build it. No additional keys are required.
#-------------------------------------------------------------------------------------------------------
#
#
# Patching is generally recommended.
# # Here's a template for patching:
#touch example.patch
#cat>example.patch<<EOF
#patch content
#EOF
#git apply example.patch

set -eo pipefail
echo "===== Auto generate config matching stable release ====="

# 1. 获取源码分支
BRANCH_NAME=$(git symbolic-ref --short HEAD)
RELEASE_MAJOR=$(echo "$BRANCH_NAME" | sed 's/openwrt-//')
echo "Branch: $BRANCH_NAME | Major version: $RELEASE_MAJOR"

# 2. 抓取该大版本下全部补丁版本，过滤空值
LATEST_PATCH=$(curl -s https://downloads.openwrt.org/releases/ \
    | grep -E "href=\"$RELEASE_MAJOR\.[0-9]+/" \
    | sed -E "s/.*href=\"($RELEASE_MAJOR\.[0-9]+)\/\".*/\1/" \
    | sort -V | tail -n1 || true)

# 兜底：抓取失败直接走defconfig，不继续下载
if [ -z "$LATEST_PATCH" ]; then
    echo "Failed to fetch patch version, use default make defconfig"
    make defconfig
else
    echo "Latest full release: $LATEST_PATCH"
    BUILDINFO_URL="https://downloads.openwrt.org/releases/$LATEST_PATCH/targets/x86/64/config.buildinfo"
    echo "Download config: $BUILDINFO_URL"
    wget -q -O .config "$BUILDINFO_URL" || {
        echo "Download failed, fallback to make defconfig"
        make defconfig
    }
fi

# 删除开发冗余配置
sed -i '/CONFIG_BUILDBOT=y/d' .config
sed -i '/CONFIG_SDK=y/d' .config
sed -i '/CONFIG_IB=y/d' .config
sed -i '/CONFIG_ALL_KMODS=y/d' .config
sed -i '/CONFIG_DEVEL=y/d' .config
sed -i '/CONFIG_TARGET_ALL_PROFILES=y/d' .config
sed -i '/CONFIG_TARGET_MULTI_PROFILE=y/d' .config

# 追加自定义包
cat >> .config <<EOF

# 自定义所需软件
CONFIG_PACKAGE_miniupnpd=y
CONFIG_PACKAGE_irqbalance=y
CONFIG_PACKAGE_block-mount=y
CONFIG_PACKAGE_luci-app-upnp=y
EOF

echo "===== Config generate finished ====="
grep -E "miniupnpd|irqbalance|block-mount|luci-app-upnp" .config

