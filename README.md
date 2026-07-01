# ZEBRA PARABOLIC MT5

MT5 Expert Advisor project for Parabolic SAR stop-and-reverse trading logic.

## Current version

- `Experts/ZEBRA_PARABOLIC_V6.mq5` — V6.00 foundation.

## Core concept

- Uses MT5 built-in Parabolic SAR (`iSAR`).
- One managed position at a time.
- Partial profit by money target and close percent.
- After partial, opposite SAR flip forgets old layer and opens new managed opposite position.
- Forgotten positions are not managed further by the EA.
