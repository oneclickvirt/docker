# FROM ubuntu:22.04
FROM debian

RUN apt-get update -y
RUN apt-get install -y
RUN qemu-kvm libvirt-daemon-system libvirt-dev build-essential curl net-tools jq openssh-server openssh-client iptables
# RUN $(apt-cache search linux-image | grep cloud | tail -n 1 | awk '{print $1}')
RUN apt-get autoclean
RUN apt-get autoremove

# RUN vagrant_latest_version=$(curl -s https://checkpoint-api.hashicorp.com/v1/check/vagrant | jq -r -M '.current_version') && \
#     URL="https://releases.hashicorp.com/vagrant/${vagrant_latest_version}/" && \
#     HTML=$(curl -s "$URL") && \
#     vagrant_pkgs=$(echo "$HTML" | grep -oE 'href="([^"]+\.deb)"' | sed -e 's/href="//' -e 's/"$//') && \
#     for pkg in $vagrant_pkgs; do if echo "$pkg" | grep -q "amd64"; then deb_filename=$(basename "$pkg"); fi; done && \
#     curl -O "https://releases.hashicorp.com/vagrant/${vagrant_latest_version}/${deb_filename}" && \
#     chmod 777 "${deb_filename}" && \
#     dpkg -i "${deb_filename}" && \
#     vagrant plugin install vagrant-libvirt && \
#     vagrant box add --provider libvirt peru/windows-10-enterprise-x64-eval && \
#     vagrant init peru/windows-10-enterprise-x64-eval

RUN curl -Lk https://github.com/hashicorp/vagrant/releases/download/2.3.8.dev%2B000086-5fc64cde/vagrant_2.3.8.dev-1_amd64.deb -o vagrant_2.3.8.dev-1_amd64.deb && \
    chmod 777 vagrant_2.3.8.dev-1_amd64.deb && \
    dpkg -i vagrant_2.3.8.dev-1_amd64.deb
RUN vagrant plugin install vagrant-libvirt
RUN vagrant box add --provider libvirt peru/windows-10-enterprise-x64-eval
RUN vagrant init peru/windows-10-enterprise-x64-eval

RUN systemctl enable libvirtd virtlogd --now
RUN VAGRANT_DEFAULT_PROVIDER=libvirt vagrant up
COPY startup.sh /
