#!/bin/sh

# Bark 推送地址（请替换为实际地址）
BARK_URL="https://bark.free.svipss.top/wkXQBsJ7mchriPBH8c7c6Z/"

# 更新软件源
apk update > /dev/null 2>&1

# 执行模拟升级并捕获输出
UPGRADE_OUTPUT=$(apk upgrade --available --simulate 2>/dev/null)

# 无更新则直接退出
[ -z "$UPGRADE_OUTPUT" ] && exit 0

# 临时文件
PKG_TMP="/tmp/pkglist.tmp"
BASE_OLD_TMP="/tmp/basefiles_old.tmp"
BASE_NEW_TMP="/tmp/basefiles_new.tmp"
> "$PKG_TMP"
> "$BASE_OLD_TMP"
> "$BASE_NEW_TMP"

# 解析模拟升级输出
echo "$UPGRADE_OUTPUT" | while read -r line; do
    case "$line" in
        "("*") Upgrading "*)
            # 提取包名和版本信息
            pkg_part="${line#*Upgrading }"
            pkg_name="${pkg_part%% *}"
            version_part="${pkg_part#* (}"
            version_part="${version_part%)}"
            old_ver="${version_part%% -> *}"
            new_ver="${version_part#* -> }"

            # 记录包名
            echo "$pkg_name" >> "$PKG_TMP"
            # 记录 base-files 的版本
            [ "$pkg_name" = "base-files" ] && {
                echo "$old_ver" > "$BASE_OLD_TMP"
                echo "$new_ver" > "$BASE_NEW_TMP"
            }
            ;;
    esac
done

# 生成去重后的包列表（逗号分隔）
PACKAGE_LIST=$(sort -u "$PKG_TMP" | tr '\n' ',' | sed 's/,$//')
rm -f "$PKG_TMP"

# 处理 base-files 更新
if [ -s "$BASE_OLD_TMP" ] && [ -s "$BASE_NEW_TMP" ]; then
    BASE_OLD=$(cat "$BASE_OLD_TMP")
    BASE_NEW=$(cat "$BASE_NEW_TMP")
    rm -f "$BASE_OLD_TMP" "$BASE_NEW_TMP"

    # 从包列表中移除 base-files（避免重复）
    PACKAGE_LIST=$(echo "$PACKAGE_LIST" | sed 's/\(,\|^\)base-files\(,\|$\)/\1\2/g; s/,,*/,/g; s/^,//; s/,$//')
    SYSTEM_UPDATE="System:$BASE_OLD->$BASE_NEW"

    # 计算其他包数量
    if [ -n "$PACKAGE_LIST" ]; then
        other_count=$(echo "$PACKAGE_LIST" | tr ',' '\n' | wc -l)
    else
        other_count=0
    fi
    total=$((1 + other_count))

    # 构造 body
    if [ -n "$PACKAGE_LIST" ]; then
        BODY="共有${total}个更新: $SYSTEM_UPDATE,$PACKAGE_LIST"
    else
        BODY="共有${total}个更新: $SYSTEM_UPDATE"
    fi
else
    rm -f "$BASE_OLD_TMP" "$BASE_NEW_TMP"
    # 无系统更新，直接使用包列表，总数即为包数量
    if [ -n "$PACKAGE_LIST" ]; then
        total=$(echo "$PACKAGE_LIST" | tr ',' '\n' | wc -l)
        BODY="共有${total}个更新: $PACKAGE_LIST"
    else
        # 理论上不会进入这里，因为前面检查过有更新
        exit 0
    fi
fi

# 发送 Bark 通知
JSON_DATA="{\"title\":\"OpenWrt 系统更新\",\"body\":\"$BODY\",\"group\":\"OpenWrt\"}"
curl -X POST -H "Content-Type: application/json" -d "$JSON_DATA" "$BARK_URL" > /dev/null 2>&1