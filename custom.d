module custom;

import std.exception;
import std.file;
import std.path;
import std.string;

import ae.sys.d.customizer;

import common;
import repo;

alias subDir!"result" resultDir;

class DiggerCustomizer : DCustomizer
{
	this() { super(repo.d); }

	override void initialize()
	{
		if (!d.repoDir.exists)
			d.log("First run detected.\nPlease be patient, " ~
				"cloning everything might take a few minutes...\n");

		super.initialize();

		d.log("Ready.");
	}

	/// Build the customized D version.
	/// The result will be in resultDir.
	void runBuild()
	{
		d.build();

		d.log("Moving...");
		if (resultDir.exists)
			resultDir.rmdirRecurse();
		rename(d.buildDir, resultDir);

		d.log("Build successful.\n\nAdd %s to your PATH to start using it.".format(
			resultDir.buildPath("bin").absolutePath()
		));
	}

	override string getCallbackCommand()
	{
		return escapeShellFileName(thisExePath) ~ " do callback";
	}
}

int handleWebTask(string[] args)
{
	enforce(args.length, "No task specified");
	auto customizer = new DiggerCustomizer();
	switch (args[0])
	{
		case "initialize":
			customizer.initialize();
			return 0;
		case "merge":
			enforce(args.length == 3);
			customizer.merge(args[1], args[2]);
			return 0;
		case "unmerge":
			enforce(args.length == 3);
			customizer.unmerge(args[1], args[2]);
			return 0;
		case "callback":
			customizer.callback(args[1..$]);
			return 0;
		case "build":
			customizer.runBuild();
			return 0;
		default:
			assert(false);
	}
}
