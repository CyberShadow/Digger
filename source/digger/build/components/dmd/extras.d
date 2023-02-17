module digger.build.components.dmd.extras;

import digger.build.components;
import digger.build.manager;

/// Extras not built from source (DigitalMars and third-party tools and libraries)
final class Extras : Component
{
	protected @property override string submoduleName() { return null; }
	protected @property override string[] sourceDependencies() { return []; }
	protected @property override string[] dependencies() { return []; }
	protected @property override string configString() { return null; }

	protected override void performBuild()
	{
		needExtras();
	}

	protected override void performStage()
	{
		auto extrasDir = needExtras();

		void copyDir(string source, string target)
		{
			source = buildPath(extrasDir, "localextras-" ~ platform, "dmd2", platform, source);
			target = buildPath(stageDir, target);
			if (source.exists)
				cp(source, target);
		}

		copyDir("bin", "bin");
		foreach (model; config.build.components.common.models)
			copyDir("bin" ~ model, "bin");
		copyDir("lib", "lib");

		version (Windows)
			foreach (model; config.build.components.common.models)
				if (model == "32")
				{
					// The version of snn.lib bundled with DMC will be newer.
					Environment env;
					needDMC(env);
					cp(buildPath(env.deps.dmcDir, "lib", "snn.lib"), buildPath(stageDir, "lib", "snn.lib"));
				}
	}
}

