import 'dart:io';

import 'package:dart_rss/dart_rss.dart';
import 'package:html/parser.dart' as parser;
import 'package:http/http.dart' as http;
import 'package:sqlite3/sqlite3.dart';
import 'package:bluesky/atproto.dart' as at;
import 'package:bluesky/bluesky.dart' as bsky;
import 'package:bluesky_text/bluesky_text.dart' as bskytxt;

import 'queries.dart' as qry;
import 'creds.dart' as cred;

void main(List<String> arguments) async {
  print("getting recalls");

  final rssRecalls = await _getRSSRecalls();
  if (rssRecalls.isEmpty) {
    print("no recalls returned by rss");
    exit(1);
  }

  print("opening database");
  final Database db;
  try {
    db = _openDatabase();
  } catch (e) {
    print(e);
    exit(1);
  }

  print("updating databse");
  final toPost = _insertRecalls(db, rssRecalls);

  print("posting updates");
  if (toPost) {
    print("there are things to post");
    final postCount = await _postUpdates(db);
    print("$postCount updates posted");
    exit(0);
  }
  print("nothing to post");
  exit(0);
}

Future<Map<String, Map>> _getRSSRecalls() async {
  print("_getRSSRecalls: getting recalls");

  final uri = Uri.https('www.fda.gov', 'about-fda/contact-fda/stay-informed/rss-feeds/recalls/rss.xml');
  final http.Response resp;

  print("_getRSSRecalls: executing GET");
  try {
    resp = await http.get(uri);
  } catch (e) {
    print('_getRSSRecalls: $e');
    return {};
  }

  print("_getRSSRecalls: checking statuscode");
  if (resp.statusCode < 200 || resp.statusCode > 299) {
    print(
        '_getRSSRecalls: error. statuscode: ${resp.statusCode} body: ${resp.body}');
    return {};
  }

  final Map<String, Map> rssData = {};
  final channel = RssFeed.parse(resp.body);
  for (final item in channel.items) {
    if (item.link != null) {
      final Map<String, String> recall = {
        "title": item.title ?? '',
        "descript": item.description ?? '',
        "pubDate": item.pubDate ?? '',
      };
      rssData[item.link!] = recall;
    }
  }

  return rssData;
}

Database _openDatabase() {
  final String homeDir = Platform.environment['HOME'] ?? '';

  final databaseDir = Directory('$homeDir/.fdarecallbot');
  if (!databaseDir.existsSync()) {
    databaseDir.createSync();
  }

  final db = sqlite3.open('${databaseDir.path}/frb.db');

  if (_isNew(db)) {
    _initializeDB(db);
  }

  return db;
}

bool _isNew(Database db) {
  final ResultSet results;
  try {
    results = db.select(qry.checkExist);
  } on SqliteException catch (e) {
    if (e.message == 'no such table: recalls') {
      return true;
    }
    print('_isNew: $e');
    rethrow;
  } catch (e) {
    print('_isNew: $e');
    rethrow;
  }
  return results.isEmpty;
}

void _initializeDB(Database db) {
  try {
    db.execute(qry.createDB);
  } catch (e) {
    print('_initializeDB: $e');
    rethrow;
  }
}

bool _insertRecalls(Database db, Map<String, Map> recalls) {
  var newRecalls = false;
  for (final k in recalls.keys) {
    final String recallValue = _recallValue(k, recalls[k]!);
    final String qryInsertRecall = qry.insertRecallTemplate.replaceAll('###VALUE###', recallValue);
    try {
      db.execute(qryInsertRecall);
    } on SqliteException catch (e) {
      if (e.explanation == 'constraint failed (code 1555)') {
        continue;
      }

      print('_insertRecalls: $e');
      print(qryInsertRecall);

      continue;
    } catch (e) {
      print('_insertRecalls: $e');
      print(qryInsertRecall);

      continue;
    }
    newRecalls = true;
  }
  return newRecalls;
}

