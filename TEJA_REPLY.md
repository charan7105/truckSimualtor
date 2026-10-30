# Reply to Teja — speed fix in stored packets

Hi Teja,

Good catch. You were right.

The stored dump had ignition on but speed was 0 in all the packets. So every stored packet was
going into the app's on-duty branch (`speed <= 5 && ignition == 1`) and the driving branch
(`speed >= 5`) was never tested at all.

Fixed now — stored packets go at 60 mph.

One thing to note: the two new buttons I added yesterday (future date and duplicates) use the same
builder, so they were also sending speed 0 packets. If you already tested them, please test again.

Build is live, please take the latest:
**https://truck-simualtor.vercel.app**

Test steps are the same as before:

- **Saved data dated in the future (2030)** — 5 stored packets dated 1 Jan 2030, app should skip all of them
- **Same saved data sent twice** — each packet sent twice, second one should be dropped
- **Send the same saved data again after reconnect** — dump, press DROP, wait for reconnect, then press this

All three are in **BAD DATA** in the bottom bar (CONNECTION → Bad data), last section.
