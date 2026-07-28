# DoseDrop — Design Spec (source of truth for all UI work)

Personality: **calm health companion** — soft, rounded, generous whitespace, One UI-style large
headers. Encouraging copy, never guilt-trippy. Everything below is implemented in
`lib/theme/app_theme.dart` (`DD` constants) — **use the constants, never hardcode hex in screens.**

## Palette (validated with the dataviz six-check validator — do not tweak casually)

### Surfaces & ink
| Token | Light | Dark |
|---|---|---|
| bg | `#F6F8F7` | `#0F1412` |
| card | `#FFFFFF` | `#171D1A` |
| cardAlt | `#EEF2F0` | `#1F2622` |
| outline | `#E2E8E5` | `#2A332E` |
| inkPrimary | `#16211D` | `#E8EDEA` |
| inkSecondary | `#4A5A54` | `#A8B5AE` |
| inkMuted | `#78877F` | `#7C8A82` |

### Brand & accents
- Brand teal (primary buttons, active nav, hero): `#0D9488`, pressed `#0F766E`; on-teal text `#FFFFFF`.
- Hero gradient: `#0D9488 → #0F766E` (135°).
- Water accent: light `#0284C7` on fill `#E0F2FE`; dark `#38BDF8` accents, chart bars stay `#0284C7`.

### Med identity colors (categorical, FIXED order, never cycled)
- Light: `#0D9488` teal, `#C2410C` orange, `#0284C7` blue, `#4D7C0F` olive, `#7C3AED` violet, `#BE185D` pink
- Dark:  `#0D9488` teal, `#EA580C` orange, `#0284C7` blue, `#65A30D` lime, `#8B5CF6` violet, `#EC4899` pink
- Both orders passed CVD + normal-vision + contrast checks. A medication keeps its color forever
  (color follows the entity, never its rank/position in a list).

### Status (reserved — NEVER used as series/identity colors; always icon + label, never color alone)
| State | Light | Dark | Icon |
|---|---|---|---|
| taken / good | `#15803D` | `#4ADE80` | check_circle |
| snoozed / warning | `#B45309` | `#FBBF24` | snooze |
| missed | `#B91C1C` | `#F87171` | error |
| skipped | `#64748B` | `#94A3B8` | remove_circle_outline |
| pending | inkMuted | inkMuted | schedule |

## Type & geometry

- System font. Display 30/w800 (screen titles, One UI large-header style), H1 24/w700,
  H2 18/w700, body 15/w400 (height 1.45), label 13/w600, caption 12/w500.
  Timers/countdowns: tabular figures (`FontFeature.tabularFigures()`), w700.
- Spacing on a 4px grid; screen padding 20; section gap 24.
- Radii: cards 20, buttons 14, chips/pills 999, bottom sheets 28 top.
- Touch targets ≥ 48px. Icon buttons get tooltips/semantics labels. Haptic light impact on confirm (mobile).

## Components

- **DoseCard** — 44px rounded-square chip in the med's identity color (white pill icon), name (H2),
  "dosage · HH:mm" (body, inkSecondary), trailing status pill. When **due now**: card elevates,
  border in med color, full-width filled teal button "Mark as taken", text buttons "Snooze 10 min" / "Skip".
  When **overdue**: thin `missed`-color border + "Overdue" pill, same actions.
- **NextUp hero** — gradient teal card: "Next up", med name + dosage, time, live countdown (tabular).
  All-done variant: soft illustration circle + "All done for today 🎉".
- **WaterRing** — 180px ring, 12px stroke, rounded caps; track = outline, fill = water accent;
  center: today's ml (H1, tabular) over "of 2000 ml goal" (caption). Quick-add chip row:
  `+250 ml` (cup), `+500 ml`, `Custom…`. Log list rows with undo.
- **Timeline** — vertical list of today's slots: time (caption, tabular), dot in status color w/ icon, label.
- **AlarmOverlay** — full-screen: bg surface, pulsing ring (med color) around 96px med chip,
  med name (Display), dosage + scheduled time, huge filled "Mark as taken" (min 56px tall),
  row "Snooze 10 min" / "Skip". Loops alarm sound (desktop) until action. Also used for water
  ("Sip time! 💧", water accent, "Log 250 ml" primary).
- **Empty states** — 96px soft cardAlt circle with a large outlined icon + one encouraging line +
  primary CTA (e.g. "Add your first medication").

## Charts (History) — dataviz rules, non-negotiable

- **Weekly water** (single series → no legend; title names it): vertical bars, single hue water
  `#0284C7` both modes; bar width ≤ 24 with ≥ 2px gaps; **4px rounded top corners only** (baseline
  flat); dashed 1px inkMuted goal line labeled "goal"; horizontal hairline grid (outline color)
  only, no vertical grid; axis text caption/inkMuted; **selective direct labels** — value above
  today's bar and the max bar only, in inkPrimary (text never wears the series color).
- **Weekly adherence**: per-day % taken as teal `#0D9488` fill over a cardAlt full-height track
  (remainder is *absence*, not a colored series); label today + best day only. No red/green
  stacking. Detail day view lists each dose with its status icon + label.
- **Stat tiles** (headline numbers): current streak 🔥, best streak, 7-day adherence % — H1 tabular
  number + caption label; tile = card radius 16.
- Tap a bar → highlight + value bubble (mobile tooltip equivalent). One axis only, never dual.
- Dark mode: same rules on dark surfaces; chart colors as specified (they were validated per mode).

## Screens

1. **Today (home)** — large header "Today" + friendly date; NextUp hero; "Due now" DoseCards (if
   any); Water card (compact ring + quick add); compact timeline of today.
2. **Meds** — list of med cards (chip, name, dosage, time chips, day letters, enable switch);
   FAB "+". **MedEditSheet** (bottom sheet, 28px top radius): name, dosage, 6-swatch color picker,
   times list (add/remove via TimePicker), Mon–Sun day toggles, notes, Save; delete inside edit
   with confirm dialog.
3. **Water** — full WaterRing, quick-add row, today's log (undoable), inline settings: goal, cup
   size, interval, active hours (start/end pickers), enable toggle.
4. **History** — week pager (‹ Mon 21 – Sun 27 ›); stat tiles row; adherence chart; water chart;
   tapping a day opens its dose list with status icons.
5. **Settings** — reminder behavior (nag interval, nag count, grace window), alarm sound toggle,
   theme (system/light/dark), desktop: autostart + close-to-tray note, "Send test notification",
   about (version, tagline "Your tablets & water, on time.").
6. **Navigation** — mobile: Material 3 `NavigationBar`, 4 tabs (Today, Meds, Water, History),
   Settings gear in the app bar. Desktop: left `NavigationRail`, default window 1100×720 (min
   900×600), title "DoseDrop"; tray menu: Open DoseDrop / Pause 1 hour / Quit.

## Accessibility

- Text contrast AA on all surfaces (ink tokens guarantee this); status never color-alone
  (icon + label); ring/chart values always readable as text; large-text safe (no fixed-height
  text containers); semantics labels on all icon-only buttons.
