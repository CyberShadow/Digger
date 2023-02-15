module digger.build.components.druntime;

import digger.build.components;
import digger.build.manager;

/// Druntime. Installs only import files, but builds the library too.
final class Druntime : DlangComponent
{
	protected @property override string submoduleName    () { return "druntime"; }
	protected @property override string[] sourceDependencies() { return ["phobos", "phobos-includes"]; }
	protected @property override string[] dependencies() { return ["dmd"]; }

	protected @property override string configString()
	{
		static struct FullConfig
		{
			string model;
			string[] makeArgs;
		}

		return FullConfig(
			config.build.components.common.model,
			config.build.components.common.makeArgs,
		).toJson();
	}

	protected override void performBuild()
	{
		foreach (model; config.build.components.common.models)
		{
			auto env = baseEnvironment;
			needCC(env, model);

			if (needHostDMD)
			{
				enum dmdVer = "v2.079.0"; // Same as latest version in DMD.performBuild
				needDMD(env, dmdVer);
			}

			getComponent("phobos").needSource();
			getComponent("dmd").needSource();
			getComponent("dmd").needInstalled();
			getComponent("phobos-includes").needInstalled();

			mkdirRecurse(sourceDir.buildPath("import"));
			mkdirRecurse(sourceDir.buildPath("lib"));

			setTimes(sourceDir.buildPath("src", "rt", "minit.obj"), Clock.currTime(), Clock.currTime()); // Don't rebuild
			submodule.saveFileState("src/rt/minit.obj");

			runMake(env, model, "import");
			runMake(env, model);
		}
	}

	protected override void performStage()
	{
		cp(
			buildPath(sourceDir, "import"),
			buildPath(stageDir , "import"),
		);
	}

	protected override void performTest()
	{
		getComponent("druntime").needBuild(true);
		getComponent("dmd").needInstalled();

		foreach (model; config.build.components.common.models)
		{
			auto env = baseEnvironment;
			needCC(env, model);
			runMake(env, model, "unittest");
		}
	}

	private bool needHostDMD()
	{
		version (Windows)
			return sourceDir.buildPath("mak", "copyimports.d").exists;
		else
			return false;
	}

	private final void runMake(ref Environment env, string model, string target = null)
	{
		// Work around https://github.com/dlang/druntime/pull/2438
		bool quotePaths = !(isVersion!"Windows" && model != "32" && sourceDir.buildPath("win64.mak").readText().canFind(`"$(CC)"`));

		string[] args =
			getMake(env) ~
			["-f", makeFileNameModel(model)] ~
			(target ? [target] : []) ~
			["DMD=" ~ dmd] ~
			(needHostDMD ? ["HOST_DMD=" ~ env.deps.hostDC] : []) ~
			(config.build.components.common.debugLib ? ["BUILD=debug"] : []) ~
			config.build.components.common.makeArgs ~
			getPlatformMakeVars(env, model, quotePaths) ~
			dMakeArgs;
		run(args, env.vars, sourceDir);
	}
}
