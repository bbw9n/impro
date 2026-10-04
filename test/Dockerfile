# Linux, headless: Emacs with Cairo (records itself), Xvfb, ffmpeg.
FROM debian:trixie-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
      emacs-gtk xvfb ffmpeg fonts-dejavu-core \
 && rm -rf /var/lib/apt/lists/*
