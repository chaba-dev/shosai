INSERT INTO sources (id, name, website)
VALUES ('gutenberg', 'Project Gutenberg', 'https://www.gutenberg.org/');
INSERT INTO books VALUES ('gutenberg:1342', 'Pride and Prejudice');
INSERT INTO authors (id, name, sort_name)
VALUES ('gutenberg:68', 'Jane Austen', 'Austen, Jane');
INSERT INTO book_authors VALUES ('gutenberg:1342', 'gutenberg:68', 0);
INSERT INTO subjects VALUES ('lcsh:courtship', 'Courtship -- Fiction');
INSERT INTO book_subjects VALUES ('gutenberg:1342', 'lcsh:courtship');
INSERT INTO categories VALUES ('classics', 'Classics');
INSERT INTO book_categories VALUES ('gutenberg:1342', 'classics');
-- Synthetic acquisition URLs: the fixture does not depend on live endpoints.
INSERT INTO editions (
  source_id, source_edition_id, book_id, title, variant_label, display_order, language, source_url,
  rights_line, acquisition_url, acquisition_format, size_bytes
) VALUES
  ('gutenberg', '1342:a', 'gutenberg:1342', 'Pride and Prejudice', 'Without images', 1, 'en',
   'https://www.gutenberg.org/ebooks/1342', 'Public domain in the USA',
   'https://example.invalid/1342-noimages.epub', 'epub', NULL),
  ('gutenberg', '1342:z', 'gutenberg:1342', 'Pride and Prejudice', 'With images', 0, 'en',
   'https://www.gutenberg.org/ebooks/1342', 'Public domain in the USA',
   'https://example.invalid/1342-images.epub', 'epub', 123456);
