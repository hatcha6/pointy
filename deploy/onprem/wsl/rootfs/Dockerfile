# The Pointy WSL distro, pre-baked in CI.
#
# `wsl --import` takes a root-filesystem tarball, and `docker export` produces
# exactly that — so we build the shop's Linux server as an image here, with
# Docker Engine and every dependency the deploy scripts need already installed,
# and ship it as one file.
#
# Doing the install here rather than on the shop's PC is what makes an on-prem
# install work with NO INTERNET: install.sh's Docker bootstrap fetches
# get.docker.com, which a shop behind a dead line can never reach. By the time
# this rootfs lands on the till, `docker` and `docker compose` already exist.
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

# systemd is what keeps the distro alive: with `systemd=true` in /etc/wsl.conf
# it becomes PID 1, so the VM does not shut down the moment the last shell
# exits, and the watchdog/update-agent timers written by register-autostart.sh
# have something to run under.
RUN apt-get update && apt-get install -y --no-install-recommends \
        systemd systemd-sysv dbus \
        ca-certificates curl gnupg \
        iproute2 iputils-ping iptables \
        python3 jq openssl unzip tzdata \
        less nano procps \
    && rm -rf /var/lib/apt/lists/*

# Docker Engine + the Compose v2 plugin from Docker's own apt repository.
RUN install -m 0755 -d /etc/apt/keyrings \
    && curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
         -o /etc/apt/keyrings/docker.asc \
    && chmod a+r /etc/apt/keyrings/docker.asc \
    && echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.asc] \
https://download.docker.com/linux/ubuntu noble stable" \
         > /etc/apt/sources.list.d/docker.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
         docker-ce docker-ce-cli containerd.io docker-compose-plugin \
    && rm -rf /var/lib/apt/lists/*

# WSL reads this on every distro start.
#
#   appendWindowsPath=false is load-bearing: with the Windows PATH appended, a
#   machine that also has Docker Desktop installed resolves `docker` to
#   docker.exe on the Windows side, and every deploy script silently manages the
#   WRONG engine.
COPY wsl.conf /etc/wsl.conf

# Enable docker + containerd by hand. `systemctl enable` refuses to run in a
# build container ("System has not been booted with systemd"), and these
# symlinks are all that command would have created anyway.
RUN mkdir -p /etc/systemd/system/multi-user.target.wants \
    && ln -sf /lib/systemd/system/docker.service \
              /etc/systemd/system/multi-user.target.wants/docker.service \
    && ln -sf /lib/systemd/system/containerd.service \
              /etc/systemd/system/multi-user.target.wants/containerd.service \
    && ln -sf /lib/systemd/system/docker.socket \
              /etc/systemd/system/sockets.target.wants/docker.socket

# WSL manages the network itself: it writes /etc/resolv.conf and configures
# eth0 before systemd starts. Leaving Ubuntu's network stack enabled means two
# owners for the same files, which shows up as intermittent DNS failures —
# exactly the kind of fault that looks like "the relay is down".
RUN systemctl mask systemd-resolved.service systemd-networkd.service \
        systemd-networkd.socket networkd-dispatcher.service \
        systemd-remount-fs.service \
        NetworkManager.service 2>/dev/null || true

# Cap container log growth. A till runs for years without anyone looking at it;
# the default unbounded json-file driver is how a shop's disk fills up.
RUN mkdir -p /etc/docker && printf '%s\n' \
    '{' \
    '  "log-driver": "json-file",' \
    '  "log-opts": { "max-size": "10m", "max-file": "3" },' \
    '  "live-restore": true' \
    '}' > /etc/docker/daemon.json

RUN mkdir -p /opt/pointy

CMD ["/sbin/init"]
