#!/bin/bash
set -eo pipefail
echo "===== Auto generate config matching stable release ====="

# 1. 获取主版本号
if [ -n "$STABLE_TAG" ]; then
    RELEASE_MAJOR=$(echo "$STABLE_TAG" | sed 's/^v//' | cut -d '.' -f1,2)
    echo "Using STABLE_TAG: $STABLE_TAG, major version: $RELEASE_MAJOR"
else
    BRANCH_NAME=$(git symbolic-ref --short HEAD 2>/dev/null || echo "")
    if [ -z "$BRANCH_NAME" ]; then
        echo "Error: Cannot determine version, STABLE_TAG not set and HEAD is detached."
        exit 1
    fi
    RELEASE_MAJOR=$(echo "$BRANCH_NAME" | sed 's/openwrt-//')
    echo "Branch: $BRANCH_NAME | Major version: $RELEASE_MAJOR"
fi

# 2. 抓取官方 config.buildinfo
LATEST_PATCH=$(curl -s https://downloads.openwrt.org/releases/ \
    | grep -E "href=\"$RELEASE_MAJOR\.[0-9]+/" \
    | sed -E "s/.*href=\"($RELEASE_MAJOR\.[0-9]+)\/\".*/\1/" \
    | sort -V | tail -n1 || true)

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

# 清理开发冗余配置
sed -i '/CONFIG_BUILDBOT=y/d' .config
sed -i '/CONFIG_SDK=y/d' .config
sed -i '/CONFIG_IB=y/d' .config
sed -i '/CONFIG_ALL_KMODS=y/d' .config
sed -i '/CONFIG_DEVEL=y/d' .config
sed -i '/CONFIG_TARGET_ALL_PROFILES=y/d' .config
sed -i '/CONFIG_TARGET_MULTI_PROFILE=y/d' .config

# 追加自定义包（引入 LuCI 基础依赖保证界面与语言包生效）
cat >> .config <<EOF

# 自定义软件及组件
CONFIG_PACKAGE_bash=y
CONFIG_PACKAGE_curl=y
CONFIG_PACKAGE_ethtool=y
CONFIG_PACKAGE_miniupnpd=y
CONFIG_PACKAGE_irqbalance=y
CONFIG_PACKAGE_block-mount=y
CONFIG_PACKAGE_luci-app-upnp=y
CONFIG_PACKAGE_luci-app-irqbalance=y
CONFIG_PACKAGE_luci-i18n-base-zh-cn=y
CONFIG_PACKAGE_luci-i18n-irqbalance-zh-cn=y
EOF

# 补全依赖并整理 .config
make defconfig

grep -E "bash|curl|ethtool|miniupnpd|irqbalance|block-mount|luci-app-upnp|luci-app-irqbalance|luci-i18n-base-zh-cn|luci-i18n-irqbalance-zh-cn" .config