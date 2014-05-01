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

import ae.sys.cmd;
import ae.sys.file;

public import ae.sys.git;

import common;

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
		scope(failure) log("Check that you have git installed and accessible from PATH.");
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

	auto args = ["log", "--pretty=format:%H"];

	// git's approxidate accepts anything, so a disambiguating prefix is required
	if (rev.canFind('@'))
	{
		auto parts = rev.findSplit("@");
		args ~= ["--until", parts[2].strip()];
		rev = parts[0].strip();
		if (rev.empty)
			rev = "origin/master";
	}

	try
		return repo.query(args ~ ["-n", "1", "origin/" ~ rev]);
	catch (Exception e)
	try
		return repo.query(args ~ ["-n", "1", rev]);
	catch (Exception e)
		{}

	auto grep = repo.query("log", "-n", "2", "--pretty=format:%H", "--grep", rev, "origin/master").splitLines();
	if (grep.length == 1)
		return grep[0];

	auto pickaxe = repo.query("log", "-n", "3", "--pretty=format:%H", "-S" ~ rev, "origin/master").splitLines();
	if (pickaxe.length && pickaxe.length <= 2) // removed <- added
		return pickaxe[$-1];   // the one where it was added

	throw new Exception("Unknown/ambiguous revision: " ~ rev);
}
