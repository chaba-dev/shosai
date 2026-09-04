ALTER TABLE reading_state ADD COLUMN revision INTEGER NOT NULL DEFAULT 0;

UPDATE reading_state SET revision = rowid;

CREATE TABLE reading_state_revision (
    singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
    value     INTEGER NOT NULL
);

INSERT INTO reading_state_revision (singleton, value)
VALUES (1, COALESCE((SELECT MAX(rowid) FROM reading_state), 0));
