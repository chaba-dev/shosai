-- Reattach local state written after migration 010 but before path ownership
-- became authoritative. Only exact path + content identity matches are eligible.
CREATE TEMP TABLE reading_state_path_owner_winners AS
WITH candidates AS (
    SELECT rs.*,
           COALESCE(rs.book_id, aliases.book_id) AS owner_id,
           ROW_NUMBER() OVER (
               PARTITION BY COALESCE(rs.book_id, aliases.book_id)
               ORDER BY rs.revision DESC, rs.updated_at DESC, rs.id DESC
           ) AS winner
    FROM reading_state AS rs
    LEFT JOIN book_path_aliases AS aliases
      ON rs.book_id IS NULL
     AND aliases.file_path = rs.file_path
     AND aliases.content_hash = rs.content_hash
    WHERE rs.book_id IS NOT NULL OR aliases.book_id IS NOT NULL
), affected AS (
    SELECT DISTINCT aliases.book_id
    FROM reading_state AS rs
    JOIN book_path_aliases AS aliases
      ON aliases.file_path = rs.file_path
     AND aliases.content_hash = rs.content_hash
    WHERE rs.book_id IS NULL
)
SELECT candidates.*
FROM candidates
JOIN affected ON affected.book_id = candidates.owner_id
WHERE candidates.winner = 1;

DELETE FROM reading_state
WHERE book_id IN (SELECT owner_id FROM reading_state_path_owner_winners)
   OR id IN (
       SELECT rs.id
       FROM reading_state AS rs
       JOIN book_path_aliases AS aliases
         ON aliases.file_path = rs.file_path
        AND aliases.content_hash = rs.content_hash
       WHERE rs.book_id IS NULL
         AND aliases.book_id IN (SELECT owner_id FROM reading_state_path_owner_winners)
   );

INSERT INTO reading_state
    (file_path, page, zoom, updated_at, location_offset, book_id, revision, content_hash)
SELECT aliases.file_path, winner.page, winner.zoom, winner.updated_at,
       winner.location_offset, winner.owner_id, winner.revision, aliases.content_hash
FROM reading_state_path_owner_winners AS winner
JOIN books AS aliases ON aliases.id = winner.owner_id;

DROP TABLE reading_state_path_owner_winners;

CREATE TEMP TABLE bookmark_path_owners AS
SELECT bookmarks.id, aliases.book_id AS owner_id
FROM bookmarks
JOIN book_path_aliases AS aliases
  ON aliases.file_path = bookmarks.file_path
 AND aliases.content_hash = bookmarks.content_hash
WHERE bookmarks.book_id IS NULL;

-- Preserve stable bookmark IDs, while retaining the newest duplicate's metadata.
UPDATE bookmarks AS stable
SET (title, color, created_at) = (
    SELECT candidate.title, candidate.color, candidate.created_at
    FROM bookmarks AS candidate
    LEFT JOIN bookmark_path_owners AS mapped ON mapped.id = candidate.id
    WHERE COALESCE(candidate.book_id, mapped.owner_id) = stable.book_id
      AND candidate.page = stable.page
      AND candidate.location_offset IS stable.location_offset
      AND candidate.note IS stable.note
    ORDER BY candidate.created_at DESC, candidate.id DESC
    LIMIT 1
)
WHERE stable.book_id IN (SELECT owner_id FROM bookmark_path_owners);

DELETE FROM bookmarks
WHERE id IN (
    SELECT id FROM (
        SELECT bookmarks.id,
               ROW_NUMBER() OVER (
                   PARTITION BY COALESCE(bookmarks.book_id, mapped.owner_id),
                                bookmarks.page, bookmarks.location_offset, bookmarks.note
                   ORDER BY (bookmarks.book_id IS NOT NULL) DESC,
                            bookmarks.created_at DESC, bookmarks.id DESC
               ) AS duplicate_rank
        FROM bookmarks
        LEFT JOIN bookmark_path_owners AS mapped ON mapped.id = bookmarks.id
        WHERE bookmarks.book_id IN (SELECT owner_id FROM bookmark_path_owners)
           OR mapped.owner_id IS NOT NULL
    )
    WHERE duplicate_rank > 1
);

UPDATE bookmarks
SET book_id = (SELECT owner_id FROM bookmark_path_owners WHERE id = bookmarks.id)
WHERE id IN (SELECT id FROM bookmark_path_owners);

DROP TABLE bookmark_path_owners;
