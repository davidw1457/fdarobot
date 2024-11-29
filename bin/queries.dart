const insertRecallTemplate = '''INSERT INTO recalls (
  Title,
  Link,
  Descript,
  PubDate
)
  VALUES
###VALUE###;''';

const checkExist = '''SELECT *
FROM recalls
LIMIT 1;''';

const createDB = '''DROP TABLE IF EXISTS recalls;

CREATE TABLE recalls (
  Title     TEXT NOT NULL,
  Link      TEXT NOT NULL PRIMARY KEY,
  Descript  TEXT NOT NULL,
  PubDate   TEXT NOT NULL,
  uri       TEXT,
  cid       TEXT
)''';

const selectToPost = '''SELECT
  Title,
  Link,
  Descript
FROM recalls
WHERE
  uri IS NULL
  AND PubDate >= '###DATE###'
ORDER BY
  PubDate ASC;''';