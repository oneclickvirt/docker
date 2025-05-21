prebuild_ifupdown() {
    if [ ! -f "/usr/local/bin/ifupdown_installed.txt" ]; then
        wget ${cdn_success_url}https://raw.githubusercontent.com/oneclickvirt/docker/main/extra_scripts/install_ifupdown.sh -O /usr/local/bin/install_ifupdown.sh
        wget ${cdn_success_url}https://raw.githubusercontent.com/oneclickvirt/docker/main/extra_scripts/ifupdown-install.service -O /etc/systemd/system/ifupdown-install.service
        chmod 777 /usr/local/bin/install_ifupdown.sh
        chmod 777 /etc/systemd/system/ifupdown-install.service
        if [ -f "/usr/local/bin/install_ifupdown.sh" ]; then
            systemctl daemon-reload
            systemctl enable ifupdown-install.service
        fi
    fi
}