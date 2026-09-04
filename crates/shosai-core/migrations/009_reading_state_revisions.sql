ALTER TABLE reading_state ADD COLUMN revision INTEGER NOT NULL DEFAULT 0;

WITH ordered AS (
    SELECT rowid, ROW_NUMBER() OVER (ORDER BY updated_at, rowid) AS revision
    FROM reading_state
)
UPDATE reading_state
SET revision = (SELECT revision FROM ordered WHERE ordered.rowid = reading_state.rowid);

CREATE TABLE reading_state_revision (
    singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
    value     INTEGER NOT NULL
);

INSERT INTO reading_state_revision (singleton, value)
VALUES (1, COALESCE((SELECT MAX(revision) FROM reading_state), 0));
