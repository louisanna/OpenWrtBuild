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

echo "===== Auto generate config matching stable release ====="
cd openwrt

# 获取当前源码稳定分支
BRANCH_NAME=$(git symbolic-ref --short HEAD)
RELEASE_VER=$(echo $BRANCH_NAME | sed 's/openwrt-//')
echo "Current branch: $BRANCH_NAME | Release version: $RELEASE_VER"

# 修正路径 targets/x86/generic 而非 x86/64
BUILDINFO_URL="https://downloads.openwrt.org/releases/$RELEASE_VER/targets/x86/generic/config.buildinfo"
echo "Download official config: $BUILDINFO_URL"
wget -q -O .config "$BUILDINFO_URL"

# 清理开发冗余配置，减小固件体积、加速编译
sed -i '/CONFIG_BUILDBOT=y/d' .config
sed -i '/CONFIG_SDK=y/d' .config
sed -i '/CONFIG_IB=y/d' .config
sed -i '/CONFIG_ALL_KMODS=y/d' .config
sed -i '/CONFIG_DEVEL=y/d' .config
sed -i '/CONFIG_TARGET_ALL_PROFILES=y/d' .config

# 3. 追加你需要的软件包
cat >> .config <<EOF

# 自定义所需软件
CONFIG_PACKAGE_miniupnpd=y
CONFIG_PACKAGE_irqbalance=y
CONFIG_PACKAGE_block-mount=y
CONFIG_PACKAGE_luci-app-upnp=y
EOF

echo "===== Config generation finished ====="
echo "Added custom packages:"
cat .config | grep -E "miniupnpd|irqbalance|block-mount|luci-app-upnp"
