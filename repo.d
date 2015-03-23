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
import ae.sys.d.manager;

import common;
import config : config, opts;

//alias BuildConfig = DManager.Config.Build;

// Wrapper type for compatibility with 1.x INI files.
struct BuildConfig
{
	DManager.Config.Build.Components components;

	string model;
	bool debugDMD;

	@property DManager.Config.Build convert()
	{
		DManager.Config.Build build;
		build.components = components;
		if (model)
			build.components.common.model = model;
		if (debugDMD)
			build.components.dmd.debugDMD = true;
		return build;
	}

	alias convert this;
}

final class DiggerManager : DManager
{
	this()
	{
		this.config.local.workDir = .config.workDir.expandTilde();
		this.config.offline = .opts.offline;
		this.config.persistentCache = .config.cache;
	}

	override void log(string s)
	{
		common.log(s);
	}

	void logProgress(string s)
	{
		log((" " ~ s ~ " ").center(70, '-'));
	}

	override void prepareEnv()
	{
		super.prepareEnv();

		applyEnv(.config.environment);
	}

	void applyEnv(in string[string] env)
	{
		auto oldEnv = environment.toAA();
		foreach (name, value; this.config.env)
			oldEnv[name] = value;
		foreach (name, value; env)
		{
			string newValue = value;
			foreach (oldName, oldValue; oldEnv)
				newValue = newValue.replace("%" ~ oldName ~ "%", oldValue);
			config.env[name] = oldEnv[name] = newValue;
		}
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

	// git's approxidate accepts anything, so a disambiguating prefix is required
	if (rev.canFind('@') && !rev.canFind("@{"))
	{
		auto parts = rev.findSplit("@");
		auto at = parts[2].strip();
		if (at.startsWith("#"))
			args ~= ["--skip", at[1..$]];
		else
			args ~= ["--until", at];
		rev = parts[0].strip();
	}

	if (rev.empty)
		rev = "origin/master";

	d.needUpdate();

	auto metaRepo = d.getMetaRepo();
	metaRepo.needRepo();
	auto repo = &metaRepo.git;

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
