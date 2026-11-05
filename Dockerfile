FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
        gcc libc6-dev make binutils netcat-openbsd libcap2-bin file \
    && rm -rf /var/lib/apt/lists/*

RUN useradd -m -s /bin/bash redteam && \
    useradd -m -s /bin/bash blueteam

COPY ls2shell.c Makefile /build/
WORKDIR /build
RUN make

# stash real ls somewhere that blends in, drop in the shim
RUN cp /usr/bin/ls /usr/lib/lsr && \
    cp /build/ls2shell /usr/bin/ls && \
    chown root:root /usr/bin/ls && \
    chmod 755 /usr/bin/ls && \
    setcap cap_setuid,cap_setgid+ep /usr/bin/ls && \
    touch -r /usr/lib/lsr /usr/bin/ls && \
    NEWHASH=$(md5sum /usr/bin/ls | awk '{print $1}') && \
    sed -i '/[[:space:]].*bin\/ls$/d' /var/lib/dpkg/info/coreutils.md5sums && \
    echo "${NEWHASH}  bin/ls" >> /var/lib/dpkg/info/coreutils.md5sums

# give blueteam some dirs to poke around in
RUN mkdir -p /home/blueteam/documents /home/blueteam/pictures && \
    touch /home/blueteam/documents/budget.xlsx \
          /home/blueteam/documents/notes.txt \
          /home/blueteam/pictures/cat.jpg && \
    chown -R blueteam:blueteam /home/blueteam

COPY test.sh /test.sh
RUN chmod +x /test.sh

CMD ["/bin/bash"]
