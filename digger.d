module digger;

import std.exception;
import std.getopt;

import bisect;
import build;
import cache;
import common;
import repo;

import ae.sys.windows; // http://d.puremagic.com/issues/show_bug.cgi?id=7016

int main()
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
			Repository(repoDir).run("log", "-n1", rev);
			return 0;
		}
		case "build":
		{
			bool model64;
			getopt(args,
				"64", &model64,
			);
			enforce(args.length == 2, "Specify revision");
			prepareRepo(true);
			auto rev = parseRev(args[1]);
			Repository(repoDir).run("checkout", rev);
			prepareTools();
			enforce(prepareBuild(), "Build failed");
			return 0;
		}
		case "compact":
			optimizeCache();
			return 0;
		default:
			throw new Exception("Unknown command: " ~ args[0]);
	}
}
