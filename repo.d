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
import ae.sys.d.customizer;

import common;

final class DiggerCustomizer : DCustomizer
{
	this()
	{
		this.config.workDir = common.config.workDir;
	}

	override void log(string s)
	{
		common.log(s);
	}

	override void prepareEnv()
	{
		super.prepareEnv();

		applyEnv(common.config.environment);
	}

	void applyEnv(in string[string] env)
	{
		auto oldEnv = environment.toAA();
		foreach (name, value; dEnv)
			oldEnv[name] = value;
		foreach (name, value; env)
		{
			string newValue = value;
			foreach (oldName, oldValue; oldEnv)
				newValue = newValue.replace("%" ~ oldName ~ "%", oldValue);
			dEnv[name] = oldEnv[name] = newValue;
		}
	}
}

DiggerCustomizer d;

static this()
{
	d = new DiggerCustomizer();
}

string parseRev(string rev)
{
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
		return d.repo.query(args ~ ["-n", "1", "origin/" ~ rev]);
	catch (Exception e)
	try
		return d.repo.query(args ~ ["-n", "1", rev]);
	catch (Exception e)
		{}

	auto grep = d.repo.query("log", "-n", "2", "--pretty=format:%H", "--grep", rev, "origin/master").splitLines();
	if (grep.length == 1)
		return grep[0];

	auto pickaxe = d.repo.query("log", "-n", "3", "--pretty=format:%H", "-S" ~ rev, "origin/master").splitLines();
	if (pickaxe.length && pickaxe.length <= 2) // removed <- added
		return pickaxe[$-1];   // the one where it was added

	throw new Exception("Unknown/ambiguous revision: " ~ rev);
}
