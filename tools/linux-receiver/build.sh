#!/bin/sh
set -eu
cd "$(dirname "$0")"
mkdir -p bin
c++ -std=c++17 -O2 -pthread PadDisplayReceiverLinux.cpp -o bin/paddisplay-receiver \
  $(pkg-config --cflags --libs sdl2 libavcodec libavutil libswscale)
echo "Built: $(pwd)/bin/paddisplay-receiver"
