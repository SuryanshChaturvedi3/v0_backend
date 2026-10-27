# Khel Club — FDE Intern Assignment
### Feature: Walkover Match Outcome

---

## How the Current Scoring Mechanism Works

Every match in the system has a status lifecycle:

```
pending → on-going → completed
```

**Step-by-step flow:**

1. A match is created (`POST /create-match`) with two `Score` rows initialised to `0` for each team.
2. The referee navigates to `/referee/<tournament_id>/matches/<match_id>`.
3. **Start:** referee clicks Start Match → `POST /update-match-status` sets `match.status = 'on-going'`.
4. **Live scoring:** referee uses +1/−1 controls and clicks Update → `POST /update-score` with `final: false` saves the running score without finalising.
5. **Finalise:** referee clicks Final → `POST /update-score` with `final: true` fires simultaneously with `POST /update-match-status` (`status: 'completed'`).
6. **Winner determination:** inside `update_score()` in `routes/score/score_core.py`, the backend compares the two integer scores:

```python
if team1_score > team2_score:
    match.winner_team_id = match.team1_id
elif team2_score > team1_score:
    match.winner_team_id = match.team2_id
else:
    match.winner_team_id = None  # draw
```

7. **Knockout propagation:** if `match.successor` is set (knockout bracket), `update_successor_match()` copies the winner into the next match's `team1_id` or `team2_id`.
8. **Standings:** `routes/tournament/tournament_core.py` calculates standings using raw SQL that JOINs `match` and `score`, counting wins by comparing score integers. A `0-0` result is explicitly skipped as unplayed:

```python
if match.team1_score == 0 and match.team2_score == 0:
    continue  # treated as unplayed
```

The entire scoring system is score-integer-driven. There is no concept of *how* a match was won — only *what the scores were*.

---

## What Changes Were Made and Why

### The Problem

The existing system has no way to represent a match outcome where a winner is awarded without playing. A walkover could not be inferred from a score:

- `0-0` → ambiguous: could be unplayed, a genuine draw, or a double default
- `1-0` → ambiguous: could be a real game result or a walkover marker
- `is_final = True` with `0-0` → still breaks standings (the `0-0` skip logic ignores it)

Any attempt to shoehorn a walkover through `POST /update-score` would create silent data ambiguity between a real `1-0` result and a walkover.

### The Solution

**A dedicated `outcome_type` column and a dedicated `POST /declare-walkover` endpoint.**

`outcome_type` is the single, authoritative source of truth for *how* a match ended. The score remains the source of truth for *what the result was numerically*.

| outcome_type | Meaning | Score stored | UI displays |
|---|---|---|---|
| `normal` | Match played to completion | Actual game score | Numeric score |
| `walkover` | Win awarded without playing | `1-0` (internal) | **Walkover** badge |

**Why a separate endpoint and not modifying `POST /update-score`:**

`POST /update-score` parses a `"X-Y"` score string, requires both sides to have scores, and determines the winner by integer comparison. Modifying it to also handle walkovers would mix two distinct business flows into one function — making it harder to reason about, test, and extend. A dedicated `POST /declare-walkover` keeps both paths independent and explicit.

**Why `outcome_type` and not a boolean `is_walkover`:**

A boolean cannot scale. `outcome_type = VARCHAR(20)` with default `'normal'` allows `'forfeit'`, `'bye'`, and any future outcome to be added at the application layer with no schema change.

**Why the existing `POST /update-score` is untouched:**

All existing normal match scoring continues to work exactly as before. The only change to the normal flow is two additive fields (`outcome_type`) added to GET API responses — no existing fields were removed or modified.

---

## Schema and Migration Changes

### New column: `match.outcome_type`

**Migration file:** `migrations/walkover/add_outcome_type.sql`

```sql
ALTER TABLE `match`
  ADD COLUMN `outcome_type` VARCHAR(20) NOT NULL DEFAULT 'normal'
  COMMENT 'Semantic match result: normal | walkover | forfeit | bye';
```

**Why `VARCHAR(20)` and not `ENUM`:**
`ENUM` in MySQL requires an `ALTER TABLE` to add new values. `VARCHAR` allows adding `'forfeit'`, `'bye'` etc. at the application layer without touching the schema again.

**Why default `'normal'`:**
All existing matches were played with real scores. Defaulting to `'normal'` means every existing row retains its meaning — the migration is fully backward-compatible.

**Model update — `models.py`, `Match` class:**

