module digger.build.components.rdmd;

import digger.build.components;
import digger.build.manager;


/// The rdmd build tool by itself.
/// It predates the tools package.
final class RDMD : DlangComponent
{
	protected @property override string submoduleName() { return "tools"; }
	protected @property override string[] sourceDependencies() { return []; }
	protected @property override string[] dependencies() { return ["dmd", "druntime", "phobos"]; }

	private @property string model() { return config.build.components.common.models.get(0); }

	protected @property override string configString()
	{
		static struct FullConfig
		{
			string model;
		}

		return FullConfig(
			this.model,
		).toJson();
	}

	protected override void performBuild()
	{
		foreach (dep; ["dmd", "druntime", "phobos", "phobos-includes"])
			getComponent(dep).needInstalled();

		auto env = baseEnvironment;
		needCC(env, this.model);

		// Just build rdmd
		bool needModel; // Need -mXX switch?

		if (sourceDir.buildPath("posix.mak").exists)
			needModel = true; // Known to be needed for recent versions

		string[] args;
		if (needConfSwitch())
			args ~= ["-conf=" ~ buildPath(buildDir , "bin", configFileName)];
		args ~= ["rdmd"];

		if (!needModel)
			try
				run([dmd] ~ args, env.vars, sourceDir);
			catch (Exception e)
				needModel = true;

		if (needModel)
			run([dmd, "-m" ~ this.model] ~ args, env.vars, sourceDir);
	}

	protected override void performStage()
	{
		cp(
			buildPath(sourceDir, "rdmd" ~ binExt),
			buildPath(stageDir , "bin", "rdmd" ~ binExt),
		);
	}

	protected override void performTest()
	{
		auto env = baseEnvironment;
		version (Windows)
			needDMC(env); // Need DigitalMars Make

		string[] args;
		if (sourceDir.buildPath(makeFileName).readText.canFind("\ntest_rdmd"))
			args = getMake(env) ~ ["-f", makeFileName, "test_rdmd", "DFLAGS=-g -m" ~ model] ~ config.build.components.common.makeArgs ~ getPlatformMakeVars(env, model) ~ dMakeArgs;
		else
		{
			// Legacy (before makefile rules)

			args = ["dmd", "-m" ~ this.model, "-run", "rdmd_test.d"];
			if (sourceDir.buildPath("rdmd_test.d").readText.canFind("modelSwitch"))
				args ~= "--model=" ~ this.model;
			else
			{
				version (Windows)
					if (this.model != "32")
					{
						// Can't test rdmd on non-32-bit Windows until compiler model matches Phobos model.
						// rdmd_test does not use -m when building rdmd, thus linking will fail
						// (because of model mismatch with the phobos we built).
						log("Can't test rdmd with model " ~ this.model ~ ", skipping");
						return;
					}
			}
		}

		foreach (dep; ["dmd", "druntime", "phobos", "phobos-includes"])
			getComponent(dep).needInstalled();

		getComponent("dmd").updateEnv(env);
		run(args, env.vars, sourceDir);
	}
}

