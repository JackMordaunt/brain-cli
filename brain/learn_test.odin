package brain

import "core:encoding/json"
import "core:strings"
import "core:testing"

import "jm:path"
import "jm:sqlite3"

// Three sessions asked for "fulltext" and were given the sqlite bullet,
// which does not name it, and none kept looking: the word becomes an
// alias. One session asked again afterwards: that serve was not used.
@(test)
learn_wires_query_words_to_the_bullets_they_found :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f := fixture(t)
	defer fixture_destroy(f)
	exec(f.cli, "reindex")
	db, err := open_db(f.cli.db)
	testing.expect_value(t, err, "")
	rows := [?]string {
		"(1,'2026-03-01 10:00:00','fulltext index',1,'claude','a')",
		"(2,'2026-03-02 10:00:00','fulltext',1,'claude','b')",
		"(3,'2026-03-03 10:00:00','fulltext search engine',1,'claude','c')",
		"(4,'2026-03-04 10:00:00','fulltext',1,'claude','d')",
		"(5,'2026-03-04 10:05:00','sqlite fts5',1,'claude','d')",
	}
	for r in rows {
		sqlite3.exec(db, strings.concatenate({"insert into queries(id,ts,q,hits,caller,session) values", r}))
		id := r[1:2]
		sqlite3.exec(db, strings.concatenate({"insert into query_hits(query_id,file,handle,rank) values(", id, ",'AI/MEMORY.md','sqlite',1)"}))
	}
	sqlite3.close(&db)

	o, _, code := exec(f.cli, "learn")
	testing.expect_value(t, code, 0)
	testing.expect(t, strings.has_prefix(o, "5 serves with a session: 4 used, 0 named back by the agent\n"), o)
	testing.expect(t, strings.contains(o, "AI/MEMORY.md **sqlite** += fulltext (3 sessions)"), o)
	testing.expect(t, !strings.contains(o, "+= index") && !strings.contains(o, "+= engine"), o)
	testing.expect(t, strings.contains(o, "too few queries logged"), o)

	o, _, code = exec(f.cli, "learn", "--json")
	testing.expect_value(t, code, 0)
	v, jerr := json.parse_string(o)
	testing.expect_value(t, jerr, nil)
	aliases, _ := v.(json.Object)["aliases"].(json.Array)
	testing.expect_value(t, len(aliases), 1)
	if len(aliases) == 1 {
		testing.expect_value(t, json_string(aliases[0], "term"), "fulltext")
	}

	o, _, code = exec(f.cli, "learn", "--apply")
	testing.expect_value(t, code, 0)
	testing.expect(t, strings.contains(o, "applied 1 edits"), o)
	text, _ := path.read(path.join(f.vault, "AI", "MEMORY.md"))
	testing.expect(t, strings.contains(text, "- **sqlite** (aliases: sqlite3, fts5, full-text search, fulltext) — the index"), text)
	// Learned once: the word now names the bullet, so it is no candidate.
	o, _, _ = exec(f.cli, "learn")
	testing.expect(t, !strings.contains(o, "+= fulltext"), o)
	o, _, code = exec(f.cli, "find", "fulltext")
	testing.expect_value(t, code, 0)
	testing.expect(t, strings.contains(o, "**sqlite**"), o)
}

// The boost is an experiment behind BRAIN_RANK=weighted: a used bullet
// gains at most one tie margin, a bullet that failed verify gains nothing.
@(test)
rank_weighting_is_off_unless_asked :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f := fixture(t)
	defer fixture_destroy(f)
	exec(f.cli, "reindex")
	db, err := open_db(f.cli.db)
	testing.expect_value(t, err, "")
	for i in 0 ..< 20 {
		sqlite3.exec_args(db, "insert into serve_outcome(query_id,handle,used,strong) values(?,?,1,0)", i64(i), "libgit2")
	}
	sqlite3.exec(db, "insert into claims(file,line,handle,kind,text,verdict,why,checked) values('AI/MEMORY.md',9,'sqlite','path','/x','failed','gone','2026-01-01')")
	hits := [?]Hit{{handle = "sqlite", score = -5}, {handle = "libgit2", score = -4.5}}
	weighed := weigh(db, hits[:])
	testing.expect_value(t, weighed[0].handle, "libgit2")
	testing.expect(t, weighed[0].score >= -5.5 && weighed[0].score < -5.4, "capped at one margin")
	testing.expect_value(t, weighed[1].score, -5)
	sqlite3.close(&db)
	testing.expect(t, !rank_weighted(f.cli), "off by default")
	// Through find: the used bullet's score moves by the cap when weighted,
	// and --plain puts it back.
	score := proc(t: ^testing.T, o: string) -> f64 {
		v, jerr := json.parse_string(o)
		testing.expect_value(t, jerr, nil)
		hits, _ := v.(json.Object)["hits"].(json.Array)
		for h in hits {
			if json_string(h, "handle") == "libgit2" {
				s, _ := h.(json.Object)["score"].(json.Float)
				return f64(s)
			}
		}
		return 0
	}
	o, _, code := exec(f.cli, "find", "libgit2", "--json")
	testing.expect_value(t, code, 0)
	plain := score(t, o)
	f.cli.env["BRAIN_RANK"] = "weighted"
	testing.expect(t, rank_weighted(f.cli), "on when asked")
	o, _, _ = exec(f.cli, "find", "libgit2", "--json")
	boosted := score(t, o)
	testing.expect(t, boosted < plain - 0.9 && boosted > plain - 1.1, "boosted by the cap")
	o, _, _ = exec(f.cli, "find", "libgit2", "--json", "--plain")
	testing.expect_value(t, score(t, o), plain)
}
