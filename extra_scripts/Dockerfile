FROM debian

RUN apt-get update -y && \
    apt-get install -y \
    qemu-kvm \
    libvirt-daemon-system \
    libvirt-dev \
    build-essential \
    $(apt-cache search linux-image | grep cloud | tail -n 1 | awk '{print $1}') \
    curl \
    net-tools \
    jq \
    iptables && \
    apt-get autoclean && \
    apt-get autoremove

RUN vagrant_latest_version=$(curl -s https://checkpoint-api.hashicorp.com/v1/check/vagrant | jq -r -M '.current_version') && \
    URL="https://releases.hashicorp.com/vagrant/${vagrant_latest_version}/" && \
    HTML=$(curl -s "$URL") && \
    vagrant_pkgs=$(echo "$HTML" | grep -oE 'href="([^"]+\.deb)"' | sed -e 's/href="//' -e 's/"$//') && \
    deb_filename=$(echo "$vagrant_pkgs" | grep "amd64") && \
    curl -O "https://releases.hashicorp.com/vagrant/${vagrant_latest_version}/${deb_filename}" && \
    chmod 777 "${deb_filename}" && \
    dpkg -i "${deb_filename}" && \
    vagrant plugin install vagrant-libvirt && \
    vagrant box add --provider libvirt peru/windows-10-enterprise-x64-eval && \
    vagrant init peru/windows-10-enterprise-x64-eval

COPY startup.sh /
