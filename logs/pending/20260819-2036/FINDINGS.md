# Findings

Run 20260819-2036 (target 192.168.1.213): ~20 deep-suspend attempts
aborted at the /sys/power/state write (ETIMEDOUT, once EBUSY).
Phase 24 succeeded - 61 s asleep, 1 s drift - and named the suspect:
lt8912 3-0048 (Lontium LT8912B DSI-HDMI bridge) resume callback returns -6.
Open item: todo/002-lt8912-suspend-abort.md.

Also drove todo/004: write-failure path printed no dmesg (now fixed),
first_eth picked can0 (now fixed), .swp files got pushed (now excluded).
