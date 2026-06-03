# Dockerfile for ALT Linux syzkaller environment
FROM alt:p11

ARG USERNAME=user
ARG UID=1000
ARG GID=1000

ENV USER=${USERNAME}
ENV HOME=/home/${USERNAME}

# Update packages and install dependencies
RUN apt-get update		&& \
    apt-get dist-upgrade -y	&& \
    apt-get install -y	\
        sudo				\
	git				\
	make				\
	bison				\
	gcc-c++				\
	flex				\
	libelf-devel			\
	libssl-devel			\
	wget				\
	libdw-devel			\
	zlib-devel			\
	openssl				\
	fdisk				\
	patch				\
	losetup				\
	mount				\
	gettext				\
	go				\
	libstdc++-devel-static		\
	meson				\
	glibc-devel-static		\
	zlib-devel-static		\
	glib2-devel-static		\
	libpcre2-devel-static		\
	libattr-devel-static		\
	libdw-devel-static		\
	libatomic-devel-static		\
	glib2-devel			\
	libgio-devel			\
	makeinfo			\
	perl-devel			\
	python3-module-sphinx		\
	python3-module-sphinx_rtd_theme	\
	libcap-ng-devel			\
	libxfs-devel			\
	libcurl-devel			\
	libpci-devel			\
	libfdt-devel			\
	libpixman-devel			\
	libkeyutils-devel		\
	python3-devel			\
	libSDL2-devel			\
	libSDL2_image-devel		\
	libncursesw-devel		\
	libalsa-devel			\
	libpulseaudio-devel		\
	libjpeg-devel			\
	libpng-devel			\
	libxkbcommon-devel		\
	xkeyboard-config-devel		\
	libaio-devel			\
	liburing-devel			\
	libbpf-devel			\
	libspice-server-devel		\
	spice-protocol			\
	libuuid-devel			\
	libcacard-devel			\
	libusbredir-devel		\
	libepoxy-devel			\
	libgbm-devel			\
	ceph-devel			\
	libvitastor-devel		\
	libiscsi-devel			\
	libnfs-devel			\
	libzstd-devel			\
	libseccomp-devel		\
	libgtk+3-devel			\
	libgnutls-devel			\
	libselinux-devel		\
	libqpl-devel			\
	libpam-devel			\
	libtasn1-devel			\
	libslirp-devel			\
	libssh-devel			\
	libusb-devel			\
	rdma-core-devel			\
	libnuma-devel			\
	liblzo2-devel			\
	libsnappy-devel			\
	bzlib-devel			\
	libudev-devel			\
	libmultipath-devel		\
	libpmem-devel			\
	libdaxctl-devel			\
	libfuse3-devel			\
	libdrm-devel			\
	pipewire-libs-devel		\
	libcapstone-devel		\
	libglusterfs11-api-devel	\
	libvirglrenderer-devel		\
	libvte-devel			\
    && \
    apt-get clean

# Optional user tools
RUN apt-get update		&& \
    apt-get install -y	\
	e2fsprogs			\
	gdisk				\
	kpartx				\
	parted				\
	bash-completion			\
	procps				\
	bc				\
	curl				\
	vim-common			\
	nano				\
	perl-JSON-PP			\
	python3-module-beautifulsoup4	\
	python3-module-odfpy		\
    && \
    apt-get clean

# Create a non-root user
RUN groupadd -g ${GID} ${USERNAME}				&& \
    useradd  -u ${UID} -g ${GID} -ms /bin/bash ${USERNAME}	&& \
    usermod  -aG wheel,proc,sys,disk ${USERNAME}		&& \
    echo "${USERNAME} ALL=(root) NOPASSWD:ALL" > /etc/sudoers.d/${USERNAME}

USER ${USERNAME}
WORKDIR /home/${USERNAME}

# Copy all project files into the container
COPY --chown=${USERNAME}:${USERNAME} . /home/user/alt-syz-box
WORKDIR /home/user/alt-syz-box

CMD ["/bin/bash"]