```python
outcome_type = db.Column(db.String(20), nullable=False, default='normal')
# 'normal'   — played to completion with real scores
# 'walkover' — winner awarded without playing
# Future:      'forfeit', 'bye', etc.
```

**Run the migration:**

```bash
mysql -u root -p test < migrations/walkover/add_outcome_type.sql
```

### Internal 1-0 score for standings compatibility

When a walkover is declared, the backend inserts `score = 1` for the winner and `score = 0` for the loser. This is an internal implementation detail.

**Why not `0-0`:** The standings queries skip `0-0` matches as unplayed. A walkover winner would not receive a win in standings.

**Why not modify the standings SQL:** Inserting `1-0` makes the existing standings queries count the win correctly without any changes to `routes/tournament/tournament_core.py` or `routes/round/round_completion.py`.

**The frontend never uses the `1-0` score for display.** It reads `outcome_type === 'walkover'` and shows a badge. A genuine `1-0` game (`outcome_type = 'normal'`) continues to show its numeric score.

---

## Assumptions Made

1. A walkover can be declared on a `pending` or `on-going` match. It cannot be declared on a match that is already finalised (`is_final = True`).
2. The walkover winner must be one of the two teams in that specific match. Any other team ID is rejected with a `400`.
3. No score entry is required before declaring a walkover — the referee goes directly from pending to completed.
4. The `1-0` internal score is an implementation detail. The product-level outcome is always determined by `outcome_type`, not by the score value.
5. Knockout bracket progression for a walkover works identically to a normal match — the bracket only cares about who won, not how.
6. No UI redesign was done. The Walkover button and badge follow the existing visual patterns (MUI dialogs, existing status badge styles).
7. The `outcome_type` column is `NOT NULL DEFAULT 'normal'` — no existing data or query needs to handle a null case.

---

## What I Would Improve With More Time

1. **Generalise the endpoint** — rename `POST /declare-walkover` to `POST /declare-outcome` and accept `outcome_type` as a request parameter. This makes one endpoint serve walkover, forfeit, bye, etc. instead of needing a new endpoint per outcome type.

2. **Add a `outcome_reason` field** — a free-text or enum `reason` column on `match` (e.g. `"team_no_show"`, `"player_injury"`) for audit and reporting purposes.

3. **Show the winner's name in the badge** — instead of just "Walkover", show "Walkover — John Smith wins" on the fixture card.

4. **Backend unit tests** — add tests for `declare_walkover()` covering: valid walkover, invalid team ID, already-finalised match, knockout propagation.

5. **Admin override flow** — allow a finalised walkover to be reversed (currently blocked by the `is_final` guard), with an appropriate confirmation step.

6. **Standings display distinction** — show walkover wins separately from played wins in the standings table, so organisers can see `W (2 played, 1 walkover)` rather than a flat win count.

---

## `/declare-walkover` API Reference

### Endpoint

```
POST /declare-walkover
```

### Request

```json
{
    "match_id": 7,
    "tournament_id": 1,
    "winner_team_id": "T001"
}
```

### Validation rules

| Rule | Response |
|---|---|
| Any field missing | `400` |
| Match not found | `404` |
| `winner_team_id` not in the match | `400` |
| Match already finalised | `400` |

### On success — DB state

```python
match.outcome_type    = 'walkover'
match.winner_team_id  = winner_team_id   # explicitly supplied
match.is_final        = True
match.status          = 'completed'
# Score rows: winner=1, loser=0
```

### Success response

```json
{
    "message": "Walkover declared successfully",
    "match_id": 7,
    "tournament_id": 1,
    "outcome_type": "walkover",
    "winner_team_id": "T001",
    "is_final": true,
    "status": "completed"
}
```

---

## GET API Changes — `outcome_type` Propagated to Frontend

Both fixture endpoints were updated to include `outcome_type` as an additive field (no existing fields changed):

**`GET /get-match-fixtures?tournament_id=<id>`** — `routes/match/match_fixtures.py`

```json
"match_status": {
    "winner_team_id": "T001",
    "is_final": true,
    "status": "completed",
    "outcome_type": "walkover"
}
```

**`GET /score/match?match_id=<id>&tournament_id=<id>`** — `routes/score/score_core.py`

```json
{
    "match_id": 7,
    "outcome_type": "walkover",
    "winner_team_id": "T001",
    "is_final": true,
    "status": "completed",
    "team1": { ... },
    "team2": { ... }
}
```

