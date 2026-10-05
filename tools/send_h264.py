#!/usr/bin/env python3
import argparse,socket,struct,time
p=argparse.ArgumentParser(description="Send Annex-B H.264 to PadDisplay")
p.add_argument("host");p.add_argument("file");p.add_argument("--chunk",type=int,default=32768);p.add_argument("--delay",type=float,default=.002)
a=p.parse_args()
with socket.create_connection((a.host,4822)) as s,open(a.file,"rb") as f:
    while True:
        d=f.read(a.chunk)
        if not d:break
        s.sendall(struct.pack(">IB",len(d),1)+d)
        if a.delay:time.sleep(a.delay)
    s.sendall(struct.pack(">IB",0,4))
