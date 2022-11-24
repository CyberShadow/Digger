module digger.repo;

import std.array;
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
import ae.sys.d.manager;
import ae.utils.regex;

import digger.common;
import digger.config : config, opts;
import digger.custom : parseSpec;

//alias BuildConfig = DManager.Config.Build;

final class DiggerManager : DManager
{
	this()
	{
		this.config.build = cast().config.build;
		this.config.local = cast().config.local;
		this.verifyWorkTree = true; // for commands which don't take BuildOptions, like bisect
	}

	override void log(string s)
	{
		.digger.common.log(s);
	}

	void logProgress(string s)
	{
		log((" " ~ s ~ " ").center(70, '-'));
	}

	override SubmoduleState parseSpec(string spec)
	{
		return .parseSpec(spec);
	}

	override MetaRepository getMetaRepo()
	{
		if (!repoDir.exists)
			log("First run detected.\nPlease be patient, " ~
				"cloning everything might take a few minutes...\n");
		return super.getMetaRepo();
	}

	override string getCallbackCommand()
	{
		return escapeShellFileName(thisExePath) ~ " do callback";
	}

	string[string] getBaseEnvironment()
	{
		return d.baseEnvironment.vars;
	}

	bool haveUpdate;

	void needUpdate()
	{
		if (!haveUpdate)
		{
			d.update();
			haveUpdate = true;
		}
	}
}

DiggerManager d;

static this()
{
	d = new DiggerManager();
}

string parseRev(string rev)
{
	auto args = ["log", "--pretty=format:%H"];

	d.needUpdate();

	auto metaRepo = d.getMetaRepo();
	auto repo = &metaRepo.git();

	// git's approxidate accepts anything, so a disambiguating prefix is required
	if (rev.canFind('@') && !rev.canFind("@{"))
	{
		auto parts = rev.findSplit("@");
		auto at = parts[2].strip();

		// If this is a named tag, use the date of the tagged commit.
		try
		{
			auto sha1 = metaRepo.getRef("refs/tags/" ~ at);
			at = repo.query("log", "-1", "--pretty=format:%cI", sha1);
		}
		catch (Exception e) {}

		if (at.startsWith("#")) // For the build-all command - skip this many commits
			args ~= ["--skip", at[1..$]];
		else
			args ~= ["--until", at];
		rev = parts[0].strip();
	}

	if (rev.empty)
		rev = "origin/master";

	try
		if (metaRepo.getRef("origin/" ~ rev))
			return repo.query(args ~ ["-n", "1", "origin/" ~ rev]);
	catch (Exception e) {}

	try
		if (metaRepo.getRef(rev))
			return repo.query(args ~ ["-n", "1", rev]);
	catch (Exception e) {}

	if (rev.startsWith("https://github.com"))
	{
		auto grep = repo.query("log", "-n", "2", "--pretty=format:%H", "--grep", "^" ~ escapeRE(rev), "origin/master").splitLines();
		if (grep.length == 1)
			return grep[0];
	}

	auto pickaxe = repo.query("log", "-n", "3", "--pretty=format:%H", "-S" ~ rev, "origin/master").splitLines();
	if (pickaxe.length && pickaxe.length <= 2) // removed <- added
		return pickaxe[$-1];   // the one where it was added

	throw new Exception("Unknown/ambiguous revision: " ~ rev);
}
