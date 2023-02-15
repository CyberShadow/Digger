module digger.site;

// import std.array;
// import std.algorithm;
// import std.exception;
// import std.file;
// import std.parallelism : parallel;
// import std.path;
// import std.process;
// import std.range;
// import std.regex;
// import std.string;
import std.typecons;

// import ae.sys.file;
// import ae.utils.regex;

import digger.build.site;
// import digger.common;
import digger.config : config, opts;
// // import digger.custom : parseSpec;

//alias BuildConfig = DManager.Config.Build;

// final class DiggerManager : DManager
// {
// 	this()
// 	{
// 		this.config.build = cast().config.build;
// 		this.config.local = cast().config.local;
// 		this.verifyWorkTree = true; // for commands which don't take BuildOptions, like bisect
// 	}

// 	override void log(string s)
// 	{
// 		.digger.common.log(s);
// 	}

// 	void logProgress(string s)
// 	{
// 		log((" " ~ s ~ " ").center(70, '-'));
// 	}

// 	override SubmoduleState parseSpec(string spec)
// 	{
// 		return .parseSpec(spec);
// 	}

// 	override MetaRepository getMetaRepo()
// 	{
// 		if (!repoDir.exists)
// 			log("First run detected.\nPlease be patient, " ~
// 				"cloning everything might take a few minutes...\n");
// 		return super.getMetaRepo();
// 	}

// 	override string getCallbackCommand()
// 	{
// 		return escapeShellFileName(thisExePath) ~ " do callback";
// 	}

// 	string[string] getBaseEnvironment()
// 	{
// 		return d.baseEnvironment.vars;
// 	}

// 	bool haveUpdate;

// 	void needUpdate()
// 	{
// 		if (!haveUpdate)
// 		{
// 			d.update();
// 			haveUpdate = true;
// 		}
// 	}
// }

private Nullable!BuildSite siteInstance;
@property BuildSite site() { return siteInstance.get(new BuildSite(config.local)); }
