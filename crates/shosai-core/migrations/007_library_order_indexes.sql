CREATE INDEX IF NOT EXISTS books_library_order_idx
    ON books(last_read DESC, date_added DESC, id DESC);

CREATE INDEX IF NOT EXISTS books_format_library_order_idx
    ON books(format, last_read DESC, date_added DESC, id DESC);
