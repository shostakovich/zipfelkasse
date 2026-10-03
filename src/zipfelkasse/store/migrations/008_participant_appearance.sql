-- Look and colour mode of the web app, chosen by each person in the settings.
ALTER TABLE participants ADD COLUMN look TEXT NOT NULL DEFAULT 'clean' CHECK (look IN ('clean', 'felt'));
ALTER TABLE participants ADD COLUMN theme TEXT NOT NULL DEFAULT 'auto' CHECK (theme IN ('auto', 'light', 'dark'));
