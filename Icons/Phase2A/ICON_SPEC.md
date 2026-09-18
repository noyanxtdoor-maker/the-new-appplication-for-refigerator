# Next Transfer Goal Icon Pilot Specification

## Locked production rules

- ViewBox: `0 0 24 24`
- Primary stroke: `#9DC8CF`
- Accent stroke: `#D7A06E`
- Stroke width: `1.8`
- Rounded line caps and joins
- Transparent background
- No gradients, shadows, glow, or circular tile baked into the SVG
- Gold is limited to one meaningful structural detail
- Goal data stores a permanent `iconId`; renaming a goal does not silently replace a manually chosen icon

## Pilot assets

- `work_briefcase.svg`
- `learning_open_book.svg`
- `finance_wallet.svg`
- `social_two_people.svg`
- `spiritual_temple.svg`
- `marriage_rings.svg`

## Required app test

Render every asset at 24 px, 28 px, and 32 px on both dark and light surfaces.
The included preview sheet is a technical raster check, not a substitute for in-app QA.
