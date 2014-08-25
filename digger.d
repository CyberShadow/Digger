module digger;

import std.exception;
import std.getopt;

static import ae.sys.net.system;

import bisect;
import cache;
import common;
import custom;
import repo;

// http://d.puremagic.com/issues/show_bug.cgi?id=7016
version(Windows) static import ae.sys.windows;

int doMain()
{
	auto args = opts.args.dup;
	enforce(args.length, "No command specified");
	auto command = args[0];
	switch (command)
	{
		case "bisect":
			return doBisect();
		case "show":
		{
			enforce(args.length == 2, "Specify revision");
			auto rev = parseRev(args[1]);
			d.repo.run("log", "-n1", rev);
			d.repo.run("log", "-n1", "--pretty=format:t=%ct", rev);
			return 0;
		}
		case "build":
		case "build-all":
		{
			BuildConfig buildConfig;
			bool model64;
			int step = 1;
			getopt(args,
				"64", &model64,
				"step", &step,
			);
			if (model64)
				buildConfig.model = "64";
			string spec = args.length > 1 ? args[1] : "master";

			if (command == "build")
				buildCustom(spec, buildConfig);
			else
				buildAll(spec, buildConfig, step);
			return 0;
		}
		case "compact":
			optimizeCache();
			return 0;
		case "delve":
			return doDelve();
		case "do":
			return handleWebTask(args[1..$]);

		default:
			throw new Exception("Unknown command: " ~ args[0]);
	}
}

int main()
{
	debug
		return doMain();
	else
	{
		try
			return doMain();
		catch (Exception e)
		{
			import std.stdio : stderr;
			stderr.writefln("Fatal error: %s", e.msg);
			return 1;
		}
	}
}
