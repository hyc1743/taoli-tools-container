FROM alpine:3.22.2

RUN apk add --no-cache \
  openbox \
  tigervnc \
  chromium \
  python3 \
  py3-pip \
  py3-xdg \
  ca-certificates \
  openssl \
  novnc \
  tailscale \
  tzdata \
  font-noto-cjk \
  font-noto

RUN pip3 install --break-system-packages --no-cache-dir websockify

RUN cp /usr/share/zoneinfo/Asia/Shanghai /etc/localtime

RUN addgroup -S taoli && adduser -S -G taoli -h /home/taoli -s /bin/sh taoli

ADD entrypoint.sh /usr/local/bin/entrypoint.sh
ADD chromium-entrypoint.sh /usr/local/bin/chromium-entrypoint

ADD favicon.ico /usr/share/novnc/
ADD index.html /usr/share/novnc/

ENV DISPLAY=:1 \
  NOVNC_PORT=443 \
  VNC_PORT=5900

RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/chromium-entrypoint

RUN mkdir -p /home/taoli; \
  chown -R taoli:taoli /home/taoli; \
  mkdir -p /home/taoli/data; \
  chown -R taoli:taoli /home/taoli/data; \
  mkdir -p /home/taoli/.local/share/tailscale; \
  chown -R taoli:taoli /home/taoli/.local/share/tailscale;

USER taoli

CMD ["/usr/local/bin/entrypoint.sh"]
