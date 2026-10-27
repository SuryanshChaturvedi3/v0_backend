-- Migration: add outcome_type to match table
-- Purpose: Store the semantic result of a match separately from the numeric score.
--
-- WHY this column exists:
--   A Walkover cannot be inferred from score alone. A score of 0-0 could mean
--   "match not yet played", "both teams defaulted", or a genuine 0-0 draw in a
--   sport that allows it. Using outcome_type as the authoritative source of truth
--   keeps business logic clean and avoids silent misinterpretation.
--
-- WHY default is 'normal':
--   All existing matches were played to completion with real scores. Defaulting
--   to 'normal' means this migration is backward-compatible — no existing row
--   changes its meaning.
--
-- WHY VARCHAR(20) and not ENUM:
--   ENUM requires an ALTER TABLE to add new values. VARCHAR allows adding
--   'forfeit', 'bye', etc. at the application layer without a schema change.
--
-- Run this once against your local 'test' database:
--   mysql -u root -p test < migrations/walkover/add_outcome_type.sql

ALTER TABLE `match`
  ADD COLUMN `outcome_type` VARCHAR(20) NOT NULL DEFAULT 'normal'
  COMMENT 'Semantic match result: normal | walkover | forfeit | bye';
