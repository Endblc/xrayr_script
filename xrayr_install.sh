#!/bin/bash

# --- 设置 ---
# set -e: 当命令失败时立即退出脚本
# set -o pipefail: 在管道中，只要有任何一个命令失败，整个管道的返回值就为非零
set -e
set -o pipefail

# --- 变量定义 ---
CONFIG_BASE_URL="https://raw.githubusercontent.com/Endblc/xcfg/refs/heads/main"
ERROR_LOG="install_error.log"

# --- 函数定义 ---
print_step() {
    echo ""
    echo "================================================="
    echo " $1"
    echo "================================================="
    echo ""
}

# --- 检测不兼容环境 ---
check_control_panels() {
    # 检测1Panel
    if [[ -d "/opt/1panel" ]] || [[ -f "/usr/local/bin/1panel" ]] || systemctl list-unit-files | grep -q "1panel"; then
        echo "检测到1Panel环境，此脚本与1Panel不兼容，安装取消。"
        exit 1
    fi
    
    # 检测宝塔
    if [[ -d "/www/server/panel" ]] || [[ -f "/etc/init.d/bt" ]] || systemctl list-unit-files | grep -q "bt"; then
        echo "检测到宝塔环境，此脚本与宝塔不兼容，安装取消。"
        exit 1
    fi
    
    # 检测aapanel
    if [[ -d "/www/server/panel" ]] || [[ -f "/etc/init.d/aaPanel" ]] || systemctl list-unit-files | grep -q "aaPanel"; then
        echo "检测到aaPanel环境，此脚本与aaPanel不兼容，安装取消。"
        exit 1
    fi
}

# --- 前置检查 ---
if [[ $EUID -ne 0 ]]; then
   echo "错误：此脚本必须以 root 身份运行"
   exit 1
fi

print_step "检查系统环境"
check_control_panels
echo "未检测到不兼容的控制面板环境，继续安装..."

# --- 用户输入与确认 ---
while true; do
    read -p "请输入面板 ID: " PANEL_ID
    read -p "请输入域名 (例如: your.domain.com): " DOMAIN
    read -s -p "请输入 GitHub 访问令牌 (输入时不会显示): " TOKEN
    echo "" 
    
    # 询问是否进行网络优化
    read -p "是否在安装完成后进行网络优化 (sysctl配置)? [y/N]: " OPT_NET_INPUT
    
    # 处理网络优化选项 (默认为 No)
    if [[ "$OPT_NET_INPUT" =~ ^[yY](es)?$ ]]; then
        ENABLE_NET_OPT=true
        NET_OPT_MSG="是"
    else
        ENABLE_NET_OPT=false
        NET_OPT_MSG="否"
    fi

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
echo "是否禁用 IPv6    : 是 (强制)"
echo "是否进行网络优化 : $NET_OPT_MSG"
echo ""
read -p "信息是否正确？按 Enter 继续，按 Ctrl+C 取消..."

# --- 主安装流程 ---
{
    print_step "1. 更新软件包列表并安装依赖"
    apt update -y
    apt install -y wget curl gnupg2 ca-certificates lsb-release debian-archive-keyring

    print_step "2. 永久禁用 IPv6"
    # 使用 sysctl.d 目录配置，避免被主 sysctl.conf 覆盖
    # 针对 Debian 12/13，这通常能立即生效且重启后保持
    echo "正在写入禁用 IPv6 配置..."
    cat > /etc/sysctl.d/99-disable-ipv6.conf << EOF
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF
    # 应用所有系统配置
    sysctl --system
    echo "IPv6 已禁用。"

    print_step "3. 安装 V2bX"
    # 下载脚本并自动输入 n (对应安装完成后的提示)
    wget -N https://raw.githubusercontent.com/wyx2685/V2bX-script/master/install.sh 
    echo "n" | bash install.sh

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
    # Nginx 配置
    curl -fSsL --header "Authorization: Bearer $TOKEN" -o /etc/nginx/nginx.conf "${CONFIG_BASE_URL}/nginx.conf"
    
    # V2bX 配置 (下载 v2bx.json 存为 config.json)
    curl -fSsL --header "Authorization: Bearer $TOKEN" -o /etc/V2bX/config.json "${CONFIG_BASE_URL}/v2bx.json"
    
    # 证书文件
    curl -fSsL --header "Authorization: Bearer $TOKEN" -o /etc/V2bX/kanata.key "${CONFIG_BASE_URL}/kanata.key"
    curl -fSsL --header "Authorization: Bearer $TOKEN" -o /etc/V2bX/kanata.crt "${CONFIG_BASE_URL}/kanata.crt"
    
    if [[ ! -s "/etc/V2bX/config.json" ]]; then
        echo "错误：/etc/V2bX/config.json 下载失败或为空文件！"
        exit 1
    fi
    echo "核心服务配置文件下载成功。"
    
    print_step "6. 设置安全权限并更新配置文件"
    echo "为私钥文件设置安全权限 (600)..."
    chmod 600 /etc/V2bX/kanata.key
    
    echo "更新配置文件变量..."
    # 替换第22行的 #### 为 面板ID
    sed -i "20s/####/$PANEL_ID/g" /etc/V2bX/config.json
    # 替换第55行的 #### 为 域名
    sed -i "53s/####/$DOMAIN/g" /etc/V2bX/config.json
    echo "配置文件变量替换完成。"

    print_step "7. 重启服务"
    echo "重启 Nginx..."
    systemctl restart nginx
    echo "重启 V2bX..."
    v2bx restart
    
    # --- 网络优化步骤 (根据用户选择执行) ---
    if [ "$ENABLE_NET_OPT" = true ]; then
        print_step "8. 执行网络优化 (sysctl)"
        
        if [ -f "/etc/sysctl.conf" ]; then
            echo "备份原 sysctl.conf 到 sysctl.conf.bak ..."
            cp /etc/sysctl.conf /etc/sysctl.conf.bak
        fi

        echo "下载网络优化配置..."
        curl -fSsL --header "Authorization: Bearer $TOKEN" -o /etc/sysctl.conf "${CONFIG_BASE_URL}/sysctl.conf"
        
        echo "应用 sysctl 配置..."
        # 临时禁用 set -e，防止因某些特定内核参数不支持导致脚本报错
        set +e 
        # 使用 --system 确保同时加载刚才创建的禁用IPv6配置和新下载的配置
        sysctl --system
        EXIT_CODE=$?
        set -e
        
        if [ $EXIT_CODE -eq 0 ]; then
            echo "网络优化应用成功。"
        else
            echo "网络优化部分参数应用失败，已忽略错误（IPv6禁用配置依然生效）。"
        fi
    else
        print_step "8. 跳过网络优化"
        echo "用户选择不进行网络优化。"
    fi

    print_step "安装完成！"
    echo "所有选定的任务已执行完毕。"

} | tee -a "$ERROR_LOG"

# 清理空日志
if [ ! -s "$ERROR_LOG" ]; then
    rm -f "$ERROR_LOG"
fi
