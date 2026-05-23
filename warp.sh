#!/bin/bash

# By skrepysh.dll <3

red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
plain='\033[0m'

if [[ -f /etc/os-release ]]; then
    source /etc/os-release
    release=$ID
elif [[ -f /usr/lib/os-release ]]; then
    source /usr/lib/os-release
    release=$ID
else
    echo "Failed to check the system OS, please contact the author!" >&2
    rm -- "$0"
    exit 1
fi

function LOGD() {
    echo -e "${yellow}[DEG] $* ${plain}"
}

function LOGE() {
    echo -e "${red}[ERR] $* ${plain}"
}

function LOGI() {
    echo -e "${green}[INF] $* ${plain}"
}

# check root
[[ $EUID -ne 0 ]] && LOGE "ERROR: You must be root to run this script! \n" && rm -- "$0" && exit 1

echo "The OS release is: $release"
os_version=""
os_version=$(grep "^VERSION_ID" /etc/os-release | cut -d '=' -f2 | tr -d '"' | tr -d '.')

select_port() {
    export WARP_PORT=40000
    LOGI "Port $WARP_PORT will be used"
}

manage_warp() {
    check_warp
    if [ $? -eq 1 ]; then
        LOGD "warp-cli is already installed!"
        configure_warp
    else
        detect_os_and_install_warp
        configure_warp
    fi
}

incompatible_os() {
    echo -e "${red}Your operating system is not supported by this script.${plain}\n"
    echo "Please ensure you are using one of the following supported operating systems:"
    echo "- Ubuntu 20.04+"
    echo "- Debian 11+"
    echo "- CentOS 8+"
    rm -- "$0"
    exit 1
}

install_ubuntu() {
    LOGI "Installing for Ubuntu"
    check_warp
    if [ $? -eq 1 ]; then
        LOGE "warp-cli is already installed. Installation aborted"
        rm -- "$0"
        exit 1
    fi
    LOGI "Adding cloudflare warp key and repo"
    curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | gpg --yes --dearmor --output /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg >> /dev/null 2>&1
    echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/cloudflare-client.list >> /dev/null 2>&1
    LOGI "Updating repos"
    apt-get update >> /dev/null 2>&1
    LOGI "Installing warp-cli"
    apt-get -y install cloudflare-warp netcat-openbsd >> /dev/null 2>&1
}

install_debian() {
    LOGI "Installing for Debian"
    check_warp
    if [ $? -eq 1 ]; then
        LOGE "warp-cli is already installed. Installation aborted"
        rm -- "$0"
        exit 1
    fi
    LOGI "Updating repos"
    apt update >> /dev/null 2>&1
    LOGI "Installing gpg"
    apt -y install gpg >> /dev/null 2>&1
    LOGI "Adding cloudflare warp key and repo"
    curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | sudo gpg --yes --dearmor --output /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg >> /dev/null 2>&1
    echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/cloudflare-client.list >> /dev/null 2>&1
    LOGI "Updating repos"
    apt-get update >> /dev/null 2>&1
    LOGI "Installing warp-cli"
    apt-get -y install cloudflare-warp netcat-traditional >> /dev/null 2>&1
}

install_centos() {
    LOGI "Installing for CentOS"
    check_warp
    if [ $? -eq 1 ]; then
        LOGE "warp-cli is already installed. Installation aborted"
        rm -- "$0"
        exit 1
    fi
    LOGI "Adding cloudflare warp repo"
    curl -fsSl https://pkg.cloudflareclient.com/cloudflare-warp-ascii.repo | tee /etc/yum.repos.d/cloudflare-warp.repo >> /dev/null 2>&1
    LOGI "Updating repos"
    yum update >> /dev/null 2>&1
    LOGI "Installing warp-cli"
    yum -y install cloudflare-warp >> /dev/null 2>&1
}

check_warp() {
    if [ "$(command -v warp-cli)" ]; then
        return 1
    else
        return 0
    fi
}

check_connection() {
    if warp-cli --accept-tos status | grep -q "Status update: Connected"; then
        return 1
    else
        return 0
    fi
}

check_registration() {
    if warp-cli --accept-tos registration show 2>&1 | grep -q "Error: Missing registration. Try running: \"warp-cli registration new\""; then
        return 1
    else
        return 0
    fi
}

detect_os_and_install_warp() {
    case "$release" in
        centos)
            if [ "$os_version" -lt 8 ]; then
                incompatible_os
            fi
            install_centos
            ;;
        ubuntu)
            if [ "$os_version" -lt 20 ]; then
                incompatible_os
            fi
            install_ubuntu
            ;;
        debian)
            if [ "$os_version" -lt 11 ]; then
                incompatible_os
            fi
            install_debian
            ;;
        *)
            incompatible_os
            ;;
    esac
}

configure_warp() {
    check_warp
    if [ $? -eq 0 ]; then
        LOGE "warp-cli is not installed. Configuring aborted"
        rm -- "$0"
        exit 1
    fi
    LOGI "Configuring WARP"
    check_connection
    if [ $? -eq 1 ]; then
        echo -n -e "${yellow}warp-cli is already connected. Disconnecting: ${plain}"
        warp-cli --accept-tos disconnect
    fi

    check_registration
    if [ $? -eq 1 ]; then
        echo -n -e "${green}Registration: ${plain}"
        warp-cli --accept-tos registration new
    fi

    select_port
    echo -n -e "${green}Setting mode proxy: ${plain}"
    warp-cli --accept-tos mode proxy
    echo -n -e "${green}Setting proxy port to $WARP_PORT: ${plain}"
    warp-cli --accept-tos proxy port $WARP_PORT
    echo -n -e "${green}Starting warp-cli: ${plain}"
    warp-cli --accept-tos connect
    LOGI "warp-cli has been configured successfully!"
    LOGI "You can access socks proxy on 127.0.0.1:$WARP_PORT"
    LOGD "If warp is not working, check it using curl -x socks://127.0.0.1:$WARP_PORT ifconfig.me"
    LOGD "If this command returns cloudflare's IP, warp is working fine"
    LOGE "YOU DON'T NEED TO OPEN $WARP_PORT PORT!!!"
}

manage_warp
rm -- "$0"
exit 0