String _recallValue(String l, Map v) {
  var pubDate = _toFormattedDateString(v['pubDate']);
  final List<String> values = [
    _sanitizeSqlString(v['title']),
    _sanitizeSqlString(l),
    _sanitizeSqlString(v['descript']),
    _sanitizeSqlString(pubDate),
  ];
  final String value = "('${values.join("','")}')";
  return value;
}

String _sanitizeSqlString(String s) {
  return s.replaceAll("'", "''");
}

String _toFormattedDateString(String d) {
  var fields = d.split(' ');
  var year = fields[3];
  var month = _months[fields[2]];
  var day = fields[1].padLeft(2,'0');
  return '$year-$month-$day';
}

Future<int> _postUpdates(Database db) async {
  var posted = 0;
  final ResultSet results;
  try {
    final threshold = DateTime.now().subtract(const Duration(days: 7));
    final year = '${threshold.year}';
    final month = '${threshold.month}'.padLeft(2, '0');
    final day = '${threshold.day}'.padLeft(2, '0');
    final thresholdStr = '$year-$month-$day';
    final qrySelectToPost = qry.selectToPost.replaceAll('###DATE###', thresholdStr);
    results = db.select(qrySelectToPost);
  } catch (e) {
    print('_postUpdates: $e');
    rethrow;
  }

  final session = await at.createSession(
    identifier: cred.username,
    password: cred.password,
  );

  final bskysesh = bsky.Bluesky.fromSession(session.data);

  for (final r in results) {
    if (r['Title'] == null || r['Title'] == '') {
      print('_postUpdates: no title: $r');
      continue;
    }
    final List<at.StrongRef> titlerefs = [];
    for (final p in _postTitles) {
      final post = _createPost(p, r);
      if (post.value.isEmpty) {
        continue;
      }
      for (final s in post.split()) {
        final bsky.ReplyRef? reply;
        if (titlerefs.isNotEmpty) {
          reply = bsky.ReplyRef(
            root: titlerefs.first,
            parent: titlerefs.last,
          );
        } else {
          reply = null;
        }

        final facets = await s.entities.toFacets();
        final strongRef = await bskysesh.feed.post(
            text: post.value,
            reply: reply,
            facets: facets.map(bsky.Facet.fromJson).toList());
        titlerefs.add(strongRef.data);

        ++posted;
        print(post.value);
      }
    }
    _updateRecall(r['Link'], titlerefs.first.cid, titlerefs.first.uri.href, db);
  }

  return posted;
}

void _updateRecall(String link, String cid, String uri, Database db) {
  final updateQuery = '''UPDATE recalls
SET
  uri = '$uri',
  cid = '$cid'
WHERE
  Link = '$link';''';
  try {
    db.execute(updateQuery);
  } on SqliteException catch(e) {
    print('_updateRecall: $e');
    print(updateQuery);
    rethrow;
  }
}

bskytxt.BlueskyText _createPost(List<List<String>> titles, Row r) {
  StringBuffer postText = StringBuffer();
  for (final t in titles) {
    final field = t[0];
    final header = t[1];
    final rawText = parser.parseFragment(r[field]).text;
    if (rawText != null && rawText != '') {
      rawText.replaceAll('  ', ' ');
      rawText.replaceAll('\n\n', '\n');
      if (header != '') {
        if (postText.isNotEmpty) {
          postText.write('\n');
        }
        postText.write('$header: ');
      }
      postText.write(rawText);
    }
  }
  final text = bskytxt.BlueskyText(postText.toString());
  return text;
}

const Map<String, String> _months = {
  'Jan': '01',
  'Feb': '02',
  'Mar': '03',
  'Apr': '04',
  'May': '05',
  'Jun': '06',
  'Jul': '07',
  'Aug': '08',
  'Sep': '09',
  'Oct': '10',
  'Nov': '11',
  'Dec': '12',
};

const List<List<List<String>>> _postTitles = [
  [
    ['Title', ''],
    ['Link', 'Link'],
    ['PubDate', 'Date']
  ],
  [
    ['Descript', 'Description'],
  ],
];