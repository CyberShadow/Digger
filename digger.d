module digger;

import std.exception;

import bisect;
import common;
import repo;

import ae.sys.windows; // http://d.puremagic.com/issues/show_bug.cgi?id=7016

int main()
{
	enforce(opts.args.length, "No command specified");
	switch (opts.args[0])
	{
		case "bisect":
			return doBisect();
		case "show":
		{
			enforce(opts.args.length == 2, "Specify revision");
			auto rev = parseRev(opts.args[1]);
			Repository(repoDir).run("log", "-n1", rev);
			return 0;
		}
		default:
			throw new Exception("Unknown command: " ~ opts.args[0]);
	}
}
