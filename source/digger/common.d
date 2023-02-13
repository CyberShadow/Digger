module digger.common;

import std.stdio;

import digger.config;

enum diggerVersion = "5.0.0";

/// Send to stderr iff we have a console to write to
void writeToConsole(string s)
{
	version (Windows)
	{
		import core.sys.windows.windows;
		auto h = GetStdHandle(STD_ERROR_HANDLE);
		if (!h || h == INVALID_HANDLE_VALUE)
			return;
	}

	stderr.write(s); stderr.flush();
}

void log(string s)
{
	if (!opts.quiet)
		writeToConsole("digger: " ~ s ~ "\n");
}
