FROM registry.suse.com/bci/bci-base:latest

RUN zypper --non-interactive install -y \
        python3 \
        python3-pip \
        kmod \
    && zypper clean -a \
    && rm -rf /var/cache/zypp/*

# targetcli-fb uses kernel LIO via configfs — no host OS packages needed
RUN pip3 install --no-cache-dir targetcli-fb rtslib-fb

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
