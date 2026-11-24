Fixtures for `vm-golden-build --check-console` (tests/golden-console.test.sh, chg-2026-11-06-005).

- `golden-console-good-109s.log`: the real pass 1 serial console of run 3 on vdhwslin01 (2026-11-24, 109 s,
  clean power-off), trimmed to its first 40 lines and the lines from cloud-init's "finished" onwards. Lines with
  ssh keys, key fingerprints, randomart and `ci-info` tables were removed.
- `golden-console-bad-*.log`: the good log with one marker removed or broken (no banner, no finished line, no
  power down, power down before finished, two GRUB boots), and the run 2 reset loop shape (only the 56-byte GRUB
  line, 50 times).
- Argus F1 probes (2026-11-24): banner after "finished", a spoofed "finished" line before GRUB (real one removed),
  "reboot: Restarting system" after power down, a "Kernel panic" line, and a kernel line after power down.
