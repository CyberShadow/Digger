module digger.build.components.curl;

import digger.build.components;
import digger.build.manager;

/// libcurl DLL and import library for Windows.
final class Curl : Component
{
	protected @property override string submoduleName() { return null; }
	protected @property override string[] sourceDependencies() { return []; }
	protected @property override string[] dependencies() { return []; }
	protected @property override string configString() { return null; }

	protected override void performBuild()
	{
		version (Windows)
			needCurl();
		else
			log("Not on Windows, skipping libcurl download");
	}

	protected override void performStage()
	{
		version (Windows)
		{
			auto curlDir = needCurl();

			void copyDir(string source, string target)
			{
				source = buildPath(curlDir, "dmd2", "windows", source);
				target = buildPath(stageDir, target);
				if (source.exists)
					cp(source, target);
			}

			foreach (model; config.build.components.common.models)
			{
				auto suffix = model == "64" ? "64" : "";
				copyDir("bin" ~ suffix, "bin");
				copyDir("lib" ~ suffix, "lib");
			}
		}
		else
			log("Not on Windows, skipping libcurl install");
	}

	protected override void updateEnv(ref Environment env)
	{
		env.vars["PATH"] = buildPath(buildDir, "bin").absolutePath() ~ pathSeparator ~ env.vars["PATH"];
	}
}
