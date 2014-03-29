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

import ae.sys.file;

import common;

struct Repository
{
	string path;

	string[] argsPrefix;

	this(string path)
	{
		path = path.absolutePath();
		enforce(path.exists, "Repository path does not exist");
		auto dotGit = path.buildPath(".git");
		if (dotGit.isFile)
			dotGit = path.buildPath(dotGit.readText().strip()[8..$]);
		//path = path.replace(`\`, `/`);
		this.path = path;
		this.argsPrefix = [`git`, `--work-tree=` ~ path, `--git-dir=` ~ dotGit];
	}

	void   run  (string[] args...) { auto owd = pushd(workPath(args[0])); return .run  (argsPrefix ~ args); }
	string query(string[] args...) { auto owd = pushd(workPath(args[0])); return .query(argsPrefix ~ args); }

	/// Certain git commands (notably, bisect) must
	/// be run in the repository's root directory.
	private string workPath(string cmd)
	{
		switch (cmd)
		{
			case "bisect":
			case "submodule":
				return path;
			default:
				return null;
		}
	}
}

alias repoDir = subDir!"repo";     /// D-dot-git repository directory
enum REPO_URL = "https://bitbucket.org/cybershadow/d.git";

string[] listComponents()
{
	auto repo = Repository(repoDir);
	return repo
		.query("ls-files")
		.splitLines()
		.filter!(r => r != ".gitmodules")
		.array();
}

void prepareRepo(bool update)
{
	if (!repoDir.exists)
	{
		log("Cloning initial repository...");
		run(["git", "clone", "--recursive", REPO_URL, repoDir]);
		return;
	}

	auto repo = Repository(repoDir);
	repo.run("bisect", "reset");
	repo.run("checkout", "--force", "master");

	if (update)
	{
		log("Updating repositories...");
		auto allRepos = listComponents()
			.map!(r => buildPath(repoDir, r))
			.chain(repoDir.only)
			.array();
		foreach (r; allRepos.parallel)
			Repository(r).run("-c", "fetch.recurseSubmodules=false", "remote", "update");
	}

	repo.run("reset", "--hard", "origin/master");
}

string parseRev(string rev)
{
	auto repo = Repository(repoDir);

	try
		return repo.query("log", "-n", "1", "--pretty=format:%H", rev);
	catch (Exception e) {}

	// git's approxidate accepts anything, so a disambiguating prefix is required
	if (rev.startsWith("@"))
		return repo.query("log", "-n", "1", "--pretty=format:%H", "--until", rev[1..$].strip(), "origin/master");

	auto grep = repo.query("log", "-n", "2", "--pretty=format:%H", "--grep", rev, "origin/master").splitLines();
	if (grep.length == 1)
		return grep[0];

	auto pickaxe = repo.query("log", "-n", "3", "--pretty=format:%H", "-S" ~ rev, "origin/master").splitLines();
	if (pickaxe.length && pickaxe.length <= 2) // removed <- added
		return pickaxe[$-1];   // the one where it was added

	throw new Exception("Unknown/ambiguous revision: " ~ rev);
}
