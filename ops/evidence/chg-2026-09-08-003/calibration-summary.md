# kappa calibration - kantoor Fibaro FGMS-001 (device d51c68cc84d57a7924e665c9ab4ff991)

| time (UTC) | lamp | brightness | reported lux | note |
|---|---|---|---|---|
| 2026-09-08T14:45:21 | off | - | 145 | ambient baseline, device heartbeat |
| 2026-09-08T15:15:47 | on | 100% | (no report) | 0->100% did NOT breach param 40 = 200 lux |
| 2026-09-08T15:45:43 | on | 100% | 218 | next hourly heartbeat, exactly 3600 s later |

- Lower bound: kappa >= (218-145)/100 = **0.73 lux per brightness-percent**
  (a lower bound because ambient was declining: 13:44 -> 181, 14:45 -> 145, ~36 lux/h)
- Central estimate: extrapolating ambient to ~109 at 15:45 gives kappa ~ 1.1
- Independent UPPER bound: a full 0 -> 100% swing produced NO threshold report while
  param 40 = 200 lux, therefore the lamp contributes < 200 lux, i.e. **kappa < 2.0**
- Chosen **k = 0.6**, deliberately below the measured lower bound (under-compensation)

## Stability
Discrete map: B_next = f(A + (kappa - k) * B). Max curve slope s = 0.2 %/lux at A=0.
Contraction requires s * |kappa - k| < 1, i.e. |kappa - k| < 5.
Measured band kappa in [0.73, 2.0] with k = 0.6 gives |kappa - k| <= 1.4, so gain <= 0.28.
**Unconditionally stable across the whole measured band**, in both directions of error.
Simulation (HA template API) converged in 2-4 iterations for kappa = 0.73, 1.1 and 2.0.
Residual ripple at the worst case (kappa=2.0) is +/-1 point, entirely inside the 10-point deadband.
