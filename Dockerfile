###########################################################
# base image, used for build stages and final images
FROM phusion/baseimage:noble-1.0.3 AS base
ARG DEBIAN_FRONTEND=noninteractive
RUN mkdir /opt/arm
WORKDIR /opt/arm

# start by updating and upgrading the OS
RUN \
    apt clean && \
    apt update && \
    apt upgrade -y -o Dpkg::Options::="--force-confold"

# create an arm group(gid 1000) and an arm user(uid 1000), with password logon disabled
RUN groupadd -g 1000 arm \
    && useradd -rm -d /home/arm -s /bin/bash -g arm -G video,cdrom -u 1000 arm

# enable support for Arch Linux and derivatives, who use a different user group for optical drive permissions
RUN groupadd -g 990 optical \
    && usermod -aG optical arm

# Enable support for Fedora derivatives, which uses GID 11 for the cdrom group
RUN groupadd -g 11 cdrom_Fedora \
   && usermod -aG cdrom_Fedora arm

# UID and GID are not settable as of https://github.com/phusion/baseimage-docker/pull/86
ENV ARM_UID=1000
ENV ARM_GID=1000

# Intel GPU runtime — provides the iHD VA driver needed for QSV hardware encoding.
RUN apt-get install -y --no-install-recommends wget gnupg ca-certificates && \
    wget -qO- https://repositories.intel.com/gpu/intel-graphics.key | \
      gpg --yes --dearmor -o /usr/share/keyrings/intel-graphics.gpg && \
    echo "deb [arch=amd64 signed-by=/usr/share/keyrings/intel-graphics.gpg] https://repositories.intel.com/gpu/ubuntu noble unified" \
      > /etc/apt/sources.list.d/intel-gpu.list && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
      intel-media-va-driver \
      libva2 \
      libva-drm2 \
      libmfx-gen1.2 && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# setup gnupg/wget for add-ppa.sh
RUN install_clean \
        git \
        wget \
        build-essential \
        libcurl4-openssl-dev \
        libssl-dev \
        gnupg \
        libudev-dev \
        udev \
        python3 \
        python3-dev \
        python3-pip \
        nano \
        vim \
        # arm extra requirements
        scons swig libzbar-dev libzbar0

###########################################################
# install deps specific to the docker deployment
FROM base AS deps-docker
RUN install_clean gosu


###########################################################
# install deps for ripper
FROM deps-docker AS deps-ripper
RUN install_clean \
        abcde \
        eyed3 \
        atomicparsley \
        cdparanoia \
        eject \
        ffmpeg \
        flac \
        default-jre-headless \
        id3 \
        id3v2 \
        lame \
        libavcodec-extra \
        lsdvd \
        mkcue \
        vorbis-tools \
        opus-tools \
        fdkaac

# install libdvd-pkg
RUN \
    install_clean libdvd-pkg && \
    dpkg-reconfigure libdvd-pkg

# install python reqs
# PIP_BREAK_SYSTEM_PACKAGES=1 is required on noble (Python 3.12 / PEP 668)
COPY requirements.txt ./requirements.txt
RUN PIP_BREAK_SYSTEM_PACKAGES=1 pip3 install --upgrade pip wheel setuptools psutil pyudev
RUN PIP_BREAK_SYSTEM_PACKAGES=1 pip3 install --ignore-installed --prefer-binary -r ./requirements.txt

###########################################################
# install makemkv and handbrake
FROM deps-ripper AS install-makemkv-handbrake
COPY ./scripts/install_mkv_hb_deps.sh /install_mkv_hb_deps.sh
RUN chmod +x /install_mkv_hb_deps.sh && sleep 1 && \
    /install_mkv_hb_deps.sh

COPY ./scripts/install_handbrake.sh /install_handbrake.sh
RUN chmod +x /install_handbrake.sh && sleep 1 && \
    /install_handbrake.sh

# MakeMKV setup by https://github.com/tianon
COPY ./scripts/install_makemkv.sh /install_makemkv.sh
RUN chmod +x /install_makemkv.sh && sleep 1 && \
    /install_makemkv.sh

# Build and install the QSV fix shim.
#
# Root cause: libmfx-gen (oneVPL GPU runtime) loads libva via dlopen(RTLD_DEEPBIND),
# isolating libva in a private symbol scope. vaGetDriverName() then fails on the
# MFX-internal VA display (VA_STATUS_ERROR_UNIMPLEMENTED), causing FFmpeg to abort
# QSV hwdevice creation. This is architectural in libmfx-gen and affects all versions.
#
# The shim fixes this via two mechanisms:
#   1. dlopen override: strips RTLD_DEEPBIND for libva loads → global scope
#   2. vaGetDriverName override: returns "iHD" so FFmpeg proceeds past the check
#
# Placed in /etc/ld.so.preload so it is effective for all processes at runtime
# without any wrapper scripts or environment variable configuration.
COPY scripts/vadrv_shim.c /tmp/vadrv_shim.c
COPY scripts/vadrv.map /tmp/vadrv.map
RUN gcc -shared -fPIC -Wl,--version-script=/tmp/vadrv.map -ldl \
      -o /usr/lib/x86_64-linux-gnu/vadrv_shim.so /tmp/vadrv_shim.c && \
    echo '/usr/lib/x86_64-linux-gnu/vadrv_shim.so' > /etc/ld.so.preload && \
    nm -D /usr/lib/x86_64-linux-gnu/vadrv_shim.so | grep -E 'vaGetDriverName|vaGetDeviceID' && \
    rm /tmp/vadrv_shim.c /tmp/vadrv.map

# LIBVA environment — ensures the iHD driver is selected even in environments
# where udev/DRM auto-detection is unavailable (e.g. containers without /dev/dri).
ENV LIBVA_DRIVER_NAME=iHD
ENV LIBVA_DRIVERS_PATH=/usr/lib/x86_64-linux-gnu/dri
ENV LIBVA_DRM_DEVICE=/dev/dri/renderD128

# clean up apt
RUN apt clean && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# Container healthcheck
COPY scripts/healthcheck.sh /healthcheck.sh
RUN chmod +x /healthcheck.sh
HEALTHCHECK --interval=5m --timeout=15s --start-period=30s CMD /healthcheck.sh

# Set Timezone data
ENV TZ=Etc/UTC
RUN install_clean tzdata && \
    ln -sf /usr/share/zoneinfo/$TZ /etc/localtime && \
    dpkg-reconfigure --frontend noninteractive tzdata

ARG VERSION
ARG BUILD_DATE
LABEL org.opencontainers.image.source=https://github.com/eljefe80/arm-dependencies.git
LABEL org.opencontainers.image.url=https://github.com/eljefe80/arm-dependencies
LABEL org.opencontainers.image.description="Dependencies for Automatic Ripping Machine (eljefe80 fork — Intel QSV support baked in)"
LABEL org.opencontainers.image.documentation=https://raw.githubusercontent.com/eljefe80/arm-dependencies/main/README.md
LABEL org.opencontainers.image.license=MIT
LABEL org.opencontainers.image.version=$VERSION
LABEL org.opencontainers.image.created=$BUILD_DATE
