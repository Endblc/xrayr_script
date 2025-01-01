#!/bin/bash

# 提示用户输入面板 ID、域名和 GitHub 访问令牌
read -p "请输入面板 ID: " PANEL_ID
read -p "请输入域名: " DOMAIN
read -p "请输入 GitHub 访问令牌: " TOKEN

# 错误日志文件
ERROR_LOG="error.log"

# 更新并安装必要的软件包
{
    echo "正在安装必要的软件包..."
    wget -N https://raw.githubusercontent.com/XrayR-project/XrayR-release/master/install.sh && bash install.sh

    apt install -y gnupg2 ca-certificates lsb-release debian-archive-keyring
    curl https://nginx.org/keys/nginx_signing.key | gpg --dearmor > /usr/share/keyrings/nginx-archive-keyring.gpg
    echo "deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] http://nginx.org/packages/mainline/debian $(lsb_release -cs) nginx" > /etc/apt/sources.list.d/nginx.list
    echo -e "Package: *\nPin: origin nginx.org\nPin: release o=nginx\nPin-Priority: 900\n" > /etc/apt/preferences.d/99nginx
    apt update -y
    apt install -y nginx

    mkdir -p /etc/systemd/system/nginx.service.d
    echo -e "[Service]\nExecStartPost=/bin/sleep 0.1" > /etc/systemd/system/nginx.service.d/override.conf
    systemctl daemon-reload

    # 下载配置文件
    curl --header "Authorization: Bearer $TOKEN" -Lo /etc/nginx/nginx.conf https://raw.githubusercontent.com/Endblc/xcfg/refs/heads/main/nginx.conf
    curl --header "Authorization: Bearer $TOKEN" -Lo /etc/XrayR/config.yml https://raw.githubusercontent.com/Endblc/xcfg/refs/heads/main/config.yml
    curl --header "Authorization: Bearer $TOKEN" -Lo /etc/XrayR/nanodesu.key https://raw.githubusercontent.com/Endblc/xcfg/refs/heads/main/nanodesu.key
    curl --header "Authorization: Bearer $TOKEN" -Lo /etc/XrayR/Certificate.crt https://raw.githubusercontent.com/Endblc/xcfg/refs/heads/main/Certificate.crt
    curl --header "Authorization: Bearer $TOKEN" -Lo /etc/sysctl.conf https://raw.githubusercontent.com/Endblc/xcfg/refs/heads/main/sysctl.conf && sysctl -p

    # 替换配置文件中的变量
    sed -i "20s/Values/$PANEL_ID/g" /etc/XrayR/config.yml
    sed -i "79s/fake/$DOMAIN/g" /etc/XrayR/config.yml

    echo "安装完成！"
} 2>> "$ERROR_LOG"

# 检查是否有错误
if [ -s "$ERROR_LOG" ]; then
    echo "安装过程中出现错误，详细信息请查看 $ERROR_LOG"
else
    # 如果没有错误，删除错误日志文件
    rm -f "$ERROR_LOG"
fi
