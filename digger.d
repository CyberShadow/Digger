module digger;

import std.exception;
import std.getopt;

import bisect;
import build;
import cache;
import common;
import repo;
import webtasks;

// http://d.puremagic.com/issues/show_bug.cgi?id=7016
version(Windows) static import ae.sys.windows;

int doMain()
{
	auto args = opts.args.dup;
	enforce(args.length, "No command specified");
	switch (args[0])
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
		{
			bool model64;
			getopt(args,
				"64", &model64,
			);
			if (model64)
				buildConfig.model = "64";
			enforce(args.length == 2, "Specify revision");
			d.prepareRepo(true);
			auto rev = parseRev(args[1]);
			d.repo.run("checkout", rev);
			prepareTools();
			prepareBuild();
			return 0;
		}
		case "compact":
			optimizeCache();
			return 0;
		case "delve":
			return doDelve();

		// digger-web tasks
		case "do":
			args = args[1..$];
			enforce(args.length, "No task specified");
			switch (args[0])
			{
				case "initialize":
					initialize();
					return 0;
				case "merge":
					enforce(args.length == 3);
					merge(args[1], args[2]);
					return 9;
				case "unmerge":
					enforce(args.length == 3);
					unmerge(args[1], args[2]);
					return 0;
				case "unmerge-rebase-edit":
					enforce(args.length == 3);
					unmergeRebaseEdit(args[1], args[2]);
					return 0;
				case "build":
					runBuild();
					return 0;
				default:
					assert(false);
			}

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