---

## Files Changed

### Backend

| File | Change |
|---|---|
| `models.py` | Added `outcome_type` column to `Match` class |
| `migrations/walkover/add_outcome_type.sql` | New file — `ALTER TABLE match ADD COLUMN outcome_type` |
| `routes/score/score_core.py` | Added `POST /declare-walkover`; added `outcome_type` to `GET /score/match` response |
| `routes/match/match_fixtures.py` | Added `outcome_type` to `match_status` in `GET /get-match-fixtures` response |
| `app.py` | `use_reloader=False` — fixes gevent + Werkzeug reloader deadlock on Windows/Python 3.13 (local dev only; no effect in production) |

### Frontend

| File | Change |
|---|---|
| `src/store/urls.js` | Added `declareWalkover: baseurl + "/declare-walkover"` |
| `src/screen/referee/match/Match.js` | Added `outcomeType` state; orange Walkover button; winner selection modal; status dialog no longer navigates away on dismiss for pending matches |
| `src/components/refereeMatchTable/RefereeMatchTable.js` | Walkover button in Actions column (pending + on-going); winner selection modal; Walkover badge in result column |
| `src/components/fixtures/Fixtures.js` | Walkover badge on match cards in `renderMatches()` |
| `src/components/fixtures/RefereeFixtures.js` | Walkover badge on referee match cards |
| `src/components/matchTable/MatchTable.js` | Walkover badge in result column instead of `1-0` score |
| `src/components/fixtures/Fixtures.module.scss` | Added `.walkoverBadge` (orange pill) |
| `src/components/refereeMatchTable/RefereeMatchTable.module.scss` | Added `.walkoverButton` (orange button) |

---

## Future Outcome Types — Forfeit, Bye

To add a new outcome type (e.g. `'forfeit'`):

1. No schema change — `outcome_type` is already `VARCHAR(20)`.
2. Add a new endpoint (or extend `/declare-walkover` into `/declare-outcome`) to set `outcome_type = 'forfeit'`.
3. Add one condition in each frontend display component:
   ```jsx
   {match.match_status?.outcome_type === 'forfeit' && <span>Forfeit</span>}
   ```
4. Winner propagation, standings compatibility, and knockout logic require no changes.

---

## How to Run and Test

### Setup

```bash
# Backend
cd backend
pip install -r requirements.txt

# Create backend/.env
# DB_HOST=localhost
# DB_USER=root
# DB_PASSWORD=<your password>
# DB_NAME=test
# DB_PORT=3306

mysql -u root -p test < dump-test-202512221924.sql
mysql -u root -p test < migrations/walkover/add_outcome_type.sql

python app.py
# → http://localhost:5001
```

```bash
# Frontend
cd frontend
npm install
npm run dev
# → http://localhost:3000
```

### Test the Walkover (UI)

1. Go to `http://localhost:3000/referee`
2. Enter Tournament ID `1`, select Season and Category → **View Matches**
3. Click the **Table** tab
4. Click the orange **Walkover** button on any pending match
5. Select the winning team in the modal
6. Result column shows orange **Walkover** badge — status becomes `completed`

### Test the Walkover (API)

```bash
# Declare walkover — T001 wins match 8
curl -X POST http://localhost:5001/declare-walkover \
  -H "Content-Type: application/json" \
  -d '{"match_id": 8, "tournament_id": 1, "winner_team_id": "T001"}'

# Verify outcome_type appears in fixtures
curl "http://localhost:5001/get-match-fixtures?tournament_id=1"

# Invalid winner — expect 400
curl -X POST http://localhost:5001/declare-walkover \
  -H "Content-Type: application/json" \
  -d '{"match_id": 9, "tournament_id": 1, "winner_team_id": "T999"}'
```

### Verification checklist

| Test | Expected |
|---|---|
| Normal `POST /update-score` | Works unchanged, `outcome_type = 'normal'` |
| Walkover — team1 wins | `outcome_type='walkover'`, `winner_team_id=team1_id` |
| Walkover — team2 wins | `outcome_type='walkover'`, `winner_team_id=team2_id` |
| Invalid `winner_team_id` | `400` |
| Already finalised match | `400` |
| Fixture API | `outcome_type` present in `match_status` |
| UI badge | Orange **Walkover** badge on completed walkover match |
| Normal `1-0` game | Shows `1-0` score, no badge (`outcome_type='normal'`) |
| Standings | Walkover winner's win count increments correctly |
