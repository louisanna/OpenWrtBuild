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

# 1. 获取源码分支
BRANCH_NAME=$(git symbolic-ref --short HEAD)
RELEASE_MAJOR=$(echo $BRANCH_NAME | sed 's/openwrt-//')
echo "Branch: $BRANCH_NAME | Major version: $RELEASE_MAJOR"

# 2. 自动抓取该大版本下最新补丁版本（25.12 → 25.12.4）
LATEST_PATCH=$(curl -s https://downloads.openwrt.org/releases/ | grep -E "href=\"$RELEASE_MAJOR\.[0-9]+/" | sed -E "s/.*href=\"($RELEASE_MAJOR\.[0-9]+)\/\".*/\1/" | sort -V | tail -n1)
echo "Latest full release: $LATEST_PATCH"

# 3. 正确完整下载地址
BUILDINFO_URL="https://downloads.openwrt.org/releases/$LATEST_PATCH/targets/x86/generic/config.buildinfo"
echo "Download config: $BUILDINFO_URL"

# 4. 下载失败自动降级用 make defconfig
wget -q -O .config "$BUILDINFO_URL" || {
  echo "Download failed, fallback to make defconfig"
  make defconfig
}

# 清理开发冗余配置，减小固件体积、加速编译
sed -i '/CONFIG_BUILDBOT=y/d' .config
sed -i '/CONFIG_SDK=y/d' .config
sed -i '/CONFIG_IB=y/d' .config
sed -i '/CONFIG_ALL_KMODS=y/d' .config
sed -i '/CONFIG_DEVEL=y/d' .config
sed -i '/CONFIG_TARGET_ALL_PROFILES=y/d' .config

# 5. 追加你需要的软件包
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
