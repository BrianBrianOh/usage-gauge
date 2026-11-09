# v0.4 design: MFD presentation and data validity

This is an aviation-inspired desktop display, not a certified flight instrument or an implementation of a restricted cockpit specification.

## Basis checked on 9 November 2026

- [MIL-STD-1472, ASSIST official revision record](https://quicksearch.dla.mil/qsdocdetails.aspx?ident_number=36903): H, 15 September 2020; Notice 1 validation, 10 April 2026. The recent notice validates the existing revision; it is not a new visual style specification.
- [MIL-STD-1787 official record](https://quicksearch.dla.mil/qsDocDetails.aspx?ident_number=37143): revision D, 16 March 2018, distribution D. Only the public metadata was consulted; restricted contents were not accessed.
- [MIL-HDBK-87213A (USAF), public handbook](https://quicksearch.dla.mil/WMX/Default.aspx?token=463898), 8 February 2005, §§3.2.1.2 and 3.2.1.2.4: consistent HUD/head-down meanings and positive indication when unreliable data is removed. This older public guidance is used for its stated principles, not represented as a 2026 cockpit layout.

The following visual choices are product design decisions derived from those principles.

## Normal mode

Identified issues in v0.3: rounded app cards, bevel gradients and shadows compete with the scale; proportional title typography conflicts with HUD labels; amber service branding overlaps caution semantics; missing readings collapse into a separate empty screen; stale snapshots still drive live-looking references and countdowns; an unknown time bar looks like 0%; the menu bar uses an unexplained dash; and missing forecast history lacks an explicit N/A indication.

Use a flat head-down MFD appearance: restrained rectangular fields, two-point corners, one-pixel rules, uppercase monospaced instrument labels and regular-weight numeric readouts. Preserve rotary detents and direct click/scroll controls while removing plastic gradients and decorative shadows. Keep text and observations off-white; cyan identifies selections and references. Amber means caution or inhibited data; red is reserved for critical limits or the existing pace warning. Service identity is stated by text, not an amber Claude brand color that could be mistaken for a caution.

Use the same REM/TTR captions, calibrated quarter ticks, and symbol meanings in normal and HUD modes. HUD remains transparent green with per-letter/digit/symbol/bar automatic contrast and its existing drag/scroll targets.

## State contract

| State | Observed usage | Live baseline, TTR, pace and forecast | Flag |
| --- | --- | --- | --- |
| Fresh observation, including a real 0% | Measured value | Available where applicable | VALID |
| Known idle window | Measured value | N/A until the window starts | IDLE |
| Waiting for the first observation | N/A | N/A | WAIT |
| Confirmed missing authentication | N/A, even if a cache exists | N/A | AUTH |
| Account has no supported plan meters | N/A | N/A | N/A |
| Read failed without a measurement | N/A | N/A | DATA |
| Old observation or read failure with a cache | Explicit LAST observation | Inhibited | STALE |
| Observed cycle ended | Explicit LAST observation | Inhibited until a new cycle is read | RESET |
| Malformed observation | N/A | Inhibited | INVALID |

Place static diagonal hatching only inside affected instrument fields and tapes. Keep the surrounding layout, scale references, service selector and recovery controls stable. Never draw a zero fill, fully charged bar, centered pace diamond or running countdown as a substitute for missing data. Missing forecast history is independently N/A, not a failure of a valid usage meter. In the menu bar, invalid/stale readings use N/A and a local hatch rather than a live-looking percentage.

Collectors provide explicit error codes. A temporary service failure that happens to mention checking sign-in is not evidence of logout. Old snapshots without the optional code remain readable. A successful read clears failure state. Connection secrets and cached account data are never copied into documentation fixtures.

## Verification

Exercise both providers across full, numeric mini, symbol, and HUD layouts, including fresh zero/100%, initial wait, auth with cached values, no meters, offline, stale, idle, expired and invalid data. Verify that affected indications are suppressed and recover after a fresh read, that no placeholder is mislabeled as zero, and that quarter tick/diamond geometry and independent HUD contrast still hold. Generate review images from the shipping views with synthetic snapshots before installation and packaging.
