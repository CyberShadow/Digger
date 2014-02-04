module repo;

import std.algorithm;
import std.exception;
import std.file;
import std.parallelism : parallel;
import std.path;
import std.process;
import std.range;
import std.regex;
import std.string;

import common;

struct Repository
{
	string path;

	void run(string[] args...) { auto owd = pushd(path); return .run(["git"] ~ args); }
	string query(string[] args...) { auto owd = pushd(path); return .query(["git"] ~ args); }
}

enum REPO = "repo";
enum REPO_URL = "https://bitbucket.org/cybershadow/d.git";

void prepareRepo(bool update)
{
	if (!REPO.exists)
	{
		log("Cloning initial repository...");
		run(["git", "clone", "--recursive", REPO_URL, REPO]);
		return;
	}

	auto repo = Repository(REPO);
	repo.run("bisect", "reset");
	repo.run("checkout", "--force", "master");
	repo.run("reset", "--hard", "origin/master");

	if (update)
	{
		log("Updating repositories...");
		auto allRepos = repo
			.query("ls-files")
			.splitLines()
			.filter!(r => r != ".gitmodules")
			.map!(r => buildPath(REPO, r))
			.chain(REPO.only)
			.array();
		foreach (r; allRepos.parallel)
			Repository(r).run("fetch", "origin");
	}
}

/// Returns SHA-1 of the initial search points.
string getRev(bool good)()
{
	static string result;
	if (!result)
		result = parseRev(good ? config.good : config.bad);
	return result;
}

string parseRev(string rev)
{
	auto repo = Repository(REPO);

	try
		return repo.query("log", "-n", "1", "--pretty=format:%H", rev);
	catch (Exception e) {}

	// git's approxidate accepts anything, so a disambiguating prefix is required
	if (rev.startsWith("@"))
		return repo.query("log", "-n", "1", "--pretty=format:%H", "--until", rev[1..$].strip());

	auto grep = repo.query("log", "-n", "2", "--pretty=format:%H", "--grep", rev).splitLines();
	if (grep.length == 1)
		return grep[0];

	auto pickaxe = repo.query("log", "-n", "3", "--pretty=format:%H", "-S" ~ rev).splitLines();
	if (pickaxe.length <= 2) // removed <- added
		return pickaxe[$-1];   // the one where it was added

	throw new Exception("Unknown/ambiguous revision: " ~ rev);
}
