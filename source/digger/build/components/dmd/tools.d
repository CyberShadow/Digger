module digger.build.components.dmd.tools;

import digger.build.components;
import digger.build.manager;

/// Tools package with all its components, including rdmd.
final class Tools : DlangComponent
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
			string[] makeArgs;
		}

		return FullConfig(
			this.model,
			config.build.components.common.makeArgs,
		).toJson();
	}

	protected override void performBuild()
	{
		getComponent("dmd").needSource();
		foreach (dep; ["dmd", "druntime", "phobos"])
			getComponent(dep).needInstalled();

		auto env = baseEnvironment;
		needCC(env, this.model);

		run(getMake(env) ~ ["-f", makeFileName, "DMD=" ~ dmd] ~ config.build.components.common.makeArgs ~ getPlatformMakeVars(env, this.model) ~ dMakeArgs, env.vars, sourceDir);
	}

	protected override void performStage()
	{
		foreach (os; buildPath(sourceDir, "generated").dirEntries(SpanMode.shallow))
			foreach (de; os.buildPath(this.model).dirEntries(SpanMode.shallow))
				if (de.extension == binExt)
					cp(de, buildPath(stageDir, "bin", de.baseName));
	}
}

