module digger;

import std.exception;

import bisect;
import common;

import ae.sys.windows; // http://d.puremagic.com/issues/show_bug.cgi?id=7016

int main()
{
	enforce(opts.args.length, "No command specified");
	switch (opts.args[0])
	{
		case "bisect":
			return doBisect();
		default:
			throw new Exception("Unknown command: " ~ opts.args[0]);
	}
}
