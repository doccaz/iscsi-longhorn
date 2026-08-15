FROM registry.suse.com/bci/python:3

RUN zypper --non-interactive install -y \
        kmod \
    && zypper clean -a \
    && rm -rf /var/cache/zypp/*

# targetcli-fb uses kernel LIO via configfs — no host OS packages needed
RUN pip3 install --no-cache-dir configshell-fb rtslib-fb targetcli-fb

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
