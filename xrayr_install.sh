#!/bin/bash

# --- 设置 ---
# set -e: 当命令失败时立即退出脚本
# set -o pipefail: 在管道中，只要有任何一个命令失败，整个管道的返回值就为非零
set -e
set -o pipefail

# --- 变量定义 ---
# 将配置文件的基础 URL 定义为变量，方便维护
CONFIG_BASE_URL="https://raw.githubusercontent.com/Endblc/xcfg/refs/heads/main"
ERROR_LOG="install_error.log"

# --- 函数定义 ---
# 打印步骤标题的函数
print_step() {
    echo ""
    echo "================================================="
    echo " $1"
    echo "================================================="
    echo ""
}

# --- 前置检查 ---
# 1. 检查脚本是否以 root 权限运行
if [[ $EUID -ne 0 ]]; then
   echo "错误：此脚本必须以 root 身份运行"
   exit 1
fi

# --- 用户输入与确认 ---
# 循环直到获取到有效的输入
while true; do
    read -p "请输入面板 ID: " PANEL_ID
    read -p "请输入域名 (例如: your.domain.com): " DOMAIN
    read -s -p "请输入 GitHub 访问令牌 (输入时不会显示): " TOKEN
    echo "" # 换行

    if [[ -z "$PANEL_ID" || -z "$DOMAIN" || -z "$TOKEN" ]]; then
        echo "错误：面板 ID、域名和令牌均不能为空，请重新输入。"
    else
        break
    fi
done

# 显示用户输入并请求最终确认
print_step "请确认您的输入"
echo "面板 ID          : $PANEL_ID"
echo "域名             : $DOMAIN"
echo "GitHub 访问令牌  : [已隐藏]"
echo ""
read -p "信息是否正确？按 Enter 继续，按 Ctrl+C 取消..."

# --- 主安装流程 ---
# 将所有输出（标准输出和标准错误）重定向到日志文件和终端
# 这样用户既能看到进度，又能记录日志
{
    print_step "1. 更新软件包列表并安装依赖 (wget, curl)"
    apt update -y
    apt install -y wget curl gnupg2 ca-certificates lsb-release debian-archive-keyring

    print_step "2. 配置 IPv6 优先"
    if ! grep -qxF 'precedence ::ffff:0:0/96 100' /etc/gai.conf; then
        echo "precedence ::ffff:0:0/96 100" >> /etc/gai.conf
        echo "已添加 IPv6 优先配置。"
    else
        echo "IPv6 优先配置已存在。"
    fi

    print_step "3. 安装 XrayR"
    wget -N https://raw.githubusercontent.com/XrayR-project/XrayR-release/master/install.sh && bash install.sh

    print_step "4. 安装并配置 Nginx"
    curl -sS https://nginx.org/keys/nginx_signing.key | gpg --dearmor > /usr/share/keyrings/nginx-archive-keyring.gpg
    echo "deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] http://nginx.org/packages/mainline/debian `lsb_release -cs` nginx" > /etc/apt/sources.list.d/nginx.list
    echo -e "Package: *\nPin: origin nginx.org\nPin: release o=nginx\nPin-Priority: 900\n" > /etc/apt/preferences.d/99nginx
    apt update -y
    apt install -y nginx
    mkdir -p /etc/systemd/system/nginx.service.d
    echo -e "[Service]\nExecStartPost=/bin/sleep 0.1" > /etc/systemd/system/nginx.service.d/override.conf
    systemctl daemon-reload

    print_step "5. 下载项目配置文件"
    # 使用 -fSsl 选项：-f 会在服务器错误时静默失败（但 set -e 会捕获），-S 显示错误，-s 静默模式，-L 跟随重定向
    curl -fSsL --header "Authorization: Bearer $TOKEN" -o /etc/nginx/nginx.conf "${CONFIG_BASE_URL}/nginx.conf"
    curl -fSsL --header "Authorization: Bearer $TOKEN" -o /etc/XrayR/config.yml "${CONFIG_BASE_URL}/config.yml"
    curl -fSsL --header "Authorization: Bearer $TOKEN" -o /etc/XrayR/kanata.key "${CONFIG_BASE_URL}/kanata.key"
    curl -fSsL --header "Authorization: Bearer $TOKEN" -o /etc/XrayR/kanata.crt "${CONFIG_BASE_URL}/kanata.crt"
    curl -fSsL --header "Authorization: Bearer $TOKEN" -o /etc/sysctl.conf "${CONFIG_BASE_URL}/sysctl.conf"
    
    # 检查关键配置文件是否下载成功
    if [[ ! -s "/etc/XrayR/config.yml" ]]; then
        echo "错误：/etc/XrayR/config.yml 下载失败或为空文件！"
        exit 1
    fi
    
    echo "所有配置文件下载成功。"
    
    print_step "6. 设置安全权限并更新配置文件"
    echo "为私钥文件设置安全权限 (600)..."
    chmod 600 /etc/XrayR/kanata.key
    
    echo "根据用户输入更新配置文件..."
    sed -i "20s/Values/$PANEL_ID/g" /etc/XrayR/config.yml
    sed -i "79s/fake/$DOMAIN/g" /etc/XrayR/config.yml
    echo "配置文件变量替换完成。"

    print_step "7. 重启服务"
    systemctl restart nginx
    xrayr restart

    print_step "8. 应用 sysctl 配置 (忽略错误)"
    # 临时禁用 set -e 以忽略 sysctl -p 的错误
    set +e
    sysctl -p -q
    set -e

    print_step "安装成功！"
    echo "所有服务已配置并重启"


} | tee -a "$ERROR_LOG"

# 最终的成功或失败判断由 set -e 自动完成，如果脚本能跑到这里，就说明没有命令失败。
# 为了保险起见，可以删掉空的日志文件
if [ ! -s "$ERROR_LOG" ]; then
    rm -f "$ERROR_LOG"
fi
