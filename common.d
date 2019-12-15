module common;

import std.stdio;

enum diggerVersion = "3.0 alpha 10";

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
	writeToConsole("digger: " ~ s ~ "\n");
}
