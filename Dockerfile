FROM registry.suse.com/bci/python:3

# gcc14/python313-devel/cairo-devel/gobject-introspection-devel are build-only,
# needed to compile pygobject/pycairo below (no prebuilt wheels for this platform).
RUN zypper --non-interactive install -y \
        kmod \
        python313-curses \
        gcc14 \
        python313-devel \
        cairo-devel \
        gobject-introspection-devel \
    && ln -sf /usr/bin/gcc-14 /usr/bin/gcc \
    && zypper clean -a \
    && rm -rf /var/cache/zypp/*

# targetcli-fb uses kernel LIO via configfs — no host OS packages needed
# configshell_fb needs curses (python313-curses) and gi.repository.Gio (pygobject).
# pygobject must stay <3.52: newer releases require girepository-2.0, which this
# SLE_BCI repo doesn't ship (only the older girepository-1.0 headers).
RUN pip3 install --no-cache-dir configshell-fb rtslib-fb targetcli-fb "pygobject<3.52" six

# rtslib's dbroot (/etc/target) isn't created by the package
RUN mkdir -p /etc/target

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
